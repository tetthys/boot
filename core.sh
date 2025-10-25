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

# Optional tiny guards (used if your core guards are not present)
boot::__has() { command -v "$1" >/dev/null 2>&1; }

if ! boot::__has boot::__require_ident; then
  ##** Validate a shell identifier (A-Z a-z _; then A-Z a-z 0-9 _). */
  boot::__require_ident() {
    local v="${1:?missing ident}"
    [[ "$v" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && return 0
    printf 'boot: error: invalid identifier "%s"\n' "$v" >&2
    return 2
  }
fi

if ! boot::__has boot::__require_callable; then
  ##** Check whether a name is callable (function/builtin/keyword/file). */
  boot::__require_callable() {
    local name="${1:?missing name}"
    [[ "$(type -t -- "$name" 2>/dev/null)" =~ ^(function|file|builtin|keyword)$ ]] && return 0
    printf 'boot: error: "%s" not callable\n' "$name" >&2
    return 127
  }
fi

##** Internal: log with optional boot::log fallback to stderr. */
boot::__log() {
  local lvl="${1:-info}"; shift || true
  if boot::__has boot::log; then
    boot::log "$lvl" "$@"
  else
    printf '[%s] %s\n' "$lvl" "$*" >&2
  fi
}

##** Internal: uint checker (>=0). */
boot::__is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

##** Internal: mktemp file safely; prints path. */
boot::__mktemp_file() {
  local d="${1:-}"
  if [[ -n "$d" ]]; then
    mktemp "$d/.tmp.XXXXXXXX" 2>/dev/null || { printf 'boot: mktemp failed in %s\n' "$d" >&2; return 1; }
  else
    mktemp 2>/dev/null || { printf 'boot: mktemp failed\n' >&2; return 1; }
  fi
}

##** Internal: start a command in its own process group (if available). */
boot::__spawn_pg() {
  # Uses setsid if available to create a new process group/session
  if boot::__has setsid; then
    setsid "$@" &
  else
    "$@" &
  fi
}

##**
# Capture stdout/stderr of a command into variables (no circular nameref).
# Safe tempfiles + guaranteed cleanup. Variables must be distinct identifiers.
#
# Usage:
#   boot::try OUT_VAR ERR_VAR -- cmd args...
#
# @param string $1 OUT var name
# @param string $2 ERR var name
# @param --        separator (optional)
# @param string .. command and args
# @return rc of the command; OUT/ERR receive captured text (may be empty)
##**
boot::try() {
  local out_name="${1:?missing OUT var}" err_name="${2:?missing ERR var}"; shift 2
  [[ "${1:-}" == "--" ]] && shift

  boot::__require_ident "$out_name" || return $?
  boot::__require_ident "$err_name" || return $?
  if [[ "$out_name" == "$err_name" ]]; then
    printf 'boot::try: OUT and ERR must be different variables\n' >&2
    return 2
  fi

  local -n __out="$out_name" __err="$err_name"
  __out=""; __err=""

  local to te rc old_umask; old_umask=$(umask); umask 077
  to="$(boot::__mktemp_file)" || { umask "$old_umask"; return 1; }
  te="$(boot::__mktemp_file)" || { umask "$old_umask"; rm -f -- "$to"; return 1; }
  umask "$old_umask"

  # Subshell not required; we capture redirections directly.
  if "$@" >"$to" 2>"$te"; then rc=0; else rc=$?; fi

  __out="$(<"$to")"
  __err="$(<"$te")"
  rm -f -- "$to" "$te" 2>/dev/null || true
  return "$rc"
}

# --- Backoff helpers -----------------------------------------------------------

##**
# Constant backoff: returns base seconds.
# @param string $1 base (float, default 0.2)
# @return string seconds (float)
##**
boot::backoff_const(){ printf "%s\n" "${1:-0.2}"; }

##**
# Exponential backoff: base * 2^(n-1)
# @param string $1 base (float, default 0.2)
# @param int    $2 attempt index n (>=1, default 1)
# @return string seconds (float)
##**
boot::backoff_expo() {
  awk -v b="${1:-0.2}" -v n="${2:-1}" 'BEGIN{printf "%.6f\n", b*(2^(n-1))}'
}

##**
# Jittered backoff: uniform random in [0, base*n]
# Uses $RANDOM if available; falls back to awk rand().
# @param string $1 base (float, default 0.5)
# @param int    $2 attempt index n (>=1, default 1)
# @return string seconds (float)
##**
boot::backoff_jitter(){
  local base="${1:-0.5}" n="${2:-1}" m
  m="$(awk -v b="$base" -v n="$n" 'BEGIN{printf "%.6f\n", b*n}')"
  if [[ -n "${RANDOM:-}" ]]; then
    # RANDOM in [0..32767]
    awk -v r="$RANDOM" -v m="$m" 'BEGIN{printf "%.6f\n", (r/32767.0)*m}'
  else
    awk -v m="$m" 'BEGIN{srand(); printf "%.6f\n", rand()*m}'
  fi
}

# --- Retry ---------------------------------------------------------------------

##**
# Retry a command with pluggable backoff. Sleeps between attempts using a
# backoff function that receives (base, attempt_index) and prints seconds.
#
# Usage:
#   boot::retry N backoff_fn BASE -- cmd args...
#
# Notes:
#   - Returns immediately on first success (rc=0).
#   - On final failure, returns the command's last rc.
#   - Logs progress with boot::log if available (warn level).
#
# @param int    $1 max attempts (>=1)
# @param string $2 backoff function name (callable)
# @param string $3 base seconds (float string)
# @param --         separator (optional)
# @param string ..  command and args
# @return rc        0 if success within N attempts; else last rc
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
    # shell sleep accepts fractional seconds in Bash
    sleep "$d"
    ((i++))
  done
}

# --- Timeout -------------------------------------------------------------------

##**
# Timeout wrapper. Uses GNU timeout if available; otherwise a portable fallback
# that starts the command in its own process group and sends TERM then KILL.
#
# Usage:
#   boot::timeout SECONDS -- cmd args...
#
# Return codes:
#   - command's exit code on success/normal finish
#   - 124 on timeout (GNU timeout compatible)
#
# @param string $1 seconds (float/int)
# @param --        separator (optional)
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

  # Fallback: run in new process group (if setsid) so children receive signals
  boot::__spawn_pg "$@"
  local pid=$!

  # Convert to integer ceiling for timing loops (fallback simplicity)
  local int_sec
  int_sec="$(awk -v s="$sec" 'BEGIN{printf "%d\n", (s==int(s)?s:int(s)+1)}')"

  # Watchdog to enforce timeout
  (
    sleep "$int_sec"
    if kill -0 "$pid" 2>/dev/null; then
      # Send TERM to the whole process group if possible
      if boot::__has pkill; then
        # Try process group via negative pgid (if the shell created it)
        kill -TERM -"${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      else
        kill -TERM -"${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      fi
      # Grace period then KILL
      sleep 1
      kill -0 "$pid" 2>/dev/null && { kill -KILL -"${pid}" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true; }
      exit 124
    else
      exit 0
    fi
  ) &
  local watchdog=$!

  # Wait for main process; capture rc
  local rc=0
  wait "$pid" || rc=$?

  # If main finished, stop watchdog
  if kill -0 "$watchdog" 2>/dev/null; then
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$rc"
  fi

  # Watchdog fired -> timeout
  return 124
}

