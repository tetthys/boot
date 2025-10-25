#!/usr/bin/env bash
# ==============================================================================
# @file boot/core.sh
# @brief Core runtime: guards, strict mode, traps, defer, logging, env utils.
# @since 1.3.0
# @version 1.3.0
# ==============================================================================

if [[ -n "${_BOOT_CORE_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_CORE_LOADED=1

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
# Effects: sets ERR trap to boot::on_err; enables pipefail/errexit/nounset.
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
# Plain logger (UI layer can override).
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

# --- Tiny guards (shared by modules) ------------------------------------------

##** Return 0 if a command exists. */
boot::__has() { command -v "$1" >/dev/null 2>&1; }

##** Validate a shell identifier. */
boot::__require_ident() {
  local v="${1:?missing ident}"
  [[ "$v" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && return 0
  printf 'boot: error: invalid identifier "%s"\n' "$v" >&2
  return 2
}

##** Check whether a name is callable (function/builtin/keyword/file). */
boot::__require_callable() {
  local name="${1:?missing name}"
  [[ "$(type -t -- "$name" 2>/dev/null)" =~ ^(function|file|builtin|keyword)$ ]] && return 0
  printf 'boot: error: "%s" not callable\n' "$name" >&2
  return 127
}

##** Internal: uint checker (>=0). */
boot::__is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
