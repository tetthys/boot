# boot/path.sh - Reusable, portable path utilities (Bash 5+)

if [[ -n "${_BOOT_PATH_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_PATH_LOADED=1

##**
# Portable realpath resolver with multiple fallbacks.
# @param string $1 path
# @return string absolute path
# @access private
##*
_boot__compat_realpath() {
  local p="${1:?}"
  if command -v realpath >/dev/null 2>&1; then realpath -- "$p" && return 0; fi
  if command -v greadlink >/dev/null 2>&1; then greadlink -f -- "$p" && return 0; fi
  if command -v readlink  >/dev/null 2>&1; then readlink  -f -- "$p" && return 0; fi
  if command -v python3   >/dev/null 2>&1; then
    python3 - "$p" <<'PY'
import os,sys; print(os.path.realpath(sys.argv[1]))
PY
    return 0
  fi
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd -P)
  else
    local d f
    d="$(dirname -- "$p")" || return 1
    f="$(basename -- "$p")" || return 1
    (cd "$d" 2>/dev/null && printf "%s/%s\n" "$(pwd -P)" "$f")
  fi
}

##**
# Normalize path (best-effort).
# @param string $1 path
# @return string normalized
##*
boot::path::normalize() {
  local p="${1:?}"
  if _boot__compat_realpath "$p" 2>/dev/null; then return 0; fi
  printf "%s\n" "${p//\/\//\/}"
}

##**
# Absolute path.
# @param string $1 path
# @return string absolute
##*
boot::path::abs() { _boot__compat_realpath "${1:?}"; }

##**
# Join path segments into a single path (stdout).
# @param string ... segments
# @return string joined
# @example
#   boot::path::join_e "/var" "log" "nginx"
##*
boot::path::join_e() { local out=""; local seg; for seg in "$@"; do [[ -z "$seg" ]] && continue; if [[ -z "$out" ]]; then out="$seg"; else out="${out%/}/${seg#/}"; fi; done; printf "%s\n" "${out:-.}"; }

##**
# Split path into dir/base/name/ext.
# @param string $1 path
# @param nameref $2 dir
# @param nameref $3 base
# @param nameref $4 name
# @param nameref $5 ext
##*
boot::path::split() {
  local p="${1:?}"; shift
  local -n __d="${1:?}" __b="${2:?}" __n="${3:?}" __e="${4:?}"
  __d="$(dirname -- "$p")" || return 1
  __b="$(basename -- "$p")" || return 1
  if [[ "$__b" == .* && "$__b" != *.* ]]; then
    __n="$__b"; __e=""
  else
    __n="${__b%.*}"
    __e="${__b##*.}"
    [[ "$__n" == "$__b" ]] && __e=""
  fi
}

##**
# Change extension (or drop if empty).
# @param string $1 path
# @param string $2 new ext (no dot) or empty
# @return string new path
##*
boot::path::change_ext() {
  local p="${1:?}" new="${2:-}"
  local d b n e
  boot::path::split "$p" d b n e || return 1
  if [[ -n "$new" ]]; then printf "%s/%s.%s\n" "$d" "$n" "$new"; else printf "%s/%s\n" "$d" "$n"; fi
}

##**
# Relative path from base to target (portable).
# @param string $1 base
# @param string $2 target
# @return string relative
##*
boot::path::rel() {
  local base="${1:?}" target="${2:?}"
  if command -v realpath >/dev/null 2>&1; then realpath --relative-to="$base" -- "$target" && return 0; fi
  if command -v python3  >/dev/null 2>&1; then
    python3 - "$base" "$target" <<'PY'
import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
    return 0
  fi
  local A B
  A="$(_boot__compat_realpath "$base")" || true
  B="$(_boot__compat_realpath "$target")" || true
  [[ -n "$A" && -n "$B" ]] && { printf "%s\n" "${B#"$A"/}"; return 0; }
  printf "%s\n" "$target"
}

# --- File tests & fs ops ------------------------------------------------------

boot::path::exists() { [[ -e "${1:?}" ]]; }
boot::path::is_file(){ [[ -f "${1:?}" ]]; }
boot::path::is_dir() { [[ -d "${1:?}" ]]; }
boot::path::is_link(){ [[ -L "${1:?}" ]]; }

boot::path::mkdirp() { mkdir -p -- "${1:?}"; }
boot::path::touch()  { : > "${1:?}"; }

boot::path::perm_octal() { stat -c "%a" "$1" 2>/dev/null || stat -f "%Lp" "$1" 2>/dev/null; }
boot::path::owner()      { stat -c "%U" "$1" 2>/dev/null || stat -f "%Su" "$1" 2>/dev/null; }
boot::path::group()      { stat -c "%G" "$1" 2>/dev/null || stat -f "%Sg" "$1" 2>/dev/null; }
boot::path::size_bytes() { stat -c "%s" "$1" 2>/dev/null || stat -f "%z"  "$1" 2>/dev/null; }
boot::path::mtime_epoch(){ stat -c "%Y" "$1" 2>/dev/null || stat -f "%m"  "$1" 2>/dev/null; }

##**
# Find a file walking upward.
# @param string $1 filename (e.g., package.json)
# @param string $2 start dir (default: $PWD)
# @param nameref $3 out var
# @return int 0 found, 1 not found
##*
boot::path::find_up() {
  local name="${1:?}" start="${2:-$PWD}" ; local -n OUT="${3:?}"
  local d; d="$(_boot__compat_realpath "$start")" || return 1
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -e "$d/$name" ]]; then OUT="$d/$name"; return 0; fi
    d="$(dirname -- "$d")"
  done
  OUT=""
  return 1
}

