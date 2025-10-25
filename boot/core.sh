# boot/core.sh - Minimal modern core for Bash 5+
# No colors here; ui.sh may override boot::log.

if [[ -n "${_BOOT_CORE_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_CORE_LOADED=1
BOOT_VERSION="1.2.0"

# --- Runtime guard ------------------------------------------------------------
if [[ -z "${BASH_VERSINFO[*]:-}" || "${BASH_VERSINFO[0]}" -lt 5 ]]; then
  printf >&2 "boot requires Bash 5+. current=%s\n" "${BASH_VERSION:-unknown}"
  return 1
fi

# --- Config -------------------------------------------------------------------
: "${BOOT_LOG_LEVEL:=info}"   # debug|info|notice|warn|error|success|silent
: "${BOOT_DEBUG_STACK:=1}"    # 1=print stacktrace on ERR
: "${BOOT_CACHE_DIR:=}"       # default resolves to XDG or ~/.cache/boot

# --- Strict / Traps / Defer ---------------------------------------------------

##**
# Enable strict/modern Bash flags for the current script.
# @since 1.2.0
# @effects Sets ERR trap to boot::on_err; enables pipefail, errexit, nounset.
# @usage
#   Call at the top of your script after sourcing boot.sh.
# @example
#   source ./boot.sh
#   boot::strict
#   main() { echo "safe mode"; }
#   main
##*
boot::strict() {
  set -Eeuo pipefail
  shopt -s inherit_errexit lastpipe extglob 2>/dev/null || true
  trap 'boot::on_err $? $LINENO' ERR
}

##**
# Default error handler invoked by ERR trap.
# @param int $1 Exit code
# @param int $2 Line number
# @since 1.2.0
# @effects Prints log and optional stacktrace.
# @example
#   boot::strict  # will auto wire ERR -> boot::on_err
#   false         # triggers boot::on_err with stack (if BOOT_DEBUG_STACK=1)
##*
boot::on_err() {
  local c="${1:-1}" l="${2:-?}"
  boot::log error "ERR(${c}) at line ${l}"
  (( BOOT_DEBUG_STACK )) && boot::stacktrace >&2
}

declare -A _BOOT_TRAPS=()

##**
# Push a trap handler without clobbering previous ones.
# @param string $1 SIGNAL (e.g., EXIT, INT)
# @param string ...$2 Handler body (single string)
# @since 1.2.0
# @example
#   boot::trap::push EXIT 'echo "cleanup"'
#   boot::trap::push INT  'echo "ctrl-c"'
##*
boot::trap::push() {
  local sig body prev
  sig="${1:?}"; shift
  body="${*:?}"
  prev="${_BOOT_TRAPS[$sig]:-}"
  if [[ -n "$prev" ]]; then
    _BOOT_TRAPS[$sig]="${prev}"$'\n'"$body"
  else
    _BOOT_TRAPS[$sig]="$body"
    trap "boot::trap::run '$sig'" "$sig"
  fi
}

##**
# Internal runner for stacked traps.
# @param string $1 SIGNAL
# @access private
##*
boot::trap::run()  {
  local sig="$1"
  local -a lines=()
  IFS=$'\n' read -r -d '' -a lines <<<"${_BOOT_TRAPS[$sig]:-}" 2>/dev/null || true
  local x
  for x in "${lines[@]}"; do eval -- "$x" || true; done
}

##**
# Pop the most recently pushed handler for a signal.
# @param string $1 SIGNAL
# @since 1.2.0
# @example
#   boot::trap::pop EXIT
##*
boot::trap::pop()  {
  local sig="${1:?}" prev
  prev="${_BOOT_TRAPS[$sig]:-}"
  [[ -z "$prev" ]] && return 0
  _BOOT_TRAPS[$sig]="$(awk 'NF{a[NR]=$0}END{for(i=1;i<NR;i++)print a[i]}' <<<"$prev")"
  if [[ -z "${_BOOT_TRAPS[$sig]}" ]]; then
    trap - "$sig" || true
    unset '_BOOT_TRAPS[$sig]'
  fi
}

declare -a _BOOT_DEFER=()

##**
# Register a deferred action to run later (LIFO).
# @param string ...$1 Body to eval on run
# @since 1.2.0
# @usage
#   Use for temp resources (dirs/files) that must be removed.
# @example
#   tmp="$(mktemp -d)"
#   boot::defer 'rm -rf -- "$tmp"'
##*
boot::defer() { _BOOT_DEFER+=("$*"); }

##**
# Execute all deferred actions in reverse order.
# @since 1.2.0
# @example
#   boot::defer 'echo third'
#   boot::defer 'echo second'
#   boot::defer 'echo first'
#   boot::defer::run  # prints: first, second, third
##*
boot::defer::run() {
  local i
  for ((i=${#_BOOT_DEFER[@]}-1; i>=0; i--)); do eval -- "${_BOOT_DEFER[$i]}" || true; done
  _BOOT_DEFER=()
}

# --- Logging (plain) ----------------------------------------------------------

##**
# Convert textual log level to numeric weight.
# @param string $1 level
# @return int weight
# @access private
##*
_boot::level_num() {
  case "${1,,}" in
    debug) echo 10 ;;
    success) echo 15 ;;
    info) echo 20 ;;
    notice) echo 25 ;;
    warn) echo 30 ;;
    error) echo 40 ;;
    silent) echo 99 ;;
    *) echo 20 ;;
  esac
}

