#!/usr/bin/env bash
# ==============================================================================
# @file boot/version.sh
# @brief Version helpers (semantic version comparison).
# @since 1.3.0
# @version 1.3.0
# ==============================================================================

if [[ -n "${_BOOT_VERSION_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_VERSION_LOADED=1

# Public version of the boot library
BOOT_VERSION="1.3.0"

##**
# Compare two semantic version strings (a.b.c).
# Prints: -1 if a<b, 0 if equal, 1 if a>b.
##*
boot::semver_cmp() {
  local verA="${1:-}" verB="${2:-}"
  if [[ -z "$verA" || -z "$verB" ]]; then
    printf '0\n'; return 0
  fi
  local IFS=. ; local -a A=() B=()
  A=($verA); B=($verB)
  local i x y
  for i in 0 1 2; do
    x="${A[i]:-0}" ; y="${B[i]:-0}"
    ((10#$x < 10#$y)) && { printf -- '-1\n'; return 0; }
    ((10#$x > 10#$y)) && { printf --  '1\n'; return 0; }
  done
  printf '0\n'
}
