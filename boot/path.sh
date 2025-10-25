#!/usr/bin/env bash
# boot/path.sh - Windows <-> WSL path conversion (pure, stateless)
# - Uses only stdout for results; no globals or side effects.
# - Safe against circular nameref (no nameref used).

if [[ -n "${_BOOT_PATH_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_PATH_LOADED=1

##**
# Convert Windows path (e.g., C:\Users\Alice\project) -> WSL (/mnt/c/Users/Alice/project)
# @param string $1 windows path
# @return string to stdout
##*
boot::path_win2wsl() {
  local w="${1:?}"
  # Trim surrounding quotes and normalize slashes
  w="${w%\"}"; w="${w#\"}"; w="${w//\\//}"
  if [[ "$w" =~ ^([A-Za-z]):/(.*)$ ]]; then
    local drive="${BASH_REMATCH[1],,}" rest="${BASH_REMATCH[2]}"
    printf "/mnt/%s/%s\n" "$drive" "$rest"
  else
    printf "%s\n" "$w"
  fi
}

##**
# Convert WSL path (/mnt/c/Users/Alice/project) -> Windows (C:\Users\Alice\project)
# @param string $1 wsl path
# @return string to stdout
##*
boot::path_wsl2win() {
  local p="${1:?}"
  if [[ "$p" =~ ^/mnt/([a-zA-Z])/(.*)$ ]]; then
    local drive="${BASH_REMATCH[1]^^}" rest="${BASH_REMATCH[2]}"
    printf "%s:\\%s\n" "$drive" "${rest//\//\\}"
  else
    printf "%s\n" "${p//\//\\}"
  fi
}

##**
# Normalize mixed path to a consistent form based on environment.
# - On WSL (Linux), prefer WSL form if drive detected; on Windows, prefer Windows form.
# @param string $1 path (either form)
# @return string to stdout
##*
boot::path_normalize() {
  local x="${1:?}"
  if grep -qEi 'microsoft|wsl' /proc/version 2>/dev/null; then
    # On WSL, convert Windows drive paths to /mnt/<drive> form
    if [[ "$x" =~ ^[A-Za-z]:[\\/].* ]]; then
      boot::path_win2wsl "$x"
      return
    fi
    printf "%s\n" "$x"
  else
    # On non-WSL, keep Windows form if drive can be inferred from /mnt/<drive>
    if [[ "$x" =~ ^/mnt/([a-zA-Z])/(.*)$ ]]; then
      boot::path_wsl2win "$x"
      return
    fi
    printf "%s\n" "$x"
  fi
}

return 0 2>/dev/null || true