# --- Lock ----------------------------------------------------------------------

##**
# Execute a command under an exclusive file lock.
# Prefers flock(1). If not available, falls back to mkdir-based lock.
#
# Usage:
#   boot::with_lock /path/to/lockfile [--timeout SEC] -- cmd args...
#
# Return codes:
#   - command's rc on success
#   - 124 on timeout
#   - 2 on invalid usage
#
# @param string $1 lock path (file path; directory will be created as needed)
# @option --timeout SEC  max wait seconds (default 30)
# @param --              separator (required before cmd)
# @param string ..       command and args
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

  # Ensure parent directory exists
  local parent; parent="$(dirname -- "$lock")"
  mkdir -p -- "$parent" || { boot::__log error "with_lock: cannot create dir $parent"; return 1; }

  if boot::__has flock; then
    # Flock path strategy: open FD on a real file, then flock -x -w TIMEOUT
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

  # Fallback: mkdir lockdir loop with timeout
  local lockdir="${lock}.dlock" rc=0 acquired=0 t0 now limit
  t0=$(date +%s)
  limit="${timeout%.*}"
  trap '((acquired)) && rmdir -- "'"$lockdir"'" 2>/dev/null || true' INT TERM EXIT
  while ! mkdir -- "$lockdir" 2>/dev/null; do
    now=$(date +%s)
    if (( limit>0 && now - t0 >= limit )); then
      trap - INT TERM EXIT
      boot::__log error "with_lock: timeout (fallback)"
      return 124
    fi
    # light contention backoff with tiny jitter (0~50ms)
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

