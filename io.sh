#!/usr/bin/env bash
# ==============================================================================
# @file boot/io.sh
# @brief Tempdirs, atomic write, read/write file, cache (TTL), portable mtime/hash.
# @since 1.3.0
# @version 1.3.0
# ==============================================================================

if [[ -n "${_BOOT_IO_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_IO_LOADED=1

##** Internal: print error to stderr. */
boot::__err() { printf '%s\n' "$*" >&2; }

##**
# Internal: portable file mtime (epoch seconds). GNU/BSD stat.
# Prints 0 on failure.
##**
boot::__mtime() {
  local p="${1:?}"
  local mt
  mt=$(stat -c %Y -- "$p" 2>/dev/null) || mt=$(stat -f %m -- "$p" 2>/dev/null) || mt=0
  printf '%s\n' "$mt"
}

##**
# Internal: portable sha256(hex) of stdin (sha256sum/shasum/openssl).
##**
boot::__sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  else
    boot::__err "boot: no sha256 tool (sha256sum/shasum/openssl)"; return 127
  fi
}

##**
# Internal: mktemp file in directory: "$dir/.tmp.XXXXXXXX".
##**
boot::__mktemp_in_dir() {
  local dir="${1:?}"
  mktemp "$dir/.tmp.XXXXXXXX" 2>/dev/null || { boot::__err "boot: mktemp failed in $dir"; return 1; }
}

##**
# with_tempdir: create a temp directory, expose its path to a child scope,
# run the command, and auto-clean the directory on exit.
#
# Usage:
#   boot::with_tempdir VAR -- cmd args...
##**
boot::with_tempdir() {
  local var="${1:?missing var name}"; shift
  [[ "${1:-}" == "--" ]] && shift
  boot::__require_ident "$var" || return $?

  local old_umask; old_umask=$(umask); umask 077
  local d
  if ! d="$(mktemp -d -t boot_tmp.XXXXXXXX 2>/dev/null || mktemp -d 2>/dev/null)"; then
    umask "$old_umask"; boot::__err "boot::with_tempdir: mktemp -d failed"; return 1
  fi
  umask "$old_umask"

  (
    trap 'rm -rf -- "$d" 2>/dev/null || true' EXIT INT TERM
    printf -v "$var" '%s' "$d"
    "$@"
  )
}

##**
# Atomic write: write stdin to a temporary file in the same directory,
# then atomically rename to destination.
##**
boot::atomic_write() {
  local dest="${1:?missing dest}"
  local dir; dir="$(dirname -- "$dest")"
  [[ -d "$dir" ]] || { boot::__err "boot::atomic_write: directory not found: $dir"; return 1; }

  local old_umask; old_umask=$(umask); umask 077
  local tmp
  if ! tmp="$(boot::__mktemp_in_dir "$dir")"; then umask "$old_umask"; return 1; fi
  umask "$old_umask"

  if ! cat >"$tmp"; then
    rm -f -- "$tmp" 2>/dev/null || true
    boot::__err "boot::atomic_write: write failed"; return 1
  fi

  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp" 2>/dev/null || true
    boot::__err "boot::atomic_write: rename failed"; return 1
  fi
}

##** Read file to stdout if readable. */
boot::readfile() {
  local p="${1:?missing path}"
  [[ -r "$p" ]] || return 1
  cat -- "$p"
}

##**
# Write arguments as a single string to path (atomic).
# No trailing newline is added.
##**
boot::writefile() {
  local p="${1:?missing path}"; shift || true
  printf "%s" "$*" | boot::atomic_write "$p"
}

##**
# Get cache directory (XDG or $HOME/.cache/boot); respects $BOOT_CACHE_DIR.
##**
boot::cache_dir() {
  if [[ -n "${BOOT_CACHE_DIR:-}" ]]; then
    printf '%s\n' "$BOOT_CACHE_DIR"
  else
    printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/boot"
  fi
}

##** Ensure cache directory exists securely (0700). */
boot::cache_ensure() {
  local d; d="$(boot::cache_dir)"
  local old_umask; old_umask=$(umask); umask 077
  mkdir -p -- "$d" || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  printf '%s\n' "$d"
}

##**
# Cache stdout of a command with a TTL (seconds).
# KEY hashed to a sha256 hex filename; TTL<=0 disables reuse.
#
# Usage:
#   boot::cache_memo KEY TTL -- cmd args...
##**
boot::cache_memo() {
  local key="${1:?missing key}" ttl="${2:?missing ttl}"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  boot::__is_uint "$ttl" || { boot::__err "boot::cache_memo: ttl must be uint"; return 2; }

  local dir file now mt
  dir="$(boot::cache_ensure)" || { boot::__err "boot::cache_memo: cannot ensure cache dir"; return 1; }

  if ! file="$(printf '%s' "$key" | boot::__sha256_stdin)"; then
    return 1
  fi
  file="$dir/${file}.cache"

  if [[ -r "$file" && "$ttl" -gt 0 ]]; then
    now=$(date +%s)
    mt=$(boot::__mtime "$file")
    if [[ "$mt" -gt 0 ]] && (( now - mt <= ttl )); then
      cat -- "$file"; return 0
    fi
  fi

  local old_umask; old_umask=$(umask); umask 077
  local tmp
  if ! tmp="$(boot::__mktemp_in_dir "$dir")"; then umask "$old_umask"; return 1; fi
  umask "$old_umask"

  if "$@" >"$tmp"; then
    mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; boot::__err "boot::cache_memo: rename failed"; return 1; }
    cat -- "$file"
  else
    local rc=$?; rm -f -- "$tmp" 2>/dev/null || true; return "$rc"
  fi
}
