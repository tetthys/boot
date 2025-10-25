#!/usr/bin/env bash
# ==============================================================================
# @file boot/control.sh
# @brief Try/capture (stdout/stderr), backoff helpers, retry, timeout, exclusive lock.
# @since 1.3.0
# @version 1.3.1
# ------------------------------------------------------------------------------
# Safe, portable control-flow helpers for Bash 5+.
# - Works under `set -euo pipefail`.
# - Uses strict argument validation and clear return codes.
# - Prefers system tools when available (timeout/flock), with portable fallbacks.
# ==============================================================================

if [[ -n "${_BOOT_CONTROL_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_CONTROL_LOADED=1

##**
# Ensure a variable is a declared indexed array (declare -a).
#
# @param string $1  Variable name.
# @return 0         If indexed array.
# @return 2         If undeclared or not indexed.
##**
if ! command -v boot::__require_array_var >/dev/null 2>&1; then
  boot::__require_array_var() {
    local var="${1:?missing var}"
    local decl
    if ! decl=$(declare -p -- "$var" 2>/dev/null); then
      printf 'boot: error: "%s" not declared (expect indexed array)\n' "$var" >&2
      return 2
    fi
    [[ "$decl" =~ ^declare\ -a\  ]] || {
      printf 'boot: error: "%s" is not an indexed array (declare -a)\n' "$var" >&2
      return 2
    }
    return 0
  }
fi

##** Internal: uint checker (>=0). */
if ! command -v boot::__is_uint >/dev/null 2>&1; then
  boot::__is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
fi

##** Internal: best-effort logger (falls back to stderr if boot::log is absent). */
boot::__log() {
  local lvl="${1:-info}"; shift || true
  if boot::__has boot::log; then
    boot::log "$lvl" "$@"
  else
    printf '[%s] %s\n' "$lvl" "$*" >&2
  fi
}

##** Internal: mktemp file safely; prints path (uses 0600 via umask 077). */
boot::__mktemp_file() {
  local d="${1:-}"
  if [[ -n "$d" ]]; then
    mktemp "$d/.tmp.XXXXXXXX" 2>/dev/null || { printf 'boot: mktemp failed in %s\n' "$d" >&2; return 1; }
  else
    mktemp 2>/dev/null || { printf 'boot: mktemp failed\n' >&2; return 1; }
  fi
}

##** Internal: spawn command in a new process group if available. */
boot::__spawn_pg() {
  # setsid starts a new session; signals can be sent to -$pid to affect the group.
  if boot::__has setsid; then
    setsid "$@" &
  else
    "$@" &   # best-effort; the backgrounded process is commonly a group leader
  fi
}

# --- boot::try -----------------------------------------------------------------

##**
# Capture stdout and stderr of a command into distinct variables (by name).
# Uses secure temporary files and guarantees cleanup.
#
# Usage:
#   boot::try OUT_VAR ERR_VAR -- cmd args...
#
# @param string $1 OUT var name (identifier)
# @param string $2 ERR var name (identifier, must differ from OUT)
# @param --        optional separator
# @param string .. command and args to execute
# @return rc        command's exit code; OUT/ERR receive captured text
##**
boot::try() {
  local out_name="${1:?missing OUT var}" err_name="${2:?missing ERR var}"; shift 2
  [[ "${1:-}" == "--" ]] && shift

  boot::__require_ident "$out_name" || return $?
  boot::__require_ident "$err_name" || return $?
  [[ "$out_name" != "$err_name" ]] || { printf 'boot::try: OUT and ERR must differ\n' >&2; return 2; }

  local -n __out="$out_name" __err="$err_name"
  __out=""; __err=""

  local to te rc old_umask; old_umask=$(umask); umask 077
  to="$(boot::__mktemp_file)" || { umask "$old_umask"; return 1; }
  te="$(boot::__mktemp_file)" || { umask "$old_umask"; rm -f -- "$to"; return 1; }
  umask "$old_umask"

  if "$@" >"$to" 2>"$te"; then rc=0; else rc=$?; fi
  __out="$(<"$to")"
  __err="$(<"$te")"
  rm -f -- "$to" "$te" 2>/dev/null || true
  return "$rc"
}

# --- Backoff helpers -----------------------------------------------------------

##**
# Constant backoff: returns the base value.
# Requires: awk
#
# @param string $1 base seconds (float string; default 0.2)
# @return string    seconds as float
##**
boot::backoff_const(){ printf "%s\n" "${1:-0.2}"; }

##**
# Exponential backoff: base * 2^(n-1)
# Requires: awk
#
# @param string $1 base seconds (float string; default 0.2)
# @param int    $2 attempt index n (>=1; default 1)
# @return string    seconds as float
##**
boot::backoff_expo() {
  boot::__has awk || { printf '0.2\n'; return 0; }
  awk -v b="${1:-0.2}" -v n="${2:-1}" 'BEGIN{printf "%.6f\n", b*(2^(n-1))}'
}

##**
# Jittered backoff: uniform random in [0, base*n]
# Prefers $RANDOM; falls back to awk rand().
#
# @param string $1 base seconds (float string; default 0.5)
# @param int    $2 attempt index n (>=1; default 1)
# @return string    seconds as float
##**
boot::backoff_jitter(){
  local base="${1:-0.5}" n="${2:-1}" m
  boot::__has awk || { printf '%s\n' "$base"; return 0; }
  m="$(awk -v b="$base" -v n="$n" 'BEGIN{printf "%.6f\n", b*n}')"
  if [[ -n "${RANDOM:-}" ]]; then
    awk -v r="$RANDOM" -v m="$m" 'BEGIN{printf "%.6f\n", (r/32767.0)*m}'
  else
    awk -v m="$m" 'BEGIN{srand(); printf "%.6f\n", rand()*m}'
  fi
}

# --- Retry ---------------------------------------------------------------------

##**
# Retry a command up to N attempts, sleeping between attempts using a
# pluggable backoff function that is called as: backoff_fn BASE ATTEMPT_INDEX
# and must print the number of seconds to sleep.
#
# Usage:
#   boot::retry N backoff_fn BASE -- cmd args...
#
# Behavior:
#   - Returns immediately on first success (rc=0).
#   - On final failure, returns the last exit code from the command.
#   - Logs each retry with boot::log (warn) if available.
#
# @param int    $1 max attempts (>=1)
# @param string $2 backoff function name (callable)
# @param string $3 base seconds (float string; default 0.2)
# @param --         optional separator
# @param string ..  command and args
# @return rc        0 on success within N attempts; else last rc
##**
boot::retry() {
  local n="${1:?missing attempts}" fn="${2:?missing backoff fn}" base="${3:-0.2}"; shift 3
  [[ "${1:-}" == "--" ]] && shift

  boot::__is_uint "$n" || { boot::__log error "retry: attempts must be uint"; return 2; }
  (( n>=1 )) || { boot::__log error "retry: attempts must be >=1"; return 2; }
  boot::__require_callable "$fn" || return $?

  local i=1 rc d
  while :; do
    "$@" && return 0
    rc=$?
    (( i>=n )) && return "$rc"
    d="$("$fn" "$base" "$i")"
    boot::__log warn "retry $i/$n rc=$rc; sleep ${d}s"
    sleep "$d"
    ((i++))
  done
}

# --- Timeout -------------------------------------------------------------------

##**
# Run a command with a timeout. GNU `timeout` is used if present; otherwise a
# portable fallback creates a (best-effort) new process group and signals it.
#
# Usage:
#   boot::timeout SECONDS -- cmd args...
#
# Return codes:
#   - command's exit code on normal completion
#   - 124 on timeout (compatible with GNU timeout)
#
# Notes:
#   - Fallback computes an integer ceiling of SECONDS for simpler timing.
#   - Sends TERM then, after 1s grace, KILL to the (process group if possible).
#
# @param string $1 seconds (float or int)
# @param --        optional separator
# @param string .. command and args
# @return rc        command rc or 124 on timeout
##**
boot::timeout() {
  local sec="${1:?missing seconds}"; shift
  [[ "${1:-}" == "--" ]] && shift

  if boot::__has timeout; then
    timeout "$sec" "$@"
    return $?
  fi

  # Fallback: run in background; try to make it a group leader
  boot::__spawn_pg "$@"
  local pid=$!

  # ceil(seconds) for the watchdog
  local int_sec="0"
  if boot::__has awk; then
    int_sec="$(awk -v s="$sec" 'BEGIN{printf "%d\n", (s==int(s)?s:int(s)+1)}')"
  else
    int_sec="${sec%%.*}"
  fi

  (
    sleep "$int_sec"
    if kill -0 "$pid" 2>/dev/null; then
      # send TERM to group (negative pid) or to pid as fallback
      kill -TERM -"${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -0 "$pid" 2>/dev/null && { kill -KILL -"${pid}" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true; }
      exit 124
    else
      exit 0
    fi
  ) &
  local watchdog=$!

  local rc=0
  wait "$pid" || rc=$?

  # If main finished, stop watchdog.
  if kill -0 "$watchdog" 2>/dev/null; then
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$rc"
  fi

  # Watchdog already fired -> timeout
  return 124
}

# --- Lock ----------------------------------------------------------------------

##**
# Execute a command under an exclusive file lock.
# Favors flock(1); falls back to mkdir-based lock when flock is unavailable.
#
# Usage:
#   boot::with_lock /path/to/lockfile [--timeout SEC] -- cmd args...
#
# Return codes:
#   - command's rc on success
#   - 124 on timeout
#   - 2 on invalid usage
#
# Notes:
#   - Ensures the parent directory exists.
#   - Fallback uses a spin loop with light jitter to reduce contention thundering.
#
# @param string $1 lock path (file path; parent directory will be created)
# @option --timeout SEC  max wait seconds (integer; default 30)
# @param --              separator (required before command)
# @param string ..       command and args to run under the lock
# @return rc
##**
boot::with_lock() {
  local lock timeout="30"
  [[ $# -lt 1 ]] && { boot::__log error "with_lock: lock path required"; return 2; }
  lock="$1"; shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="${2:-30}"; shift 2;;
      --) shift; break;;
      *) break;;
    esac
  done
  [[ $# -gt 0 ]] || { boot::__log error "with_lock: command required"; return 2; }

  local parent; parent="$(dirname -- "$lock")"
  mkdir -p -- "$parent" || { boot::__log error "with_lock: cannot create dir $parent"; return 1; }

  if boot::__has flock; then
    : > "$lock" 2>/dev/null || true
    local __fd rc
    exec {__fd}>"$lock" || { boot::__log error "with_lock: open failed: $lock"; return 1; }
    if ! flock -x -w "${timeout%.*}" "$__fd"; then
      eval "exec $__fd>&-"
      boot::__log error "with_lock: timeout"
      return 124
    fi
    "$@"; rc=$?
    { flock -u "$__fd"; eval "exec $__fd>&-"; } 2>/dev/null || true
    return "$rc"
  fi

  # Fallback: mkdir spin with timeout
  local lockdir="${lock}.dlock" rc=0 acquired=0 t0 now limit
  t0=$(date +%s); limit="${timeout%.*}"
  trap '((acquired)) && rmdir -- "'"$lockdir"'" 2>/dev/null || true' INT TERM EXIT
  while ! mkdir -- "$lockdir" 2>/dev/null; do
    now=$(date +%s)
    if (( limit>0 && now - t0 >= limit )); then
      trap - INT TERM EXIT
      boot::__log error "with_lock: timeout (fallback)"
      return 124
    fi
    # light jitter (0~50ms) to reduce contention
    if [[ -n "${RANDOM:-}" ]] && boot::__has awk; then
      sleep "$(awk -v r="$RANDOM" 'BEGIN{printf "0.%03d\n", int((r/32767)*50)}')"
    else
      sleep 0.05
    fi
  done
  acquired=1
  "$@"; rc=$?
  rmdir -- "$lockdir" 2>/dev/null || true
  trap - INT TERM EXIT
  return "$rc"
}
