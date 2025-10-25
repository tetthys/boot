#!/usr/bin/env bash
# scripts/demo.sh - Boot toolkit end-to-end demo (UI, PATH, NETWORK)
# Requires: Bash 5+, curl (for HTTP), openssl (for TLS/ALPN demo, optional)

set -Eeuo pipefail

##**
# Resolve repo root and load boot.
# - Assumes: boot.sh at repo root that sources core/ui/path/network.
##*
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=/dev/null
source "${ROOT}/boot.sh"

boot::strict
BOOT_LOG_LEVEL="${BOOT_LOG_LEVEL:-debug}"  # can override externally

boot::banner "Boot Demo (version ${BOOT_VERSION:-N/A})"

# ==============================================================================
# UI SHOWCASE
# ==============================================================================

boot::log info "UI showcase: table / key-value / timeline / spinner / progress"

## Table -----------------------------------------------------------------------
HEAD=(ID Name Score)
ROWS=($'1\tAlice\t98' $'2\tBob\t87' $'3\tCharlie\t91')
boot::ui::table HEAD ROWS

## Key-Value dump --------------------------------------------------------------
declare -A INFO=(
  [project]="boot"
  [language]="bash"
  [features]="ui,path,network"
  [version]="${BOOT_VERSION:-N/A}"
)
boot::ui::kv_dump INFO 2

## Timeline --------------------------------------------------------------------
EV=(
  $'10:00\tStart demo'
  $'10:05\tUI showcase'
  $'10:10\tPATH helpers'
  $'10:15\tNETWORK checks'
  $'10:20\tFinish'
)
boot::ui::timeline EV

## Spinner & Progress ----------------------------------------------------------
boot::spinner -- bash -lc 'sleep 0.5' "Preparing environment"
for p in 0 20 40 60 80 100; do boot::progress "$p" "Working"; sleep 0.05; done
boot::hr

# ==============================================================================
# PATH HELPERS
# ==============================================================================

boot::log info "PATH helpers"

# Join / abs / rel
joined="$(boot::path::join_e "/var" "log" "nginx" "access.log")"
abs="$(boot::path::abs "$joined")"
rel="$(boot::path::rel "/var/log" "$abs")"
boot::log success "join      : $joined"
boot::log success "abs       : $abs"
boot::log success "rel(base=/var/log): $rel"

# WSL/Windows conversions
win_ex="D:\\Work\\data\\file.txt"
wsl_from_win="$(boot::path::win_to_wsl "$win_ex")"
wsl_ex="/mnt/c/Users/Public/Documents/Report.pdf"
win_from_wsl="$(boot::path::wsl_to_win "$wsl_ex")"
if boot::path::is_wsl; then
  boot::log notice "WSL detected"
else
  boot::log notice "WSL not detected"
fi
boot::log success "win->wsl  : $win_ex  ->  $wsl_from_win"
boot::log success "wsl->win  : $wsl_ex  ->  $win_from_wsl"
boot::hr

# ==============================================================================
# NETWORK HELPERS
# ==============================================================================

boot::log info "NETWORK helpers"

# HTTP GET demo
if boot::require curl >/dev/null; then
  body="" status=""
  boot::net::http GET "https://httpbin.org/get" body status --timeout 6 --max-retry 2
  boot::log success "httpbin status=$status, body.len=${#body}"
else
  boot::log warn "curl not found; skipping HTTP demo"
fi

# TLS expiry & ALPN (optional: needs openssl)
if command -v openssl >/dev/null 2>&1; then
  host="example.com"
  days="" exp=""
  if boot::net::tls_expiry "$host" 443 days exp --timeout 8; then
    boot::log notice "TLS notAfter ($host): $exp"
    boot::log success "TLS days remaining : $days day(s)"
  else
    boot::log warn "TLS expiry check failed for $host"
  fi

  alpn=""
  if boot::net::alpn "$host" 443 alpn --timeout 8; then
    boot::log success "ALPN negotiated    : $alpn"
  else
    boot::log warn "ALPN check failed for $host"
  fi

  # HTTP protocol version (curl-based)
  ver=""
  if boot::net::http_version "https://$host" ver; then
    boot::log success "HTTP version (curl): $ver"
  fi
else
  boot::log warn "openssl not found; skipping TLS/ALPN demo"
fi

boot::hr

# ==============================================================================
# MINI REPORT (table)
# ==============================================================================

boot::log info "Mini report (table rendering)"

HEAD2=("Section" "Item" "Value")
ROWS2=()
ROWS2+=($'UI\tTable rows\t3')
ROWS2+=($'UI\tKV entries\t'"${#INFO[@]}")
ROWS2+=($'PATH\tWSL?\t'"$(boot::path::is_wsl && echo yes || echo no)")
if command -v curl >/dev/null 2>&1; then
  ROWS2+=($'NET\tcurl\tavailable')
else
  ROWS2+=($'NET\tcurl\tmissing')
fi
if command -v openssl >/dev/null 2>&1; then
  ROWS2+=($'NET\topenssl\tavailable')
else
  ROWS2+=($'NET\topenssl\tmissing')
fi
boot::ui::table HEAD2 ROWS2

boot::log success "Demo completed ✅"
