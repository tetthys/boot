#!/usr/bin/env bash
# scripts/demo.sh - Minimal showcase for boot UI (Python Rich)
# Requirements:
#   - python3
#   - pip install rich
# Files:
#   - boot/boot_ui.py
#   - boot/ui.sh
#
# What this demo shows:
#   - Logging (levels, JSON/file sinks via env)
#   - Banner / Horizontal rule
#   - Table (with sorting / descending)
#   - Key-Value dump (assoc array)
#   - Timeline block
#   - Spinner (runs a command)
#   - Progress (one-shot render, called repeatedly)

set -Eeuo pipefail

# Resolve project root and source the UI wrapper
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=/dev/null
source "${ROOT}/boot/ui.sh"

# Optional: tweak theme/format/sinks here (uncomment to try)
# export BOOT_THEME=light          # light|dark|mono
# export BOOT_LOG_FORMAT=json      # text|json
# export BOOT_LOG_FILE="${ROOT}/demo.log"
# export BOOT_LOG_JSON_FILE="${ROOT}/demo.jsonl"

boot::banner "Boot UI Demo"

# --- Logging levels ------------------------------------------------------------
boot::log debug   "Debug message (may be hidden depending on your log viewer)"
boot::log info    "Information message"
boot::log notice  "Notice message"
boot::log warn    "Warning message"
boot::log error   "Error message"
boot::log success "Success message"

boot::hr

# --- Table (with sorting) ------------------------------------------------------
HEAD=(ID Name Score)
ROWS=(
  $'1\tAlice\t98'
  $'2\tBob\t87'
  $'3\tCharlie\t91'
  $'4\tDana\t70'
)
boot::log info "Table: unsorted"
boot::ui::table HEAD ROWS

boot::log info "Table: sort by Score (desc)"
boot::ui::table HEAD ROWS --sort Score --desc

boot::hr

# --- Key-Value dump ------------------------------------------------------------
declare -A META=(
  [project]=boot
  [component]=ui
  [backend]=python-rich
  [theme]="${BOOT_THEME:-dark}"
)
boot::ui::kv_dump META 2

boot::hr

# --- Timeline ------------------------------------------------------------------
EVENTS=(
  $'10:00\tStart demo'
  $'10:05\tShow logging'
  $'10:10\tShow table'
  $'10:15\tShow key-value'
  $'10:20\tShow timeline'
  $'10:25\tRun spinner'
  $'10:30\tRender progress'
  $'10:35\tFinish'
)
boot::ui::timeline EVENTS

boot::hr

# --- Spinner -------------------------------------------------------------------
boot::log info "Spinner: running a short task..."
boot::spinner --label "Simulating work (0.6s)" -- bash -lc 'sleep 0.6'

# --- Progress ------------------------------------------------------------------
boot::log info "Progress: 0..100%"
for p in 0 20 40 60 80 100; do
  boot::progress "$p" "Working..."
  sleep 0.05
done

boot::banner "Demo complete"
boot::log success "All UI components displayed successfully"
