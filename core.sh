#!/usr/bin/env bash
# boot/core.sh - Minimal functional core for Bash 5+
# - No colors here; override boot::log in your own UI layer.
# - Circular nameref avoided (use __* internal names).
# - Pure, slim, reusable API only.

if [[ -n "${_BOOT_CORE_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_CORE_LOADED=1
BOOT_VERSION="1.3.0"

# --- Runtime guard -------------------------------------------------------------
if [[ -z "${BASH_VERSINFO[*]:-}" || "${BASH_VERSINFO[0]}" -lt 5 ]]; then
  printf >&2 "boot requires Bash 5+. current=%s\n" "${BASH_VERSION:-unknown}"
  return 1
fi

# --- Config --------------------------------------------------------------------
: "${BOOT_LOG_LEVEL:=info}"   # debug|info|notice|warn|error|success|silent
: "${BOOT_DEBUG_STACK:=1}"    # 1=print stacktrace on ERR
: "${BOOT_CACHE_DIR:=}"       # default resolves to XDG or ~/.cache/boot

# --- Strict / Traps / Defer ----------------------------------------------------

##**
# Enable strict/modern Bash flags for the current script.
# @effects Sets ERR trap to boot::on_err; enables pipefail, errexit, nounset.
# @usage
#   boot::strict
##*
boot::strict() {
  set -Eeuo pipefail
  shopt -s inherit_errexit lastpipe extglob 2>/dev/null || true
  trap 'boot::on_err $? $LINENO' ERR
}

##**
# Default error handler; prints a message and optional stack trace.
# @param int $1 Exit code
# @param int $2 Line number
##*
boot::on_err() {
  local c="${1:-1}" l="${2:-?}"
  boot::log error "ERR(${c}) at line ${l}"
  (( BOOT_DEBUG_STACK )) && boot::stacktrace >&2
}

# Stackable traps (functional, no globals leaking)
declare -A _BOOT_TRAPS=()

##**
# Push a trap handler without clobbering previous ones.
# @param string $1 SIGNAL (EXIT, INT, TERM, ...)
# @param string ...$2 handler body (single string)
##*
boot::trap_push() {
  local sig body prev
  sig="${1:?}"; shift
  body="${*:?}"
  prev="${_BOOT_TRAPS[$sig]:-}"
  if [[ -n "$prev" ]]; then
    _BOOT_TRAPS[$sig]="${prev}"$'\n'"$body"
  else
    _BOOT_TRAPS[$sig]="$body"
    trap "boot::trap_run '$sig'" "$sig"
  fi
}

##** @access private */
boot::trap_run() {
  local sig="$1" x
  local -a lines=()
  IFS=$'\n' read -r -d '' -a lines <<<"${_BOOT_TRAPS[$sig]:-}" 2>/dev/null || true
  for x in "${lines[@]}"; do eval -- "$x" || true; done
}

##**
# Pop the most recently pushed handler for a signal.
# @param string $1 SIGNAL
##*
boot::trap_pop() {
  local sig="${1:?}" prev
  prev="${_BOOT_TRAPS[$sig]:-}"
  [[ -z "$prev" ]] && return 0
  _BOOT_TRAPS[$sig]="$(awk 'NF{a[NR]=$0}END{for(i=1;i<NR;i++)print a[i]}' <<<"$prev")"
  if [[ -z "${_BOOT_TRAPS[$sig]}" ]]; then
    trap - "$sig" || true
    unset '_BOOT_TRAPS[$sig]'
  fi
}

# Deferred actions (LIFO)
declare -a _BOOT_DEFER=()

##** Register a deferred action (LIFO). */
boot::defer() { _BOOT_DEFER+=("$*"); }

##** Run all deferred actions, last-in-first-out. */
boot::defer_run() {
  local i
  for ((i=${#_BOOT_DEFER[@]}-1; i>=0; i--)); do eval -- "${_BOOT_DEFER[$i]}" || true; done
  _BOOT_DEFER=()
}

# --- Logging (plain) -----------------------------------------------------------

_boot::level_num() {
  case "${1,,}" in
    debug) echo 10 ;; success) echo 15 ;; info) echo 20 ;;
    notice) echo 25 ;; warn) echo 30 ;; error) echo 40 ;;
    silent) echo 99 ;; *) echo 20 ;;
  esac
}

##**
# Plain logger (UI can override).
# @param string $1 level
# @param string ...$2 message
##*
boot::log() {
  local lvl="${1:-info}"; shift || true
  local want="$(_boot::level_num "$BOOT_LOG_LEVEL")"
  local cur="$(_boot::level_num "$lvl")"
  (( cur < want )) && return 0
  printf "[boot:%s] %s\n" "$lvl" "$*"
}