##**
# Plain logger (UI may override with colors).
# @param string $1 level
# @param string ...$2 message
# @since 1.2.0
# @example
#   boot::log info "hello"
#   BOOT_LOG_LEVEL=warn; boot::log info "hidden"; boot::log warn "shown"
##*
boot::log() {
  local lvl="${1:-info}"; shift || true
  local want cur
  want="$(_boot::level_num "$BOOT_LOG_LEVEL")"
  cur="$(_boot::level_num "$lvl")"
  (( cur < want )) && return 0
  printf "[boot:%s] %s\n" "$lvl" "$*"
}

# --- Basics -------------------------------------------------------------------

##**
# Ensure commands exist in PATH.
# @param string ...$1 command names
# @return int 0 if all exist, 1 otherwise
# @example
#   boot::require git jq || exit 1
##*
boot::require() {
  local m=0 c
  for c in "$@"; do
    if ! command -v -- "$c" >/dev/null 2>&1; then
      m=1; boot::log warn "missing command: $c"
    fi
  done
  return $m
}

##**
# Detect if current file is sourced.
# @return int 0 if sourced, 1 if executed
# @example
#   if boot::is_sourced; then echo "sourced"; else echo "executed"; fi
##*
boot::is_sourced() { [[ "${BASH_SOURCE[0]}" != "$0" ]]; }

##**
# Current epoch in milliseconds.
# @return int ms
# @example
#   t0="$(boot::now_ms)"; sleep 0.1; t1="$(boot::now_ms)"; echo "$((t1-t0)) ms"
##*
boot::now_ms() { printf "%s" "$(($(date +%s%3N)))"; }

##**
# Print a simple stack trace to stdout.
# @example
#   some() { boot::stacktrace; }
#   some   # prints call frames
##*
boot::stacktrace() {
  local i
  for (( i=1; i<${#FUNCNAME[@]}; i++ )); do
    printf "#%d %s (%s:%s)\n" \
      "$i" "${FUNCNAME[$i]:-?}" "${BASH_SOURCE[$i]:-?}" "${BASH_LINENO[$((i-1))]:-?}"
  done
}

##**
# Get boolean env var with defaults.
# @param string $1 NAME
# @param int    $2 default (0/1)
# @return int 0/1
# @example
#   export FOO=true;  boot::env_get_bool FOO 0  # -> 1
#   unset FOO;        boot::env_get_bool FOO 1  # -> 1
##*
boot::env_get_bool() {
  local n="${1:?}" def="${2:-0}" v="${!n-}"
  case "${v,,}" in 1|true|yes|on) echo 1 ;; 0|false|no|off|"") echo "$def" ;; *) echo "$def" ;; esac
}

