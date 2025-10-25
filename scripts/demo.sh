#!/usr/bin/env bash
# scripts/demo.sh - Unified demo for the boot framework
# Demonstrates usage of: core, ui, network, path
#
# Usage:
#   bash scripts/demo.sh

set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${ROOT}/boot.sh"

boot::strict

# --- demo start ---------------------------------------------------------------
boot::banner "Boot Framework Demo"
boot::log info "Boot version: ${BOOT_VERSION:-unknown}"
boot::log info "All modules loaded successfully"

# --- CORE ---------------------------------------------------------------------
boot::hr
boot::banner "Core Utilities"

boot::log info "Testing safe try()"
OUT="" ERR=""
if boot::try OUT ERR -- bash -lc 'echo "ok"; >&2 echo "warn"' ; then
  boot::log success "OUT='$OUT' ERR='$ERR'"
fi

boot::log info "Testing retry() with exponential backoff"
boot::retry 3 boot::backoff_expo 0.1 -- bash -lc 'false' || boot::log warn "retry() gave up as expected"

boot::log info "Testing cache memoization"
boot::cache_memo "time_1s" 2 -- date +%s

# --- NETWORK ------------------------------------------------------------------
boot::hr
boot::banner "Network Utilities"

if declare -F boot::net_http >/dev/null; then
  BODY="" CODE=""
  boot::log info "Fetching https://httpbin.org/get"
  if boot::net_http GET "https://httpbin.org/get" BODY CODE --timeout 3; then
    boot::log success "HTTP $CODE (body.len=${#BODY})"
  else
    boot::log error "HTTP request failed"
  fi
fi

if declare -F boot::tls_expiry >/dev/null; then
  EXP="$(boot::tls_expiry google.com:443 --cache-ttl 300 || true)"
  boot::log info "TLS expiry for google.com: $EXP"
fi

if declare -F boot::alpn >/dev/null; then
  ALPN="$(boot::alpn google.com:443 || true)"
  boot::log info "ALPN negotiated: $ALPN"
fi

# --- PATH ---------------------------------------------------------------------
boot::hr
boot::banner "Path Helpers"

if declare -F boot::path_win2wsl >/dev/null; then
  boot::log info "Win2WSL: $(boot::path_win2wsl 'C:\\Users\\Alice\\project')"
fi

if declare -F boot::path_wsl2win >/dev/null; then
  boot::log info "WSL2Win: $(boot::path_wsl2win '/mnt/c/Users/Alice/project')"
fi

if declare -F boot::path_normalize >/dev/null; then
  boot::log info "Normalize: $(boot::path_normalize './tmp/../boot')"
fi

# --- UI / VISUAL --------------------------------------------------------------
boot::hr
boot::banner "UI Showcase"

if declare -F boot::ui_table >/dev/null; then
  HEADERS=("ID" "Name" "Score")
  ROWS=("1|Alice|98" "2|Bob|87" "3|Charlie|91")
  boot::ui_table HEADERS ROWS
fi

if declare -F boot::ui_kv_dump >/dev/null; then
  declare -A INFO=(
    [features]="core,ui,network,path"
    [version]="${BOOT_VERSION}"
    [lang]="bash"
  )
  boot::ui_kv_dump INFO 2
fi

if declare -F boot::ui_timeline >/dev/null; then
  EVENTS=("10:00 Start demo" "10:05 Core tests" "10:10 Network" "10:15 Path" "10:20 UI done")
  boot::ui_timeline EVENTS
fi

boot::spinner --label "Preparing environment..." -- sleep 1
boot::progress 80 "Almost done..."

# --- DONE ---------------------------------------------------------------------
boot::hr
boot::banner "Demo Complete"
boot::log success "✅ All boot subsystems working properly!"