# --- Basics --------------------------------------------------------------------

##** Ensure commands exist in PATH. Return 0 if all exist. */
boot::require() {
  local m=0 c
  for c in "$@"; do
    command -v -- "$c" >/dev/null 2>&1 || { m=1; boot::log warn "missing command: $c"; }
  done
  return $m
}

##** Return 0 if current file is sourced. */
boot::is_sourced() { [[ "${BASH_SOURCE[0]}" != "$0" ]]; }

##** Current epoch milliseconds. */
boot::now_ms() { printf "%s" "$(($(date +%s%3N)))"; }

##** Print simple stack trace to stdout. */
boot::stacktrace() {
  local i
  for (( i=1; i<${#FUNCNAME[@]}; i++ )); do
    printf "#%d %s (%s:%s)\n" \
      "$i" "${FUNCNAME[$i]:-?}" "${BASH_SOURCE[$i]:-?}" "${BASH_LINENO[$((i-1))]:-?}"
  done
}

##** Env getters (bool/int/string). */
boot::env_get_bool(){ local n="${1:?}" d="${2:-0}" v="${!n-}"; case "${v,,}" in 1|true|yes|on)echo 1;; 0|false|no|off|"")echo "$d";; *)echo "$d";; esac; }
boot::env_get_int() { local n="${1:?}" d="${2:-0}" v="${!n-}"; [[ "$v" =~ ^-?[0-9]+$ ]] && echo "$v" || echo "$d"; }
boot::env_get()     { local n="${1:?}" d="${2:-}"; [[ -n "${!n-}" ]] && echo "${!n}" || echo "$d"; }

# --- Try / Retry / Timeout / Lock ---------------------------------------------

##** Capture stdout/stderr of a command into variables (no circular nameref). */
boot::try() {
  local -n __out="${1:?}" __err="${2:?}"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  local to te rc; to="$(mktemp)"; te="$(mktemp)"
  if "$@" >"$to" 2>"$te"; then rc=0; else rc=$?; fi
  __out="$(<"$to")"; __err="$(<"$te")"
  rm -f -- "$to" "$te"
  return $rc
}

##** Backoff helpers. */
boot::backoff_const(){ printf "%s\n" "${1:-0.2}"; }
boot::backoff_expo() { awk -v b="${1:-0.2}" -v n="${2:-1}" 'BEGIN{printf "%.6f\n", b*(2^(n-1))}'; }
boot::backoff_jitter(){ awk -v m="$(awk -v b="${1:-0.5}" -v n="${2:-1}" 'BEGIN{print b*n}')" 'BEGIN{srand(); printf "%.6f\n", rand()*m}'; }

##** Retry a command with pluggable backoff (function name). */
boot::retry() {
  local n="${1:?}" fn="${2:?}" base="${3:-0.2}"; shift 3
  [[ "${1:-}" == "--" ]] && shift
  local i=1 rc d
  while :; do
    "$@" && return 0
    rc=$?
    (( i>=n )) && return "$rc"
    d="$("$fn" "$base" "$i")"
    boot::log warn "retry $i/$n rc=$rc sleep ${d}s"
    sleep "$d"
    ((i++))
  done
}

##** Timeout wrapper (uses GNU timeout if available, else soft fallback). */
boot::timeout() {
  local sec="${1:?}"; shift
  [[ "${1:-}" == "--" ]] && shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$sec" "$@"
  else
    ( "$@" ) & local pid=$!
    ( sleep "$sec"; kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true ) &
    wait "$pid"
  fi
}

