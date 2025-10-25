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

# --- Internals: tiny guards ---------------------------------------------------

##**
# Ensure that a given name refers to a callable entity.
# -----------------------------------------------------------------------------
# Accepts user-defined functions, builtins, keywords, or external executables
# available in PATH. Used internally to validate callbacks and predicates.
#
# @param string $1  Name to check.
# @return 0         If callable.
# @return 127       If not callable (prints an error to stderr).
#
# @example
#   boot::__require_callable my_func || exit 1
##**
boot::__require_callable() {
  local name="${1:?missing name}"
  if [[ "$(type -t -- "$name" 2>/dev/null)" =~ ^(function|file|builtin|keyword)$ ]]; then
    return 0
  fi
  printf 'boot: error: callback "%s" not found or not callable\n' "$name" >&2
  return 127
}

##**
# Ensure that a variable is a declared indexed array (declare -a).
# -----------------------------------------------------------------------------
# Validates a nameref target before mapping or filtering. Fails if undeclared
# or not an indexed array.
#
# @param string $1  Variable name to validate.
# @return 0         If valid indexed array.
# @return 2         If undeclared or not an indexed array (prints error).
#
# @example
#   local -a xs=(a b c)
#   boot::__require_array_var xs || exit 2
##**
boot::__require_array_var() {
  local var="${1:?missing var}"
  local decl
  if ! decl=$(declare -p -- "$var" 2>/dev/null); then
    printf 'boot: error: "%s" is not declared (expect indexed array)\n' "$var" >&2
    return 2
  fi
  if [[ ! "$decl" =~ ^declare\ -a\  ]]; then
    printf 'boot: error: "%s" is not an indexed array (declare -a ...)\n' "$var" >&2
    return 2
  fi
  return 0
}

