# boot/ui.sh - Colorful logging & UI helpers (Bash 5+)

if [[ -n "${_BOOT_UI_LOADED:-}" ]]; then return 0; fi
readonly _BOOT_UI_LOADED=1

: "${BOOT_NO_COLOR:=0}"      # 1=disable ANSI color
: "${BOOT_EMOJI:=1}"         # 1=use emojis
: "${BOOT_TS:=time}"         # time|none
: "${BOOT_TRUNC_COLUMNS:=0}" # 0=off, N=truncate width

# ANSI palette (stderr TTY check for colors)
if [[ $BOOT_NO_COLOR -eq 0 && -t 2 ]]; then
  _C_RESET=$'\e[0m'; _C_DIM=$'\e[2m'; _C_BOLD=$'\e[1m'
  _C_RED=$'\e[31m'; _C_GRN=$'\e[32m'; _C_YEL=$'\e[33m'; _C_BLU=$'\e[34m'
  _C_MAG=$'\e[35m'; _C_CYA=$'\e[36m'; _C_GRY=$'\e[90m'; _C_WHT=$'\e[97m'
else
  _C_RESET= _C_DIM= _C_BOLD= _C_RED= _C_GRN= _C_YEL= _C_BLU= _C_MAG= _C_CYA= _C_GRY= _C_WHT=
fi

##**
# Format timestamp.
# @return string timestamp or empty
# @access private
##*
boot::fmt_ts(){ [[ $BOOT_TS == time ]] && printf "%(%H:%M:%S)T" -1 || printf ""; }

##**
# Truncate a string to N visible columns.
# @param string $1 text
# @param int    $2 columns
# @return string truncated
##*
boot::fmt_truncate(){ local s="$1" cols="${2:-0}"; (( cols>0 && ${#s}>cols )) && printf "%s…" "${s:0:cols-1}" || printf "%s" "$s"; }

##**
# Map level to emoji.
# @param string $1 level
# @return string emoji
##*
boot::fmt_emoji(){ (( ! BOOT_EMOJI )) && { printf ""; return; }; case "$1" in debug)echo "🧩";; info)echo "ℹ️";; notice)echo "🔔";; warn)echo "⚠️";; error)echo "❌";; success)echo "✅";; *)echo "●";; esac; }

##**
# Map level to color.
# @param string $1 level
# @return string color sequence
##*
boot::fmt_lvlcol(){ case "$1" in debug)printf "%s" "$_C_CYA";; info)printf "%s" "$_C_GRN";; notice)printf "%s" "$_C_BLU";; warn)printf "%s" "$_C_YEL";; error)printf "%s" "$_C_RED";; success)printf "%s" "$_C_GRN$_C_BOLD";; *)printf "%s" "$_C_WHT";; esac; }

##**
# Colorful logger overriding core boot::log.
# @param string $1 level
# @param string ...$2 message
# @example
#   boot::log success "done!"
##*
boot::log() {
  local lvl="${1:-info}"; shift || true
  local want cur ts em col msg
  want="$(_boot::level_num "$BOOT_LOG_LEVEL")"
  cur="$(_boot::level_num "$lvl")"
  (( cur < want )) && return 0
  ts="$(boot::fmt_ts)"; [[ -n "$ts" ]] && ts=" ${_C_GRY}${ts}${_C_RESET}"
  em="$(boot::fmt_emoji "$lvl")"; col="$(boot::fmt_lvlcol "$lvl")"
  msg="$*"; (( BOOT_TRUNC_COLUMNS > 0 )) && msg="$(boot::fmt_truncate "$msg" "$BOOT_TRUNC_COLUMNS")"
  if [[ -n "$em" ]]; then
    printf "%s[%sboot%s]%s %b %s\n" "$_C_GRY" "$_C_DIM" "$_C_RESET" "$ts" "$col$em$_C_RESET" "$msg"
  else
    printf "%s[%sboot:%s%s]%s %s\n" "$_C_GRY" "$_C_DIM" "$lvl" "$_C_RESET" "$ts" "$msg"
  fi
}

##**
# Draw a bold banner line.
# @param string $1 text
# @return void
##*
boot::banner(){ local text="${1:?}" bar; bar=$(printf '%*s' "${COLUMNS:-80}" '' | tr ' ' '━'); printf "%s\n%s %s%s\n%s\n" "$_C_BLU$bar$_C_RESET" "$_C_BOLD" "$text" "$_C_RESET" "$_C_BLU$bar$_C_RESET"; }

##**
# Horizontal rule.
# @return void
##*
boot::hr(){ printf "%s\n" "$(printf '%*s' "${COLUMNS:-80}" '' | tr ' ' '─')"; }

##**
# Simple progress bar (single-line, 0..100).
# @param int    $1 percent
# @param string $2 label
# @return void
##*
boot::progress(){
  local p="${1:?}" lbl="${2:-}" w filled empty
  (( p<0 )) && p=0; (( p>100 )) && p=100
  w=$(( (${COLUMNS:-60} - 10) )); (( w<10 )) && w=10
  filled=$(( p*w/100 )) ; empty=$(( w-filled ))
  printf "%s[%s%s]%s %3d%% %s\r" "$_C_GRY" "$_C_GRN$(printf '%*s' "$filled" '' | tr ' ' '#')" "$(printf '%*s' "$empty" '' | tr ' ' '-')" "$_C_RESET" "$p" "$lbl"
  (( p == 100 )) && printf "\n"
}