##**
# Exclusive file lock. Prefer flock; fallback to mkdir lock.
# @option --timeout SEC (default: 30)
# @return command's rc, or 124 on timeout, 2 on invalid usage
##*
boot::with_lock() {
  local lock timeout="30"
  [[ $# -lt 1 ]] && { boot::log error "with_lock: lock path required"; return 2; }
  lock="$1"; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="${2:-30}"; shift 2;;
      --) shift; break;;
      *) break;;
    esac
  done
  [[ $# -gt 0 ]] || { boot::log error "with_lock: command required"; return 2; }
  local -a CMD=( "$@" )

  if command -v flock >/dev/null 2>&1; then
    local __fd rc
    mkdir -p -- "$(dirname -- "$lock")" || { boot::log error "with_lock: cannot create dir"; return 1; }
    : > "$lock" 2>/dev/null || true
    exec {__fd}>"$lock" || { boot::log error "with_lock: open failed"; return 1; }
    flock -x -w "$timeout" "$__fd" || { eval "exec $__fd>&-"; boot::log error "with_lock: timeout"; return 124; }
    "${CMD[@]}"; rc=$?
    { flock -u "$__fd"; eval "exec $__fd>&-"; } 2>/dev/null || true
    return "$rc"
  fi

  local lockdir="${lock}.dlock" rc=0 acquired=0 t0 now limit
  t0=$(date +%s); limit="${timeout%.*}"
  mkdir -p -- "$(dirname -- "$lockdir")" || { boot::log error "with_lock: cannot create parent"; return 1; }
  trap '((acquired)) && rmdir -- "'"$lockdir"'" 2>/dev/null || true' INT TERM EXIT
  while ! mkdir -- "$lockdir" 2>/dev/null; do
    now=$(date +%s)
    if (( limit>0 && now - t0 >= limit )); then trap - INT TERM EXIT; boot::log error "with_lock: timeout (fallback)"; return 124; fi
    sleep 0.1
  done
  acquired=1
  "${CMD[@]}"; rc=$?
  rmdir -- "$lockdir" 2>/dev/null || true
  trap - INT TERM EXIT
  return "$rc"
}

# --- Atomic I/O / Temp / Cache -------------------------------------------------

boot::with_tempdir() {
  local var="${1:?}"; shift
  [[ "${1:-}" == "--" ]] && shift
  local d; d="$(mktemp -d)"
  (
    trap 'rm -rf -- "$d"' EXIT
    printf -v "$var" '%s' "$d"
    "$@"
  )
}

boot::atomic_write(){ local dest="${1:?}" dir tmp; dir="$(dirname -- "$dest")"; tmp="$(mktemp "$dir/.tmp.XXXXXXXX")"; cat >"$tmp"; mv -f -- "$tmp" "$dest"; }
boot::readfile(){ local p="${1:?}"; [[ -r "$p" ]] && cat -- "$p"; }
boot::writefile(){ local p="${1:?}"; shift; printf "%s" "$*" | boot::atomic_write "$p"; }

boot::cache_dir(){ if [[ -n "$BOOT_CACHE_DIR" ]]; then printf "%s\n" "$BOOT_CACHE_DIR"; else printf "%s\n" "${XDG_CACHE_HOME:-$HOME/.cache}/boot"; fi; }
boot::cache_memo(){
  local key="${1:?}" ttl="${2:-0}"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  local dir file now mt tmp
  dir="$(boot::cache_dir)"; mkdir -p -- "$dir"
  file="$dir/$(printf "%s" "$key" | sha1sum | awk '{print $1}').cache"
  if [[ -r "$file" && $ttl -gt 0 ]]; then
    now=$(date +%s); mt=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0)
    (( now-mt<=ttl )) && { cat -- "$file"; return 0; }
  fi
  tmp="$(mktemp "$dir/.tmp.XXXXXX")"
  if "$@" >"$tmp"; then mv -f -- "$tmp" "$file"; cat -- "$file"; else rm -f -- "$tmp"; return 1; fi
}

# --- IDs & Versions ------------------------------------------------------------

##**
# Generate a simple non-cryptographic random ID string.
# Uses time (ns) + RANDOM entropy.
# @return string id
# @example
#   id="$(boot::id_rand)"; echo "$id"
#   # → 1730123456123456789-12345-6789
##*
boot::id_rand() {
  local t n r1 r2
  # date +%s%N is nanosecond epoch (Linux only; fallback to seconds)
  t="$(date +%s%N 2>/dev/null || date +%s)"
  r1=$RANDOM
  r2=$RANDOM
  printf '%s-%d-%d\n' "$t" "$r1" "$r2"
}

##**
# Compare two semantic version strings (a.b.c).
# Returns: -1 if a<b, 0 if equal, 1 if a>b.
# Handles missing minor/patch by treating them as 0.
# @param string $1 version A
# @param string $2 version B
# @return int comparison result (-1|0|1)
# @example
#   boot::semver_cmp 1.2.3 1.10.0   # -> -1
#   boot::semver_cmp 2.0 1.9.9      # -> 1
#   boot::semver_cmp 1.0.0 1.0.0    # -> 0
##*
boot::semver_cmp() {
  local verA="${1:-}" verB="${2:-}"
  if [[ -z "$verA" || -z "$verB" ]]; then
    printf '%s\n' "0"
    return 0
  fi

  local IFS=.
  local -a A=() B=()
  # shellcheck disable=SC2206
  A=($verA)
  # shellcheck disable=SC2206
  B=($verB)

  local i x y
  for i in 0 1 2; do
    x="${A[i]:-0}"
    y="${B[i]:-0}"
    # Force numeric compare; strip leading zeros
    ((10#$x < 10#$y)) && { printf '%s\n' "-1"; return 0; }
    ((10#$x > 10#$y)) && { printf '%s\n' "1";  return 0; }
  done
  printf '%s\n' "0"
}

return 0 2>/dev/null || true