##**
# Get integer env var with default.
# @param string $1 NAME
# @param int    $2 default
# @return int
# @example
#   export N=42;  boot::env_get_int N 0  # -> 42
#   unset N;      boot::env_get_int N 7  # -> 7
##*
boot::env_get_int() {
  local n="${1:?}" def="${2:-0}" v="${!n-}"
  [[ "$v" =~ ^-?[0-9]+$ ]] && echo "$v" || echo "$def"
}

##**
# Get string env var with default.
# @param string $1 NAME
# @param string $2 default
# @return string
# @example
#   export NAME="alice"; boot::env_get NAME "n/a"  # -> alice
#   unset NAME;         boot::env_get NAME "n/a"   # -> n/a
##*
boot::env_get() {
  local n="${1:?}" def="${2:-}"
  [[ -n "${!n-}" ]] && echo "${!n}" || echo "$def"
}

# --- Try / Retry / Backoff / Timeout / Lock ----------------------------------

##**
# Capture stdout/stderr of a command into variables.
# @param nameref $1 outvar
# @param nameref $2 errvar
# @param string  -- sentinel
# @param string  ... command
# @return int exit code of the command
# @example
#   if boot::try OUT ERR -- ls /nope; then echo "OK"; else echo "E:$ERR"; fi
##*
boot::try() {
  local -n __o="${1:?}" __e="${2:?}"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  local to te rc
  to="$(mktemp)" && te="$(mktemp)"
  if "$@" >"$to" 2>"$te"; then rc=0; else rc=$?; fi
  __o="$(<"$to")"; __e="$(<"$te")"
  rm -f -- "$to" "$te"
  return $rc
}

##**
# Constant backoff generator.
# @param float $1 base seconds
# @return float delay seconds
# @example
#   boot::backoff_const 0.2  # -> 0.2
##*
boot::backoff_const() { printf "%s\n" "${1:-0.2}"; }

##**
# Exponential backoff generator (b * 2^(n-1)).
# @param float $1 base seconds
# @param int   $2 attempt index (1..)
# @return float delay seconds
# @example
#   boot::backoff_expo 0.1 3  # -> 0.4
##*
boot::backoff_expo() {
  local base="${1:-0.2}" n="${2:-1}"
  awk -v b="$base" -v n="$n" 'BEGIN{printf "%.6f\n", b*(2^(n-1))}'
}

##**
# Jitter backoff generator (random in [0, base*n]).
# @param float $1 base seconds
# @param int   $2 attempt index
# @return float delay seconds
# @example
#   boot::backoff_jitter 0.5 2  # -> random 0..1.0
##*
boot::backoff_jitter() {
  local base="${1:-0.5}" n="${2:-1}"
  awk -v m="$(awk -v b="$base" -v n="$n" 'BEGIN{print b*n}')" 'BEGIN{srand(); printf "%.6f\n", rand()*m}'
}

