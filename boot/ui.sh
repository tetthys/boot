# boot/ui.sh - Minimal Bash wrapper for Python Rich UI
# - Source this file to use UI functions in your Bash scripts.
# - No Bash fallback: requires python3 + rich + boot/boot_ui.py.
#
# Public API:
#   boot::log LEVEL MSG...
#   boot::banner "Title"
#   boot::hr
#   boot::ui::table HEAD ROWS [--sort COL|INDEX] [--desc]    # ROWS are TSV lines
#   boot::ui::kv_dump MAP [PAD]
#   boot::ui::timeline EVENTS
#   boot::spinner [--label TEXT] -- cmd arg...
#   boot::progress PERCENT ["Label"]
#
# Environment knobs (forwarded to Python backend):
#   BOOT_NO_COLOR=1, BOOT_EMOJI=0, BOOT_TS=none,
#   BOOT_THEME=light|dark|mono, BOOT_LOG_FORMAT=text|json,
#   BOOT_LOG_FILE=/path/file, BOOT_LOG_JSON_FILE=/path/file
#
# Usage example:
#   source ./boot/ui.sh
#   boot::log info "Hello UI"
#   HEAD=(ID Name Score)
#   ROWS=($'1\tAlice\t98' $'2\tBob\t87')
#   boot::ui::table HEAD ROWS --sort Score --desc

if [[ -n "${_BOOT_UI_WRAPPER_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_UI_WRAPPER_LOADED=1

: "${BOOT_NO_COLOR:=0}"
: "${BOOT_EMOJI:=1}"
: "${BOOT_TS:=time}"
: "${BOOT_THEME:=dark}"
: "${BOOT_LOG_FORMAT:=text}"
: "${BOOT_LOG_FILE:=}"
: "${BOOT_LOG_JSON_FILE:=}"
: "${BOOT_PY_UI:=}"  # optional absolute path to boot_ui.py

# Resolve backend path (boot/boot_ui.py)
_boot_ui__path() {
  if [[ -n "${BOOT_PY_UI:-}" && -r "$BOOT_PY_UI" ]]; then printf "%s" "$BOOT_PY_UI"; return 0; fi
  local here="${BASH_SOURCE[0]}"; local root; root="$(cd -- "$(dirname -- "$here")/.." && pwd -P)"
  local bin="$root/boot/boot_ui.py"
  [[ -r "$bin" ]] && { printf "%s" "$bin"; return 0; }
  printf >&2 "[boot:ui] backend not found (expected at %s)\n" "$bin"
  return 1
}

# Readiness check (hard fail)
_boot_ui__ensure() {
  command -v python3 >/dev/null 2>&1 || { printf >&2 "[boot:ui] python3 is required.\n"; return 1; }
  local py; py="$(_boot_ui__path)" || return 1
  if ! python3 - >/dev/null 2>&1 <<'PY'
try:
    import rich  # noqa
except Exception:
    raise SystemExit(1)
PY
  then
    printf >&2 "[boot:ui] 'rich' is required. Install: python3 -m pip install rich\n"
    return 1
  fi
  printf "%s" "$py"
  return 0
}

_boot_ui__PY="$(_boot_ui__ensure)" || return 1

# Runner: forward env vars and call Python backend
_boot_ui__run() {
  BOOT_NO_COLOR="$BOOT_NO_COLOR" \
  BOOT_EMOJI="$BOOT_EMOJI" \
  BOOT_TS="$BOOT_TS" \
  BOOT_THEME="$BOOT_THEME" \
  BOOT_LOG_FORMAT="$BOOT_LOG_FORMAT" \
  BOOT_LOG_FILE="$BOOT_LOG_FILE" \
  BOOT_LOG_JSON_FILE="$BOOT_LOG_JSON_FILE" \
  python3 "$_boot_ui__PY" "$@"
}

# Small JSON escaper for headers and kv
_boot_ui__json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"
  printf "%s" "$s"
}

# ---------------- Public API ----------------

boot::log()      { local lvl="${1:-info}"; shift || true; _boot_ui__run log --level "$lvl" "$@"; }
boot::banner()   { _boot_ui__run banner "$*"; }
boot::hr()       { _boot_ui__run hr; }

# headers: array; rows: array (TSV lines)
boot::ui::table() {
  local -n H="${1:?}" R="${2:?}"; shift 2
  local SORT_BY="" DESC=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sort) SORT_BY="${2:-}"; shift 2;;
      --desc) DESC="--desc"; shift;;
      *) break;;
    esac
  done
  local json="[" i
  for i in "${!H[@]}"; do
    json+="\"$(_boot_ui__json_escape "${H[$i]}")\""
    [[ $i -lt $((${#H[@]}-1)) ]] && json+=","
  done
  json+="]"
  if [[ -n "$SORT_BY" ]]; then
    { printf "%s\n" "${R[@]}"; } | _boot_ui__run table --headers "$json" --sort-by "$SORT_BY" ${DESC:+--desc}
  else
    { printf "%s\n" "${R[@]}"; } | _boot_ui__run table --headers "$json"
  fi
}

boot::ui::kv_dump() {
  local -n MAP="${1:?}"; local pad="${2:-0}"
  local first=1 js="{"
  local k; for k in "${!MAP[@]}"; do
    local kk="$(_boot_ui__json_escape "$k")"
    local vv="$(_boot_ui__json_escape "${MAP[$k]}")"
    (( first )) && first=0 || js+=","
    js+="\"$kk\":\"$vv\""
  done; js+="}"
  _boot_ui__run kv --json "$js" --pad "$pad"
}

boot::ui::timeline() {
  local -n EV="${1:?}"
  { printf "%s\n" "${EV[@]}"; } | _boot_ui__run timeline
}

# Usage: boot::spinner [--label TEXT] -- cmd arg...
boot::spinner() {
  local lbl=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) lbl="${2:-}"; shift 2;;
      --) shift; break;;
      *) break;;
    esac
  done
  _boot_ui__run spinner --label "$lbl" -- "$@"
}

boot::progress() {
  local p="${1:-0}" lbl="${2:-}"
  _boot_ui__run progress --percent "$p" --label "$lbl"
}

return 0 2>/dev/null || true
