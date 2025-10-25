#!/usr/bin/env bash
# ==============================================================================
# @file boot/id.sh
# @brief Simple random ID helpers.
# @since 1.3.0
# @version 1.3.0
# ==============================================================================

if [[ -n "${_BOOT_ID_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_ID_LOADED=1

##**
# Generate a simple non-cryptographic random ID string.
# Uses time (ns if available) + RANDOM entropy.
##*
boot::id_rand() {
  local t r1 r2
  t="$(date +%s%N 2>/dev/null || date +%s)"
  r1=$RANDOM; r2=$RANDOM
  printf '%s-%d-%d\n' "$t" "$r1" "$r2"
}
