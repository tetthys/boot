#!/usr/bin/env bash
# boot/boot.sh - Unified entrypoint for all boot modules
# Loads, in order:
#   1) core.sh      (strict/log/try/retry/cache/arrays/locks)
#   2) ui.sh        (Python Rich UI interface)
#   3) network.sh   (HTTP/TLS/ALPN helpers)
#   4) path.sh      (Windows <-> WSL path helpers)
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
for req in functional core ui network path; do
  file="${_BOOT_DIR}/${req}.sh"
  if [[ ! -r "$file" ]]; then
    printf >&2 "[boot] missing required module: %s\n" "$file"
    return 1
  fi
  # shellcheck source=/dev/null
  source "$file"
done

return 0 2>/dev/null || true
