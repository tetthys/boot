#!/usr/bin/env bash
# boot/network.sh - Functional network helpers using core.sh API
# - Pure, slim, reusable; no global side effects.
# - Depends on: curl (HTTP), openssl (TLS helpers).
#
# API:
#   boot::net_http METHOD URL OUT_BODY OUT_STATUS [options]
#     Options:
#       --timeout SEC        curl max-time (default: 10)
#       --max-retry N        retry count on curl failure or 5xx (default: 0)
#       --backoff base       base seconds for exponential backoff (default: 0.2)
#       --data STR           request body (optional)
#       --header "K: V"      repeatable header
#       --user-agent UA      custom UA string
#       --insecure           allow insecure TLS
#
#   boot::tls_expiry HOST:PORT [--cache-ttl SEC]
#     Prints certificate notAfter in OpenSSL's textual format (UTC).
#
#   boot::alpn HOST:PORT
#     Prints negotiated ALPN protocol(s) (e.g., "h2" or "http/1.1").

if [[ -n "${_BOOT_NETWORK_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_NETWORK_LOADED=1

# --- HTTP ----------------------------------------------------------------------

##**
# Perform an HTTP request via curl; writes body/status via nameref.
# Return codes:
#   0 on success; 1 on curl error; 127 if curl is missing.
##*
boot::net_http() {
  local method="${1:?}" url="${2:?}"; shift 2
  local -n __body="${1:?}" __code="${2:?}"; shift 2

  local timeout=10 retry=0 base=0.2 data="" ua="" insecure=0
  local -a headers=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)   timeout="${2:-10}"; shift 2;;
      --max-retry) retry="${2:-0}"; shift 2;;
      --backoff)   base="${2:-0.2}"; shift 2;;
      --data)      data="${2:-}"; shift 2;;
      --header)    headers+=("$2"); shift 2;;
      --user-agent) ua="${2:-}"; shift 2;;
      --insecure)  insecure=1; shift;;
      --) shift; break;;
      *)  break;;
    esac
  done

  if ! boot::require curl >/dev/null; then
    __body=""; __code=""
    return 127
  fi

  # One attempt runner
  _boot__http_once() {
    local -a args=(-sS -X "$method" --max-time "$timeout" -w '%{http_code}')
    local h
    for h in "${headers[@]}"; do args+=( -H "$h" ); done
    [[ -n "$data" ]] && args+=( --data-binary "$data" )
    [[ -n "$ua"   ]] && args+=( -A "$ua" )
    (( insecure )) && args+=( -k )

    local tmpb; tmpb="$(mktemp)"
    local code rc
    if code="$(curl "${args[@]}" "$url" -o "$tmpb")"; then
      __body="$(<"$tmpb")"
      __code="$code"
      rc=0
    else
      __body="$(<"$tmpb")"
      __code=""
      rc=1
    fi
    rm -f -- "$tmpb"
    # Consider 5xx as retryable failure
    if [[ $rc -eq 0 && "$__code" =~ ^5[0-9][0-9]$ ]]; then
      rc=1
    fi
    return "$rc"
  }

  # Retry loop using core backoff
  local attempt=1
  while :; do
    if _boot__http_once; then
      return 0
    fi
    if (( attempt > retry )); then
      return 1
    fi
    local delay; delay="$(boot::backoff_expo "$base" "$attempt")"
    boot::log warn "http retry $attempt/$retry rc=1 sleep ${delay}s url=$url"
    sleep "$delay"
    ((attempt++))
  done
}

# --- TLS -----------------------------------------------------------------------

##**
# Print certificate notAfter (expiry) for HOST:PORT. Optional cache.
# Returns:
#   0 on success with output; 127 if openssl is missing; non-zero otherwise.
##*
boot::tls_expiry() {
  local hp="${1:?}"; shift || true
  local cache_ttl=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cache-ttl) cache_ttl="${2:-0}"; shift 2;;
      *) break;;
    esac
  done

  if ! boot::require openssl >/dev/null; then
    return 127
  fi

  _boot__expiry_raw() {
    # shellcheck disable=SC2005
    echo "$(printf '' \
      | openssl s_client -servername "${hp%%:*}" -connect "$hp" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null \
      | sed -E 's/^notAfter=//')"
  }

  if (( cache_ttl > 0 )); then
    boot::cache_memo "tls-expiry:$hp" "$cache_ttl" -- bash -lc '_boot__expiry_raw' \
      2>/dev/null || _boot__expiry_raw
  else
    _boot__expiry_raw
  fi
}

##**
# Print negotiated ALPN protocol(s) (e.g., "h2" or "http/1.1").
# Returns:
#   0 if any output printed; 127 if openssl is missing; non-zero otherwise.
##*
boot::alpn() {
  local hp="${1:?}"
  if ! boot::require openssl >/dev/null; then
    return 127
  fi
  printf '' \
    | openssl s_client -alpn "h2,http/1.1" -servername "${hp%%:*}" -connect "$hp" 2>/dev/null \
    | awk -F': ' '/ALPN protocol/{getline;print $0}' \
    | sed 's/Negotiated, //' || true
}

return 0 2>/dev/null || true