##**
# Render a simple ASCII table.
# - Rows are split by a delimiter (default: TAB). No nested arrays needed.
# @param nameref $1 headers (array of strings)
# @param nameref $2 rows (array of delimited strings)
# @param string  $3 delimiter (default: $'\t')
# @example
#   HEAD=(ID Name Score)
#   ROWS=($'1\tAlice\t98' $'2\tBob\t87')
#   boot::ui::table HEAD ROWS
##*
boot::ui::table() {
  local -n __HEAD="${1:?}" __ROWS="${2:?}"; local DELIM="${3:-$'\t'}"
  local -a W=()
  local cols=${#__HEAD[@]} r c cell
  # widths by header
  for ((c=0;c<cols;c++)); do W[c]=${#__HEAD[c]}; done
  # widths by data
  for r in "${__ROWS[@]}"; do
    IFS="$DELIM" read -r -a _F <<<"$r"
    for ((c=0;c<cols;c++)); do cell="${_F[c]:-}"; (( ${#cell} > W[c] )) && W[c]=${#cell}; done
  done
  # helpers
  local sep="+"; for ((c=0;c<cols;c++)); do sep+="$(printf -- '-%.0s' $(seq 1 $((W[c]+2))))+"; done
  printf "%s\n" "$sep"
  # header
  printf "|"; for ((c=0;c<cols;c++)); do printf " %-${W[c]}s |" "${__HEAD[c]}"; done; printf "\n"
  printf "%s\n" "$sep"
  # rows
  for r in "${__ROWS[@]}"; do
    IFS="$DELIM" read -r -a _F <<<"$r"
    printf "|"
    for ((c=0;c<cols;c++)); do printf " %-${W[c]}s |" "${_F[c]:-}"; done
    printf "\n"
  done
  printf "%s\n" "$sep"
}

##**
# Pretty-print a key-value map (assoc) with aligned colons.
# @param nameref $1 assoc map
# @param int     $2 left padding spaces (default 0)
# @example
#   declare -A M=([name]=alice [lang]=bash)
#   boot::ui::kv_dump M 2
##*
boot::ui::kv_dump() {
  local -n __MAP="${1:?}" ; local pad="${2:-0}" k max=0
  for k in "${!__MAP[@]}"; do (( ${#k} > max )) && max=${#k}; done
  for k in "${!__MAP[@]}"; do
    printf "%*s%-*s : %s\n" "$pad" "" "$max" "$k" "${__MAP[$k]}"
  done
}

##**
# Render a lightweight timeline block.
# - Events are strings "timestamp<TAB>text" (you control the format).
# @param nameref $1 events (array)
# @example
#   EV=($'10:00\tStart' $'10:30\tBuild' $'11:00\tRelease')
#   boot::ui::timeline EV
##*
boot::ui::timeline() {
  local -n __EV="${1:?}" ; local left=0 e t msg bar
  # measure left column width
  for e in "${__EV[@]}"; do IFS=$'\t' read -r t msg <<<"$e"; (( ${#t} > left )) && left=${#t}; done
  for e in "${__EV[@]}"; do
    IFS=$'\t' read -r t msg <<<"$e"
    printf "%-${left}s %s %s\n" "$t" "●" "$msg"
    bar="$(printf '%*s' "$left" '')"
    printf "%s │\n" "$bar"
  done
}

##**
# Spinner for a long-running command.
# Usage: boot::spinner [--label TEXT] -- cmd arg...
# @option --label TEXT   Label to show while spinning
# @return int command exit code
# @example
#   boot::spinner --label "Preparing" -- bash -lc 'sleep 0.5'
##*
boot::spinner(){
  local lbl="" rc spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  # parse optional --label
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) lbl="${2:-}"; shift 2;;
      --) shift; break;;
      *) break;;
    esac
  done
  local -a CMD=( "$@" )
  if [[ ${#CMD[@]} -eq 0 ]]; then
    boot::log error "spinner: no command"
    return 2
  fi
  "${CMD[@]}" & local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    local c="${spin:i%${#spin}:1}"; i=$((i+1))
    if [[ -n "$lbl" ]]; then
      printf "%s%s%s %s\r" "$_C_CYA" "$c" "$_C_RESET" "$lbl"
    else
      printf "%s%s%s\r" "$_C_CYA" "$c" "$_C_RESET"
    fi
    sleep 0.08
  done
  wait "$pid"; rc=$?
  if [[ -n "$lbl" ]]; then
    (( rc==0 )) && printf "%s✔%s %s\n" "$_C_GRN" "$_C_RESET" "$lbl" || printf "%s✖%s %s (rc=%d)\n" "$_C_RED" "$_C_RESET" "$lbl" "$rc"
  else
    (( rc==0 )) && printf "%s✔%s\n" "$_C_GRN" "$_C_RESET" || printf "%s✖%s (rc=%d)\n" "$_C_RED" "$_C_RESET" "$rc"
  fi
  return "$rc"
}
