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

# Optional UI tuning (uncomment to tweak)
# export BOOT_THEME=dark
# export BOOT_LOG_FORMAT=text
# export BOOT_EMOJI=1

boot::banner "Functional + UI: Mini ETL Report"
boot::log info "Starting demo pipeline"
boot::hr

# ------------------------------------------------------------------------------
# 1) Dataset (TSV rows). Fields: ID,Name,Category,PriceUSD,Rating
# ------------------------------------------------------------------------------
# We'll use functional ops (map/filter/reduce/uniq/join) to transform/aggregate.
declare -a DATA_RAW=(
  $'p01\tAlice-Book\tBooks\t12.90\t4.7'
  $'p02\tBob-Mug\tHome\t7.50\t4.2'
  $'p03\tChoi-Keyboard\tElectronics\t39.00\t4.8'
  $'p04\tDana-Lamp\tHome\t24.00\t3.9'
  $'p05\tEun-SSD\tElectronics\t59.90\t4.6'
  $'p06\tFoo-Notebook\tBooks\t4.20\t4.0'
  $'p07\tGina-Mouse\tElectronics\t19.50\t4.4'
  $'p08\tHana-Pen\tOffice\t1.90\t3.8'
  $'p09\tIra-Chair\tHome\t89.00\t4.1'
  $'p10\tJin-Cable\tElectronics\t5.90\t3.7'
)

# ------------------------------------------------------------------------------
# 2) Spinner: pretend to "fetch" the dataset (wrap any command)
# ------------------------------------------------------------------------------
boot::spinner --label "Loading dataset..." -- bash -lc 'sleep 0.7'

# ------------------------------------------------------------------------------
# 3) Functional helpers: predicates and mappers
# ------------------------------------------------------------------------------
# cb_extract_category: TSV -> echo category
cb_extract_category() {
  # $1=line, $2=index
  local IFS=$'\t' id name cat price rate
  read -r id name cat price rate <<<"$1"
  printf '%s' "$cat"
}

# pd_price_ge_10: keep lines with price >= 10
pd_price_ge_10() {
  local IFS=$'\t' id name cat price rate
  read -r id name cat price rate <<<"$1"
  awk -v p="$price" 'BEGIN{exit !(p>=10)}'
}

# cb_add_discount: TSV -> TSV with 10% discounted price column appended
cb_add_discount() {
  local IFS=$'\t' id name cat price rate
  read -r id name cat price rate <<<"$1"
  # compute 10% off (floor to 2 decimals)
  local disc
  disc="$(awk -v p="$price" 'BEGIN{printf "%.2f", p*0.9}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s' "$id" "$name" "$cat" "$price" "$rate" "$disc"
}

# rd_sum_price: acc + line.price -> echo new_acc
rd_sum_price() {
  local acc="$1" line="$2"
  local IFS=$'\t' id name cat price rate
  read -r id name cat price rate <<<"$line"
  awk -v a="$acc" -v p="$price" 'BEGIN{printf "%.2f", a + p}'
}

# rd_sum_rating: acc + rating -> echo new_acc
rd_sum_rating() {
  local acc="$1" line="$2"
  local IFS=$'\t' id name cat price rate
  read -r id name cat price rate <<<"$line"
  awk -v a="$acc" -v r="$rate" 'BEGIN{printf "%.2f", a + r}'
}

# ------------------------------------------------------------------------------
# 4) Transformations
# ------------------------------------------------------------------------------
# 4.1 filter: keep price >= 10
declare -a DATA_FILT=()
boot::filter DATA_RAW DATA_FILT pd_price_ge_10

# 4.2 map: add discounted price column
declare -a DATA_DISC=()
boot::map DATA_FILT DATA_DISC cb_add_discount

# 4.3 distinct categories
declare -a CATS=() CATS_UNIQ=()
boot::map DATA_RAW CATS cb_extract_category
boot::uniq CATS CATS_UNIQ

# 4.4 reduce: totals and averages
total_price="0.00"
boot::reduce DATA_FILT 0 total_price rd_sum_price

total_rating="0.00"
boot::reduce DATA_FILT 0 total_rating rd_sum_rating

count="${#DATA_FILT[@]}"
avg_price="$(awk -v s="$total_price" -v c="$count" 'BEGIN{ if(c==0) print "0.00"; else printf "%.2f", s/c }')"
avg_rate="$(awk -v s="$total_rating" -v c="$count" 'BEGIN{ if(c==0) print "0.00"; else printf "%.2f", s/c }')"

# ------------------------------------------------------------------------------
# 5) Progress: simulate staged pipeline
# ------------------------------------------------------------------------------
for p in 0 35 65 85 100; do
  boot::progress "$p" "Processing... ($p%)"
  sleep 0.15
done
boot::hr

# ------------------------------------------------------------------------------
# 6) KV summary (associative array)
# ------------------------------------------------------------------------------
declare -A SUMMARY=(
  ["items_total"]="${#DATA_RAW[@]}"
  ["items_kept(>=10)"]="$count"
  ["categories_distinct"]="${#CATS_UNIQ[@]}"
  ["avg_price_kept"]="$avg_price"
  ["avg_rating_kept"]="$avg_rate"
)
boot::log info "Summary"
boot::ui::kv_dump SUMMARY 1
boot::hr

# ------------------------------------------------------------------------------
# 7) Table (HEAD/ROWS) — show discounted prices and sort by Discounted
# ------------------------------------------------------------------------------
declare -a HEAD=(ID Name Category PriceUSD Rating Discounted)
# Build ROWS from DATA_DISC (already includes Discounted column at the end)
declare -a ROWS=("${DATA_DISC[@]}")

boot::log info "Kept items with 10% discount (sorted by Discounted desc)"
boot::ui::table HEAD ROWS --sort Discounted --desc
boot::hr

# ------------------------------------------------------------------------------
# 8) Timeline
# ------------------------------------------------------------------------------
declare -a EVENTS=(
  $'18:05\tFetch dataset'
  $'18:06\tFilter price >= 10'
  $'18:06\tMap discount column'
  $'18:06\tAggregate metrics'
  $'18:07\tRender report'
  $'18:07\tDone ✅'
)
boot::ui::timeline EVENTS
boot::hr

# ------------------------------------------------------------------------------
# 9) Show category list using join
# ------------------------------------------------------------------------------
boot::log info "Distinct categories"
boot::join CATS_UNIQ ", "