##**
# Detect WSL environment.
# @return int 0 if WSL, else 1
# @example
#   if boot::path::is_wsl; then echo "WSL detected"; fi
##*
boot::path::is_wsl() {
  [[ -n "${WSL_INTEROP:-}" ]] && return 0
  grep -qi 'microsoft' /proc/version 2>/dev/null
}

##**
# Convert Windows path -> WSL path (C:\Users\me -> /mnt/c/Users/me).
# - Pure string conversion; does not check existence.
# @param string $1 win_path
# @return string wsl_path
# @example
#   boot::path::win_to_wsl "D:\Work\foo.txt"
##*
boot::path::win_to_wsl() {
  local p="${1:?}"
  # normalize backslashes
  p="${p//\\//}"
  # UNC \\wsl$ or network share: best-effort
  if [[ "$p" =~ ^//wsl\$ ]]; then
    printf "%s\n" "/${p#//}"
    return 0
  fi
  if [[ "$p" =~ ^([A-Za-z]):(/.*)?$ ]]; then
    local drive="${BASH_REMATCH[1],,}" rest="${BASH_REMATCH[2]}"
    printf "/mnt/%s%s\n" "$drive" "$rest"
  else
    # already like / or relative: return as-is
    printf "%s\n" "$p"
  fi
}

##**
# Convert WSL path -> Windows path (/mnt/c/Users/me -> C:\Users\me).
# - If not /mnt/<drive>/..., returns input as-is.
# @param string $1 wsl_path
# @return string win_path
# @example
#   boot::path::wsl_to_win "/mnt/e/Downloads/file.zip"
##*
boot::path::wsl_to_win() {
  local p="${1:?}"
  if [[ "$p" =~ ^/mnt/([A-Za-z])/(.*)$ ]]; then
    local drive="${BASH_REMATCH[1]^^}" rest="${BASH_REMATCH[2]}"
    printf "%s:\\%s\n" "$drive" "${rest//\//\\}"
  else
    printf "%s\n" "$p"
  fi
}

# --- PATH env ops -------------------------------------------------------------

boot::path::in_PATH() {
  local dir="${1:?}" IFS=:
  read -r -a _P <<<"${PATH:-}"
  local x; for x in "${_P[@]}"; do [[ "$x" == "$dir" ]] && return 0; done; return 1
}
boot::path::add_prepend(){ local dir="${1:?}"; boot::path::in_PATH "$dir" || export PATH="$dir:${PATH:-}"; }
boot::path::add_append(){  local dir="${1:?}"; boot::path::in_PATH "$dir" || export PATH="${PATH:-}:$dir"; }
boot::path::which_all() {
  local name="${1:?}" IFS=:
  read -r -a _P <<<"${PATH:-}"
  local d; for d in "${_P[@]}"; do [[ -x "$d/$name" ]] && printf "%s\n" "$d/$name"; done
}

# --- Temp helpers -------------------------------------------------------------

boot::path::tempdir()  { mktemp -d; }
boot::path::tempfile() { mktemp; }

return 0 2>/dev/null || true
