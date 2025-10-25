# boot.sh - Single entry to load core, UI, path, and network helpers.

if [[ -n "${_BOOT_ENTRY_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_ENTRY_LOADED=1

_BOOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# core (required)
if [[ -r "${_BOOT_DIR}/boot/core.sh" ]]; then
  # shellcheck source=boot/core.sh
  source "${_BOOT_DIR}/boot/core.sh"
else
  printf >&2 "boot/core.sh not found. Aborting.\n"; return 1
fi

# ui (optional)
[[ -r "${_BOOT_DIR}/boot/ui.sh" ]] && source "${_BOOT_DIR}/boot/ui.sh"

# path (optional but recommended)
[[ -r "${_BOOT_DIR}/boot/path.sh" ]] && source "${_BOOT_DIR}/boot/path.sh"

# network (optional)
[[ -r "${_BOOT_DIR}/boot/network.sh" ]] && source "${_BOOT_DIR}/boot/network.sh"

return 0 2>/dev/null || true
