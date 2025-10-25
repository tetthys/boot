#!/usr/bin/env bash
# boot/boot.sh - Unified entrypoint for all boot modules
# Loads, in order:
#
# Usage:
#   source "/path/to/boot/boot.sh"
#   boot::strict
#   boot::log info "hello"
#
# All modules are required to exist; boot.sh will fail fast if missing.

if [[ -n "${_BOOT_MAIN_LOADED:-}" ]]; then
  return 0
fi
readonly _BOOT_MAIN_LOADED=1

# Resolve absolute path of this file
_BOOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# --- required modules ---------------------------------------------------------
for req in functional control core io id version ui network path; do
  file="${_BOOT_DIR}/${req}.sh"
  if [[ ! -r "$file" ]]; then
    printf >&2 "[boot] missing required module: %s\n" "$file"
    return 1
  fi
  # shellcheck source=/dev/null
  source "$file"
done

return 0 2>/dev/null || true
