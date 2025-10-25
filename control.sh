#!/usr/bin/env bash
# ==============================================================================
# @file boot/control.sh
# @brief Try/capture, backoff, retry, timeout, exclusive lock helpers.
# @since 1.3.0
# @version 1.3.0
# ==============================================================================

if [[ -n "${_BOOT_CONTROL_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_CONTROL_LOADED=1

##** Internal: mktemp file safely; prints path. */
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
  if boot::__has setsid; then
    setsid "$@" &
  else
    "$@" &
  fi
}

##**
# boot::try — capture stdout/stderr of a command into variables.
# Usage: boot::try OUT_VAR ERR_VAR -- cmd args...
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
  __out="$(<"$to")"; __err="$(<"$te")"
  rm -f -- "$to" "$te" 2>/dev/null || true
  return "$rc"
}

# --- Backoff helpers -----------------------------------------------------------

boot::backoff_const(){ printf "%s\n" "${1:-0.2}"; }
boot::backoff_expo() { awk -v b="${1:-0.2}" -v n="${2:-1}" 'BEGIN{printf "%.6f\n", b*(2^(n-1))}'; }
boot::backoff_jitter(){
  local base="${1:-0.5}" n="${2:-1}" m
  m="$(awk -v b="$base" -v n="$n" 'BEGIN{printf "%.6f\n", b*n}')"
  if [[ -n "${RANDOM:-}" ]]; then
    awk -v r="$RANDOM" -v m="$m" 'BEGIN{printf "%.6f\n", (r/32767.0)*m}'
  else
    awk -v m="$m" 'BEGIN{srand(); printf "%.6f\n", rand()*m}'
  fi
}

# --- Retry ---------------------------------------------------------------------

##**
# Retry a command with a pluggable backoff function.
# Usage: boot::retry N backoff_fn BASE -- cmd args...
##**
boot::retry() {
  local n="${1:?missing attempts}" fn="${2:?missing backoff fn}" base="${3:-0.2}"; shift 3
  [[ "${1:-}" == "--" ]] && shift
  boot::__is_uint "$n" || { boot::log error "retry: attempts must be uint"; return 2; }
  (( n>=1 )) || { boot::log error "retry: attempts must be >=1"; return 2; }
  boot::__require_callable "$fn" || return $?

  local i=1 rc d
  while :; do
    "$@" && return 0
    rc=$?
    (( i>=n )) && return "$rc"
    d="$("$fn" "$base" "$i")"
    boot::log warn "retry $i/$n rc=$rc; sleep ${d}s"
    sleep "$d"
    ((i++))
  done
}

# --- Timeout -------------------------------------------------------------------

##**
# Timeout wrapper: GNU timeout if present, else portable fallback (pgid+signals).
# Returns 124 on timeout.
# Usage: boot::timeout SECONDS -- cmd args...
##**
boot::timeout() {
  local sec="${1:?missing seconds}"; shift
  [[ "${1:-}" == "--" ]] && shift

  if boot::__has timeout; then
    timeout "$sec" "$@"; return $?
  fi

  boot::__spawn_pg "$@"
  local pid=$!
  local int_sec
  int_sec="$(awk -v s="$sec" 'BEGIN{printf "%d\n", (s==int(s)?s:int(s)+1)}')"

  (
    sleep "$int_sec"
    if kill -0 "$pid" 2>/dev/null; then
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

  if kill -0 "$watchdog" 2>/dev/null; then
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$rc"
  fi
  return 124
}

# --- Lock ----------------------------------------------------------------------

##**
# Exclusive file lock (flock preferred; mkdir fallback).
# Usage: boot::with_lock /path/lockfile [--timeout SEC] -- cmd args...
##**
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

  local parent; parent="$(dirname -- "$lock")"
  mkdir -p -- "$parent" || { boot::log error "with_lock: cannot create dir $parent"; return 1; }

  if boot::__has flock; then
    : > "$lock" 2>/dev/null || true
    local __fd rc
    exec {__fd}>"$lock" || { boot::log error "with_lock: open failed: $lock"; return 1; }
    if ! flock -x -w "${timeout%.*}" "$__fd"; then
      eval "exec $__fd>&-"
      boot::log error "with_lock: timeout"
      return 124
    fi
    "$@"; rc=$?
    { flock -u "$__fd"; eval "exec $__fd>&-"; } 2>/dev/null || true
    return "$rc"
  fi

  local lockdir="${lock}.dlock" rc=0 acquired=0 t0 now limit
  t0=$(date +%s); limit="${timeout%.*}"
  trap '((acquired)) && rmdir -- "'"$lockdir"'" 2>/dev/null || true' INT TERM EXIT
  while ! mkdir -- "$lockdir" 2>/dev/null; do
    now=$(date +%s)
    if (( limit>0 && now - t0 >= limit )); then
      trap - INT TERM EXIT
      boot::log error "with_lock: timeout (fallback)"
      return 124
    fi
    if [[ -n "${RANDOM:-}" ]]; then
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
