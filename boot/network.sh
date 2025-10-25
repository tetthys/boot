# boot/network.sh - Network helpers (Bash 5+)

if [[ -n "${_BOOT_NET_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_NET_LOADED=1

# ------------------------------ HTTP ------------------------------------------

##**
# HTTP request via curl with retries and timeout.
# @param string $1 METHOD (GET|POST|PUT|DELETE|HEAD|PATCH)
# @param string $2 URL
# @param nameref $3 body_out
# @param nameref $4 status_out
# @option --timeout <sec>   default 15
# @option --header  'K: V'  repeatable
# @option --data    '...'   raw body; use @- to read from stdin
# @option --max-retry <n>   default 1
# @option --retry-delay <s> default 0.3
# @return int 0 on 2xx, else curl exit code
##*
boot::net::http() {
  local method="${1:?}" url="${2:?}"; shift 2
  local -n __body="${1:?}" __status="${2:?}"; shift 2
  local timeout=15 max_retry=1 retry_delay=0.3 data=""
  local -a headers=() curl_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="${2:?}"; shift 2;;
      --header)  headers+=("-H" "$2"); shift 2;;
      --data)    data="$2"; shift 2;;
      --max-retry) max_retry="${2:?}"; shift 2;;
      --retry-delay) retry_delay="${2:?}"; shift 2;;
      --) shift; break;;
      *) break;;
    esac
  done
  boot::require curl >/dev/null || { boot::log error "curl required"; return 127; }

  curl_args=( -sS -m "$timeout" -w '%{http_code}' -L "${headers[@]}" -X "$method" "$url" )
  local attempt=1 rc code raw err
  while :; do
    raw="$(mktemp)"; err="$(mktemp)"
    if [[ "$data" == @- ]]; then
      local stdin; stdin="$(cat -)"
      printf "%s" "$stdin" | curl "${curl_args[@]}" -d "@-" >"$raw" 2>"$err"; rc=$?
    elif [[ -n "$data" ]]; then
      curl "${curl_args[@]}" -d "$data" >"$raw" 2>"$err"; rc=$?
    else
      curl "${curl_args[@]}" >"$raw" 2>"$err"; rc=$?
    fi

    code="$(tail -c 3 "$raw" 2>/dev/null || printf "000")"
    __body="$(head -c -3 "$raw" 2>/dev/null || true)"
    __status="$code"
    rm -f -- "$raw"

    if (( rc==0 )) && [[ "$code" =~ ^2[0-9][0-9]$ ]]; then rm -f -- "$err"; return 0; fi
    if (( attempt >= max_retry )); then
      boot::log error "HTTP $method $url -> rc=$rc status=${code:-NA} $(<"$err")"
      rm -f -- "$err"
      return "$rc"
    fi
    boot::log warn "HTTP retry $attempt/$max_retry rc=$rc status=${code:-NA}"
    sleep "$retry_delay"
    attempt=$((attempt+1))
    rm -f -- "$err"
  done
}

##**
# Infer HTTP protocol version via curl (application-level).
# @param string $1 url
# @param nameref $2 version_out (e.g., 2, 1.1)
# @return int 0 on success
# @example
#   boot::net::http_version "https://example.com" v && echo "$v"
##*
boot::net::http_version() {
  local url="${1:?}"; local -n OUT="${2:?}"
  boot::require curl >/dev/null || { boot::log error "curl required"; return 127; }
  OUT="$(curl -sS -o /dev/null -w '%{http_version}' "$url" || printf "")"
  [[ -n "$OUT" ]]
}

# ------------------------------ TLS / ALPN ------------------------------------

##**
# Get TLS certificate expiry (days remaining + notAfter string).
# Uses OpenSSL s_client -> x509 and parses notAfter. Works behind SNI.
# @param string $1 host
# @param int    $2 port (default 443)
# @param nameref $3 days_out
# @param nameref $4 notafter_out
# @option --timeout <sec> default 8
# @return int 0 on success; 124 on timeout; 127 if openssl missing
# @example
#   boot::net::tls_expiry example.com 443 DAYS EXP && echo "$DAYS $EXP"
##*
boot::net::tls_expiry() {
  local host="${1:?}" port="${2:-443}"; shift 2 || true
  local -n DAYS="${1:?}" NOTAFTER="${2:?}"
  local timeout=8
  shift 2 || true
  if [[ "${1:-}" == "--timeout" ]]; then timeout="${2:?}"; shift 2; fi
  boot::require openssl >/dev/null || { boot::log error "openssl required"; return 127; }

  local out notafter rc=0
  out="$(boot::timeout "$timeout" -- bash -lc 'openssl s_client -servername "$0" -connect "$0":"$1" -showcerts < /dev/null 2>/dev/null | openssl x509 -noout -enddate' "$host" "$port")" || rc=$?
  (( rc!=0 )) && { (( rc==124 )) && return 124 || return 1; }
  notafter="${out#notAfter=}"
  NOTAFTER="$notafter"

  # Convert notAfter -> epoch seconds (GNU date / BSD date / Python3 fallback)
  local exp_epoch=""
  if date -d "$notafter" +%s >/dev/null 2>&1; then
    exp_epoch="$(date -d "$notafter" +%s)"
  elif date -j -f "%b %d %T %Y %Z" "$notafter" +%s >/dev/null 2>&1; then
    exp_epoch="$(date -j -f "%b %d %T %Y %Z" "$notafter" +%s)"
  elif command -v python3 >/dev/null 2>&1; then
    exp_epoch="$(python3 - <<'PY' "$notafter"
import sys,datetime
s=sys.argv[1]
try:
  dt=datetime.datetime.strptime(s, "%b %d %H:%M:%S %Y %Z")
  print(int(dt.timestamp()))
except Exception:
  print("")
PY
)"
  fi
  [[ -z "$exp_epoch" ]] && { boot::log error "failed to parse notAfter"; return 1; }
  local now_epoch; now_epoch="$(date +%s)"
  DAYS="$(( (exp_epoch - now_epoch) / 86400 ))"
  return 0
}