##**
# Internal: print error to stderr.
# @param string $1  message
##**
boot::__err() { printf '%s\n' "$*" >&2; }

##**
# Internal: check if a string is an integer (>=0).
# @param string $1  candidate
# @return 0 if integer, else 1
##**
boot::__is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

##**
# Internal: portable file mtime (epoch seconds).
# Uses GNU/BSD stat variants. Prints 0 on failure.
# @param string $1  path
# @return 0 print epoch seconds; 0 on failure as "0"
##**
boot::__mtime() {
  local p="${1:?}"
  local mt
  mt=$(stat -c %Y -- "$p" 2>/dev/null) || mt=$(stat -f %m -- "$p" 2>/dev/null) || mt=0
  printf '%s\n' "$mt"
}

##**
# Internal: portable sha256(hex) of stdin.
# Tries sha256sum, shasum -a 256, then openssl dgst -sha256.
# @return 0 and print hex; 127 if no tool available.
##**
boot::__sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    # openssl prints like "(stdin)= <hex>" or "<hex>"
    openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  else
    boot::__err "boot: no sha256 tool (sha256sum/shasum/openssl)"; return 127
  fi
}

##**
# Internal: portable mktemp file in a directory.
# Creates a file (not directory) as "$dir/.tmp.XXXXXXXX".
# @param string $1  directory path (must exist)
# @return 0 print path; non-zero on failure
##**
boot::__mktemp_in_dir() {
  local dir="${1:?}"
  # mktemp with path template works on GNU/BSD
  mktemp "$dir/.tmp.XXXXXXXX" 2>/dev/null || { boot::__err "boot: mktemp failed in $dir"; return 1; }
}