##**
# Validate that a string is a valid shell identifier.
# -----------------------------------------------------------------------------
# Matches ^[a-zA-Z_][a-zA-Z0-9_]*$. Used to validate variable names for namerefs.
#
# @param string $1  Candidate identifier.
# @return 0         If valid identifier.
# @return 2         If invalid (prints error).
#
# @example
#   boot::__require_ident OUT_VAR || exit 2
##**
boot::__require_ident() {
  local v="${1:?}"
  [[ "$v" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && return 0
  printf 'boot: error: invalid identifier "%s"\n' "$v" >&2
  return 2
}

# --- Arrays (functional, nameref-safe) ---------------------------------------

##**
# Map an array through a callback function (value, index) -> echo result.
# -----------------------------------------------------------------------------
# Invokes the callback for each element of IN array and writes each result to
# OUT array. The callback must echo exactly one line per input. On callback
# failure (non-zero exit), the element is skipped with a warning.
#
# Usage:
#   boot::map IN_ARR OUT_ARR cb_func
#
# @param string $1  Name of input array (declare -a).
# @param string $2  Name of output array (declare -a).
# @param string $3  Callback function or command.
# @return 0         On success (skipped elements allowed).
# @return 2|127     On validation error.
#
# @example
#   to_upper(){ printf '%s' "${1^^}"; }
#   local -a xs=(a b c) ys=()
#   boot::map xs ys to_upper
#   # ys -> (A B C)
##**
boot::map() {
  local in_name="${1:?missing IN array}" out_name="${2:?missing OUT array}" cb="${3:?missing callback}"
  boot::__require_ident "$in_name"  && boot::__require_array_var "$in_name"  || return $?
  boot::__require_ident "$out_name" && boot::__require_callable "$cb"        || return $?

  local -n __in="$in_name" __out="$out_name"
  __out=()

  local i out
  for i in "${!__in[@]}"; do
    if ! out="$("$cb" "${__in[$i]}" "$i")"; then
      printf 'boot::map: warning: callback "%s" failed at index %s; skipping element\n' "$cb" "$i" >&2
      continue
    fi
    __out+=("$out")
  done
}

##**
# Filter an array using a predicate function (value, index) -> exit 0 to keep.
# -----------------------------------------------------------------------------
# Copies only elements for which the predicate returns success (0) into the
# OUT array. Non-zero exit codes exclude the element.
#
# Usage:
#   boot::filter IN_ARR OUT_ARR pred_func
#
# @param string $1  Name of input array (declare -a).
# @param string $2  Name of output array (declare -a).
# @param string $3  Predicate function or command.
# @return 0         On success.
# @return 2|127     On validation error.
#
# @example
#   is_even_len(){ (( ${#1} % 2 == 0 )); }
#   local -a xs=(a bb ccc dddd) ys=()
#   boot::filter xs ys is_even_len
#   # ys -> (bb dddd)
##**
boot::filter() {
  local in_name="${1:?missing IN array}" out_name="${2:?missing OUT array}" pd="${3:?missing predicate}"
  boot::__require_ident "$in_name"  && boot::__require_array_var "$in_name"  || return $?
  boot::__require_ident "$out_name" && boot::__require_callable "$pd"        || return $?

  local -n __in="$in_name" __out="$out_name"
  __out=()

  local i v
  for i in "${!__in[@]}"; do
    v="${__in[$i]}"
    if "$pd" "$v" "$i"; then
      __out+=("$v")
    fi
  done
}

##**
# Reduce an array using a reducer: (acc, value) -> echo new_acc.
# -----------------------------------------------------------------------------
# Iterates through each element of the IN array, calling reducer(acc, value)
# and updating the accumulator. If reducer fails (non-zero exit), the previous
# accumulator is kept and a warning is printed.
#
# Usage:
#   boot::reduce IN_ARR INIT_ACC OUT_SCALAR reducer_func
#
# @param string $1  Input array name (declare -a).
# @param string $2  Initial accumulator value.
# @param string $3  Output scalar variable name.
# @param string $4  Reducer function or command.
# @return 0         On success.
# @return 2|127     On validation error.
#
# @example
#   add(){ printf '%s' "$(( ${1:-0} + ${2:-0} ))"; }
#   local -a xs=(1 2 3); local sum=""
#   boot::reduce xs 0 sum add
#   # sum -> "6"
##**
boot::reduce() {
  local in_name="${1:?missing IN array}" acc="${2:?missing init acc}" out_name="${3:?missing OUT var}" rd="${4:?missing reducer}"
  boot::__require_ident "$in_name"  && boot::__require_array_var "$in_name" || return $?
  boot::__require_ident "$out_name" && boot::__require_callable "$rd"       || return $?

  local -n __in="$in_name" __out="$out_name"
  local v next
  for v in "${__in[@]}"; do
    if ! next="$("$rd" "$acc" "$v")"; then
      printf 'boot::reduce: warning: reducer "%s" failed; keeping previous acc\n' "$rd" >&2
      continue
    fi
    acc="$next"
  done
  __out="$acc"
}

##**
# Perform parallel map over an array (order-preserving).
# -----------------------------------------------------------------------------
# Executes callback(value, index) for each element concurrently, up to the
# specified concurrency level. Output order matches input order. Each callback’s
# stdout is captured as its result.
#
# If any job fails, the function exits with code 1 unless BOOT_PAR_MAP_SOFT=1
# is set (then only warnings are printed).
#
# Usage:
#   boot::par_map CONCURRENCY IN_ARR OUT_ARR cb_func
#
# Env:
#   BOOT_PAR_MAP_SOFT=1  Downgrade job failures to warnings.
#
# @param int    $1  Concurrency (>=1; 0 treated as 1).
# @param string $2  Input array name (declare -a).
# @param string $3  Output array name (declare -a).
# @param string $4  Callback function or command.
# @return 0         On success.
# @return 1         If any job failed (hard mode).
# @return 2|127     On validation error.
#
# @example
#   work(){ printf '%s-%s' "$1" "$2"; sleep 0.1; }
#   local -a xs=(A B C D) ys=()
#   boot::par_map 2 xs ys work
#   # ys -> (A-0 B-1 C-2 D-3)
##**
boot::par_map() {
  local conc="${1:?missing concurrency}"; shift || true
  local in_name="${1:?missing IN array}" out_name="${2:?missing OUT array}" cb="${3:?missing callback}"

  if [[ ! "$conc" =~ ^[0-9]+$ ]]; then
    printf 'boot::par_map: error: concurrency must be a non-negative integer\n' >&2
    return 2
  fi
  (( conc < 1 )) && conc=1

  boot::__require_ident "$in_name"  && boot::__require_array_var "$in_name"  || return $?
  boot::__require_ident "$out_name" && boot::__require_callable "$cb"        || return $?

  local -n __in="$in_name" __out="$out_name"
  __out=()

  local tmpd
  tmpd="$(mktemp -d -t boot_par_map.XXXXXX)" || { printf 'boot::par_map: mktemp failed\n' >&2; return 1; }
  local cleanup='_code=$?; rm -rf -- '"$tmpd"' 2>/dev/null || true; exit $_code'
  trap "$cleanup" EXIT INT TERM

  local -a pids=()
  local i pid running=0
  for i in "${!__in[@]}"; do
    {
      "$cb" "${__in[$i]}" "$i" >"${tmpd}/$i.out"
    } & pid=$!
    pids+=("$pid")
    (( running++ ))
    while (( running >= conc )); do
      if builtin help wait >/dev/null 2>&1 && wait -n 2>/dev/null; then
        (( running-- ))
      else
        wait "${pids[0]}" || true
        pids=("${pids[@]:1}")
        (( running-- ))
      fi
    done
  done

  local any_fail=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      any_fail=1
    fi
  done

  local idx
  for idx in "${!__in[@]}"; do
    if [[ -f "${tmpd}/$idx.out" ]]; then
      __out+=("$(<"${tmpd}/$idx.out")")
    else
      __out+=("")
    fi
  done

  if (( any_fail )) && [[ "${BOOT_PAR_MAP_SOFT:-0}" != "1" ]]; then
    printf 'boot::par_map: error: one or more tasks failed\n' >&2
    return 1
  elif (( any_fail )); then
    printf 'boot::par_map: warning: one or more tasks failed (soft mode)\n' >&2
  fi
}

##**
# Map over stdin lines via callback: (line, index) -> echo result.
# -----------------------------------------------------------------------------
# Reads from stdin using `read -r` (preserving backslashes) and invokes the
# callback for each line, passing both the line content and its zero-based index.
#
# Usage:
#   ... | boot::pipe_map cb
#
# @param string $1  Callback function or command.
# @return 0         On success.
# @return 127       If callback not callable.
#
# @example
#   print_idx(){ printf '%s => %s\n' "$2" "$1"; }
#   printf '%s\n' a b c | boot::pipe_map print_idx
##**
boot::pipe_map() {
  local cb="${1:?missing callback}"
  boot::__require_callable "$cb" || return $?
  local line i=0
  while IFS= read -r line; do
    "$cb" "$line" "$i"
    ((i++))
  done
}

##**
# Filter stdin lines via predicate: (line, index) -> exit 0 to keep.
# -----------------------------------------------------------------------------
# Reads lines from stdin and prints only those for which the predicate exits 0.
# Backslashes are preserved (`read -r`).
#
# Usage:
#   ... | boot::pipe_filter pred
#
# @param string $1  Predicate function or command.
# @return 0         On success.
# @return 127       If predicate not callable.
#
# @example
#   starts_with_hash(){ [[ "$1" == \#* ]]; }
#   printf '%s\n' "#a" "b" "#c" | boot::pipe_filter starts_with_hash
#   # Output: "#a" and "#c"
##**
boot::pipe_filter() {
  local pd="${1:?missing predicate}"
  boot::__require_callable "$pd" || return $?
  local line i=0
  while IFS= read -r line; do
    if "$pd" "$line" "$i"; then
      printf '%s\n' "$line"
    fi
    ((i++))
  done
}

return 0 2>/dev/null || true