##**
# Check negotiated ALPN (TLS-level) using OpenSSL.
# @param string $1 host
# @param int    $2 port (default 443)
# @param nameref $3 proto_out (e.g., h2, http/1.1, none)
# @option --timeout <sec> default 8
# @return int 0 on success
# @example
#   boot::net::alpn "example.com" 443 P && echo "$P"
##*
boot::net::alpn() {
  local host="${1:?}" port="${2:-443}"; shift 2 || true
  local -n OUT="${1:?}"; shift || true
  local timeout=8
  if [[ "${1:-}" == "--timeout" ]]; then timeout="${2:?}"; shift 2; fi
  boot::require openssl >/dev/null || { boot::log error "openssl required"; return 127; }

  local txt rc=0
  txt="$(boot::timeout "$timeout" -- bash -lc 'openssl s_client -alpn "h2,http/1.1" -servername "$0" -connect "$0":"$1" < /dev/null 2>&1' "$host" "$port")" || rc=$?
  (( rc!=0 )) && { (( rc==124 )) && return 124 || return 1; }
  # Try ALPN first; fall back to NPN strings in older stacks.
  OUT="$(awk -F': ' '/ALPN protocol:/{print $2} /Next protocol/{print $3}' <<<"$txt" | head -n1)"
  [[ -z "$OUT" ]] && OUT="none"
  return 0
}

# ------------------------------ DNS / IP / Ports ------------------------------

boot::net::dns_a() {
  local name="${1:?}"; local -n OUT="${2:?}"; OUT=()
  if command -v getent >/dev/null 2>&1; then
    while read -r ip; do [[ -n "$ip" ]] && OUT+=("$ip"); done < <(getent ahosts "$name" | awk '{print $1}' | sort -u)
  elif command -v dig >/dev/null 2>&1; then
    while read -r ip; do [[ -n "$ip" ]] && OUT+=("$ip"); done < <( { dig +short A "$name"; dig +short AAAA "$name"; } )
  elif command -v host >/dev/null 2>&1; then
    while read -r ip; do [[ -n "$ip" ]] && OUT+=("$ip"); done < <(host "$name" | awk '/has address|IPv6/{print $NF}')
  else
    boot::log warn "dns_a: no resolver found"; return 127
  fi
}
boot::net::dns_rev() {
  local ip="${1:?}"
  if command -v host >/dev/null 2>&1; then host "$ip" | awk '/domain name pointer/{print $5}' | sed 's/\.$//'
  elif command -v dig  >/dev/null 2>&1; then dig +short -x "$ip" | sed 's/\.$//'
  else boot::log warn "dns_rev: no resolver"; return 127; fi
}

boot::net::port_open() {
  local host="${1:?}" port="${2:?}"
  if [[ -e /dev/tcp/localhost/0 ]]; then
    (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1
  else
    command -v nc >/dev/null 2>&1 && nc -z -w 2 "$host" "$port"
  fi
}
boot::net::wait_port() {
  local host="${1:?}" port="${2:?}"; shift 2
  local timeout=30
  if [[ "${1:-}" == "--timeout" ]]; then timeout="${2:?}"; shift 2; fi
  local t0 now; t0="$(date +%s)"
  boot::log notice "wait_port ${host}:${port} (timeout=${timeout}s)"
  while ! boot::net::port_open "$host" "$port"; do
    now="$(date +%s)"
    (( now - t0 >= ${timeout%.*} )) && { boot::log error "timeout ${host}:${port}"; return 124; }
    sleep 0.2
  done
  boot::log success "port open: ${host}:${port}"
}

return 0 2>/dev/null || true