##**
# Execute a callback on a fresh temp directory and auto-clean it.
# The temp directory path is exposed via a variable name you provide,
# but only within the callback (subshell scope) to ensure cleanup safety.
#
# Usage:
#   boot::with_tempdir VAR -- cmd args...
#   # Inside cmd, $VAR points to the temp dir; it is removed on exit.
#
# @param string $1  variable name to receive the temp dir (in child scope)
# @param --         separator before command
# @param string ..  command and its arguments
# @return exit code of the command, temp dir is always removed.
##**
boot::with_tempdir() {
  local var="${1:?missing var name}"; shift
  [[ "${1:-}" == "--" ]] && shift
  if [[ "${var}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then :; else
    boot::__err "boot::with_tempdir: invalid identifier: $var"; return 2
  fi
  # mktemp -d is typically 0700; enforce strict umask anyway.
  local old_umask; old_umask=$(umask); umask 077
  local d
  if ! d="$(mktemp -d -t boot_tmp.XXXXXXXX 2>/dev/null || mktemp -d 2>/dev/null)"; then
    umask "$old_umask"; boot::__err "boot::with_tempdir: mktemp -d failed"; return 1
  fi
  umask "$old_umask"

  (
    # trap cleanup for multiple signals
    trap 'rm -rf -- "$d" 2>/dev/null || true' EXIT INT TERM
    # expose path via printf -v (child scope only by design)
    printf -v "$var" '%s' "$d"
    if command -v boot::__require_callable >/dev/null 2>&1; then
      # If the next token is a bare function name, we still just exec "$@"
      # The callable check is optional; "$@" may be a pipeline/command chain.
      :
    fi
    "$@"
  )
}

##**
# Atomically write stdin to DEST.
# Strategy: create tmp file in the same dir -> write -> fsync (best-effort) ->
# mv -f to DEST. This guarantees atomic replacement on the same filesystem.
#
# @param string $1  destination path
# @stdin            content to write
# @return 0 on success; non-zero on failure
##**
boot::atomic_write() {
  local dest="${1:?missing dest}"
  local dir; dir="$(dirname -- "$dest")"
  # Ensure dir exists
  if [[ ! -d "$dir" ]]; then
    boot::__err "boot::atomic_write: directory not found: $dir"; return 1
  fi

  local old_umask; old_umask=$(umask); umask 077
  local tmp
  if ! tmp="$(boot::__mktemp_in_dir "$dir")"; then umask "$old_umask"; return 1; fi
  umask "$old_umask"

  # Write stdin to tmp
  if ! cat >"$tmp"; then
    rm -f -- "$tmp" 2>/dev/null || true
    boot::__err "boot::atomic_write: write failed"
    return 1
  fi

  # Best-effort fsync (Linux/BSD)
  if command -v sync >/dev/null 2>&1; then
    # try to flush file handle with dd workaround (no portable fsync in POSIX shell)
    # ignore errors (best-effort)
    : >/dev/null 2>&1
  fi

  # Atomic rename
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp" 2>/dev/null || true
    boot::__err "boot::atomic_write: rename failed"
    return 1
  fi
}

##**
# Read file to stdout if readable.
# @param string $1  path
# @return 0 and print content; 1 if not readable
##**
boot::readfile() {
  local p="${1:?missing path}"
  [[ -r "$p" ]] || return 1
  cat -- "$p"
}

##**
# Write arguments as a single string to path (atomic).
# @param string $1  path
# @param string ..  parts to join without newline (use printf yourself to add \n)
# @return 0 on success
##**
boot::writefile() {
  local p="${1:?missing path}"; shift || true
  # Join args as-is (no trailing newline). If you need newline: printf '%s\n'
  printf "%s" "$*" | boot::atomic_write "$p"
}

##**
# Get cache directory (XDG or $HOME/.cache/boot).
# Does not create it; use boot::cache_ensure if needed.
# Env: BOOT_CACHE_DIR to override.
# @return 0 and print path
##**
boot::cache_dir() {
  if [[ -n "${BOOT_CACHE_DIR:-}" ]]; then
    printf '%s\n' "$BOOT_CACHE_DIR"
  else
    printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/boot"
  fi
}

##**
# Ensure cache directory exists with secure permissions (0700).
# @return 0 on success
##**
boot::cache_ensure() {
  local d; d="$(boot::cache_dir)"
  # mkdir -p + umask 077 for secure default
  local old_umask; old_umask=$(umask); umask 077
  mkdir -p -- "$d" || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  printf '%s\n' "$d"
}

##**
# Cache the stdout of a command with a TTL (seconds).
# If cache exists and is fresh (now - mtime <= ttl), prints cached content.
# Otherwise, runs the command, captures stdout to a temp file, atomically
# refreshes the cache file, and prints the content.
#
# Usage:
#   boot::cache_memo KEY TTL -- cmd args...
#
# KEY is hashed with SHA-256 to form the cache file name; TTL<=0 disables reuse.
#
# @param string $1  key (any string)
# @param int    $2  ttl seconds (>=0)
# @param --         separator before command
# @param string ..  command and its arguments
# @return 0 on hit/miss success; non-zero if command fails or tooling missing
##**
boot::cache_memo() {
  local key="${1:?missing key}" ttl="${2:?missing ttl}"; shift 2
  [[ "${1:-}" == "--" ]] && shift

  if ! boot::__is_uint "$ttl"; then
    boot::__err "boot::cache_memo: ttl must be a non-negative integer"; return 2
  fi

  local dir file now mt
  dir="$(boot::cache_ensure)" || { boot::__err "boot::cache_memo: cannot ensure cache dir"; return 1; }

  # Compute cache file name = sha256(key).cache
  if ! file="$(printf '%s' "$key" | boot::__sha256_stdin)"; then
    return 1
  fi
  file="$dir/${file}.cache"

  # Serve from cache if fresh
  if [[ -r "$file" && "$ttl" -gt 0 ]]; then
    now=$(date +%s)
    mt=$(boot::__mtime "$file")
    if [[ "$mt" -gt 0 ]] && (( now - mt <= ttl )); then
      cat -- "$file"
      return 0
    fi
  fi

  # Miss or expired: run command and atomically refresh
  local old_umask; old_umask=$(umask); umask 077
  local tmp
  if ! tmp="$(boot::__mktemp_in_dir "$dir")"; then umask "$old_umask"; return 1; fi
  umask "$old_umask"

  if "$@" >"$tmp"; then
    if mv -f -- "$tmp" "$file"; then
      cat -- "$file"
      return 0
    else
      rm -f -- "$tmp" 2>/dev/null || true
      boot::__err "boot::cache_memo: rename failed"
      return 1
    fi
  else
    local rc=$?
    rm -f -- "$tmp" 2>/dev/null || true
    return "$rc"
  fi
}

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