##**
# Retry wrapper with pluggable backoff function (by name).
# @param int    $1 attempts
# @param string $2 backoff function name
# @param float  $3 base delay
# @param string -- sentinel
# @param string ... command
# @return int last exit code
# @example
#   boot::retry 3 boot::backoff_expo 0.2 -- curl -fsS https://example.com
##*
boot::retry() {
  local n="${1:?}" fn="${2:?}" base="${3:-0.2}"; shift 3
  [[ "${1:-}" == "--" ]] && shift
  local i=1 d rc
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

##**
# Run a command with a soft timeout.
# @param float  $1 seconds
# @param string -- sentinel
# @param string ... command
# @return int exit code (or timeout's exit)
# @example
#   boot::timeout 0.2 -- bash -lc 'sleep 1'   # -> times out
##*
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
# Execute a command under an exclusive file lock.
# - Uses flock when available; otherwise falls back to atomic mkdir lock.
# - Returns the wrapped command's exit code, or:
#   * 2   : invalid usage (missing args)
#   * 124 : lock acquisition timeout
# @param string $1 lock file path (regular file; created if absent)
# @param string -- sentinel separating options from command
# @param string ... command to run while holding the lock
# @option --timeout <seconds>  Lock acquisition timeout (default: 30)
# @return int exit code
# @example
#   boot::with_lock "/tmp/my.lock" -- bash -lc 'echo critical; sleep 0.2'
##*
boot::with_lock() {
  local lock timeout="30"
  [[ $# -lt 1 ]] && { boot::log error "with_lock: lock path required"; return 2; }
  lock="$1"; shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        if [[ -n "${2:-}" && "$2" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
          timeout="$2"; shift 2
        else
          boot::log error "with_lock: invalid --timeout"; return 2
        fi
        ;;
      --) shift; break;;
      *)  break;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    boot::log error "with_lock: command to execute is required"
    return 2
  fi
  local -a CMD=( "$@" )
  local timeout_sec="${timeout%.*}"; [[ -z "$timeout_sec" ]] && timeout_sec=0

  if command -v flock >/dev/null 2>&1; then
    local __fd rc=0
    if ! mkdir -p -- "$(dirname -- "$lock")"; then
      boot::log error "with_lock: cannot create lock dir"; return 1
    fi
    (
      umask 077
      : > "$lock" 2>/dev/null || true
    )

    if ! exec {__fd}>"$lock"; then
      boot::log error "with_lock: cannot open lock file"; return 1
    fi
    if ! flock -x -w "$timeout" "$__fd"; then
      { eval "exec $__fd>&-"; } 2>/dev/null || true
      boot::log error "with_lock: timeout acquiring lock: $lock"
      return 124
    fi

    if "${CMD[@]}"; then rc=0; else rc=$?; fi
    { flock -u "$__fd"; } 2>/dev/null || true
    { eval "exec $__fd>&-"; } 2>/dev/null || true
    return "$rc"
  fi

  local lockdir="${lock}.dlock" rc=0 acquired=0 t0 now
  t0="$(date +%s)"
  if ! mkdir -p -- "$(dirname -- "$lockdir")"; then
    boot::log error "with_lock: cannot create parent dir"
    return 1
  fi

  _boot__with_lock_cleanup_fallback() {
    if (( acquired == 1 )); then
      rmdir -- "$lockdir" 2>/dev/null || true
      acquired=0
    fi
  }
  # shellcheck disable=SC2064
  trap "_boot__with_lock_cleanup_fallback" INT TERM EXIT

  while ! mkdir -- "$lockdir" 2>/dev/null; do
    now="$(date +%s)"
    if (( timeout_sec > 0 )) && (( now - t0 >= timeout_sec )); then
      trap - INT TERM EXIT
      boot::log error "with_lock: timeout acquiring lock (fallback): $lockdir"
      return 124
    fi
    sleep 0.1
  done
  acquired=1

  if "${CMD[@]}"; then rc=0; else rc=$?; fi
  { rmdir -- "$lockdir"; } 2>/dev/null || true
  acquired=0
  trap - INT TERM EXIT
  return "$rc"
}

# --- Atomic I/O / Temp / Cache ------------------------------------------------

##**
# Create an ephemeral temp dir and run a body in a subshell.
# @param string $1 varname to receive the temp dir path (within subshell)
# @param string -- sentinel
# @param string ... body command
# @effects Temp directory is removed on exit of subshell.
# @example
#   boot::with_tempdir TMP -- bash -lc 'echo "tmp=$TMP"; touch "$TMP/x"'
##*
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

##**
# Atomic write stdin to destination file.
# @param string $1 destination path
# @example
#   echo "hello" | boot::atomic_write "/tmp/hello.txt"
##*
boot::atomic_write() {
  local dest="${1:?}" dir tmp
  dir="$(dirname -- "$dest")"
  tmp="$(mktemp "$dir/.tmp.XXXXXXXX")"
  cat >"$tmp"
  mv -f -- "$tmp" "$dest"
}

##**
# Read a file to stdout if readable.
# @param string $1 path
# @return int 0 if printed, 1 otherwise
# @example
#   boot::readfile "/etc/hosts" | head -n 1
##*
boot::readfile() {
  local p="${1:?}"
  [[ -r "$p" ]] && cat -- "$p"
}

##**
# Write string arguments to file atomically.
# @param string $1 path
# @param string ...$2 content
# @example
#   boot::writefile "/tmp/k.txt" "key=" "value"
##*
boot::writefile() {
  local p="${1:?}"; shift
  printf "%s" "$*" | boot::atomic_write "$p"
}

##**
# Resolve cache directory (XDG or ~/.cache/boot).
# @return string path
# @example
#   dir="$(boot::cache_dir)"; echo "$dir"
##*
boot::cache_dir() {
  if [[ -n "$BOOT_CACHE_DIR" ]]; then
    printf "%s\n" "$BOOT_CACHE_DIR"
  else
    printf "%s\n" "${XDG_CACHE_HOME:-$HOME/.cache}/boot"
  fi
}

##**
# Memoize stdout of a command by a cache key (optional TTL).
# @param string $1 key
# @param int    $2 ttl seconds (0=no expiry check)
# @param string -- sentinel
# @param string ... command
# @return int 0 on success (cache hit/miss both), 1 on command failure
# @example
#   boot::cache_memo "date-1s" 1 -- date +%s   # cached for 1 second
##*
boot::cache_memo() {
  local key="${1:?}" ttl="${2:-0}"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  local dir file now mt tmp
  dir="$(boot::cache_dir)"; mkdir -p -- "$dir"
  file="$dir/$(printf "%s" "$key" | sha1sum | awk '{print $1}').cache"
  if [[ -r "$file" && $ttl -gt 0 ]]; then
    now=$(date +%s)
    mt=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0)
    if (( now - mt <= ttl )); then
      cat -- "$file"; return 0
    fi
  fi
  tmp="$(mktemp "$dir/.tmp.XXXXXX")"
  if "$@" >"$tmp"; then
    mv -f -- "$tmp" "$file"
    cat -- "$file"
  else
    rm -f -- "$tmp"
    return 1
  fi
}

# --- IDs & Versions -----------------------------------------------------------

##**
# Generate a simple non-cryptographic random id string.
# @return string id
# @example
#   id="$(boot::id_rand)"; echo "$id"
##*
boot::id_rand() { printf "%s" "$(date +%s%N)-$RANDOM-$RANDOM"; }

##**
# Compare semantic versions a.b.c
# @param string $1 a
# @param string $2 b
# @return int -1 if a<b, 0 if equal, 1 if a>b
# @example
#   boot::semver_cmp 1.2.3 1.10.0  # -> -1
##*
boot::semver_cmp() {
  local a=${1:?} b=${2:?} IFS=. A=($a) B=($b) i x y
  for i in 0 1 2; do
    x="${A[i]:-0}"; y="${B[i]:-0}"
    (( x+=0, y+=0 ))
    if (( x<y )); then echo -1; return 0; fi
    if (( x>y )); then echo 1;  return 0; fi
  done
  echo 0
}

# --- Arrays (functional) & Streams -------------------------------------------

##**
# Map an array through a *function* callback (no eval).
# @param nameref $1 in array
# @param nameref $2 out array
# @param string  $3 callback function name (value, index)
# @example
#   up(){ printf "%s" "${1^^}"; }
#   IN=(a b); boot::map IN OUT up; printf "%s\n" "${OUT[@]}"  # -> A B
##*
boot::map() {
  local -n IN="${1:?}" OUT="${2:?}"; local cb="${3:?}"
  OUT=()
  local i val
  for i in "${!IN[@]}"; do
    val="$("$cb" "${IN[$i]}" "$i")"
    OUT+=("$val")
  done
}

##**
# Filter an array by *predicate* function (0=keep).
# @param nameref $1 in array
# @param nameref $2 out array
# @param string  $3 predicate function name (value, index) -> exit 0 keep
# @example
#   is_even(){ (( $2 % 2 == 0 )); }
#   IN=(a b c d); boot::filter IN OUT is_even; printf "%s\n" "${OUT[@]}"  # -> a c
##*
boot::filter() {
  local -n IN="${1:?}" OUT="${2:?}"; local pd="${3:?}"
  OUT=()
  local i v
  for i in "${!IN[@]}"; do
    v="${IN[$i]}"
    if "$pd" "$v" "$i"; then OUT+=("$v"); fi
  done
}

##**
# Reduce an array with an accumulator via function.
# @param nameref $1 in array
# @param string  $2 initial accumulator
# @param nameref $3 out scalar
# @param string  $4 reducer function name (acc, value) -> echo new_acc
# @example
#   add(){ echo "$(($1 + ${#2}))"; }
#   IN=(aa b ccc); boot::reduce IN 0 SUM add; echo "$SUM"  # -> 6
##*
boot::reduce() {
  local -n IN="${1:?}"; local acc="${2:?}"; local -n OUT="${3:?}"; local rd="${4:?}"
  local v
  for v in "${IN[@]}"; do
    acc="$("$rd" "$acc" "$v")"
  done
  OUT="$acc"
}

##**
# Parallel map (order-preserving) with PID queue; callback is a function name.
# @param int     $1 concurrency>=1
# @param nameref $2 in array
# @param nameref $3 out array
# @param string  $4 callback function name (value, index)
# @example
#   work(){ sleep 0.1; printf "%s" "$1!"; }
#   IN=(a b c d); boot::par_map 2 IN OUT work; printf "%s\n" "${OUT[@]}"  # -> a! b! c! d!
##*
boot::par_map() {
  local conc="${1:?}"; shift
  local -n IN="${1:?}" OUT="${2:?}"; local cb="${3:?}"
  (( conc<1 )) && conc=1
  OUT=()
  local -a TF=() PIDS=()
  local i tf pid
  for i in "${!IN[@]}"; do
    tf="$(mktemp)"; TF+=("$tf")
    (
      "$cb" "${IN[$i]}" "$i" >"$tf"
    ) & pid=$!
    PIDS+=("$pid")
    while (( ${#PIDS[@]} >= conc )); do
      wait "${PIDS[0]}" || true
      PIDS=("${PIDS[@]:1}")
    done
  done
  for pid in "${PIDS[@]}"; do wait "$pid" || true; done
  for tf in "${TF[@]}"; do OUT+=("$(<"$tf")"); rm -f -- "$tf"; done
}

##**
# Stream map from stdin using a function callback.
# @param string $1 callback function name (line, index) -> echo mapped
# @example
#   up(){ printf "%s" "${1^^}"; }
#   seq 3 | boot::pipe_map up   # -> 1st 2nd 3rd lines upper-cased
##*
boot::pipe_map() {
  local cb="${1:?}" line i=0
  while IFS= read -r line; do
    "$cb" "$line" "$i"
    ((i++))
  done
}

##**
# Stream filter from stdin using a predicate function.
# @param string $1 predicate function name (line, index) -> exit 0 keep
# @example
#   keep_even(){ (( $2 % 2 == 0 )); }
#   seq 5 | boot::pipe_filter keep_even  # -> lines 0,2,4 (0-based)
##*
boot::pipe_filter() {
  local pd="${1:?}" line i=0
  while IFS= read -r line; do
    if "$pd" "$line" "$i"; then printf "%s\n" "$line"; fi
    ((i++))
  done
}

return 0 2>/dev/null || true
