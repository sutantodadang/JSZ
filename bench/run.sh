#!/usr/bin/env bash
# Comparative benchmark runner: jsz vs QuickJS (qjs) vs Node.
# Each workload in bench/js/ self-times its hot section and prints
# "name,ms,checksum". This script runs each workload RUNS times per engine,
# takes the median, checks checksums agree across engines, and prints a
# markdown table.
#
# Usage: bench/run.sh [path-to-jsz]   (default: ./zig-out/bin/jsz)
set -u

JSZ="${1:-./zig-out/bin/jsz}"
RUNS="${RUNS:-5}"
DIR="$(dirname "$0")/js"

engines=()
names=()
if [ -x "$JSZ" ] || command -v "$JSZ" >/dev/null 2>&1; then
  engines+=("$JSZ"); names+=("jsz")
else
  echo "jsz binary not found at '$JSZ' — build first (zig build)" >&2
  exit 1
fi
if command -v qjs >/dev/null 2>&1; then engines+=("qjs"); names+=("quickjs"); fi
if command -v node >/dev/null 2>&1; then engines+=("node"); names+=("node"); fi

median() { # args: sorted-able list of ints
  local sorted=($(printf '%s\n' "$@" | sort -n))
  echo "${sorted[$(( ${#sorted[@]} / 2 ))]}"
}

# Header
hdr="| workload |"; sep="|---|"
for n in "${names[@]}"; do hdr="$hdr $n (ms) |"; sep="$sep---|"; done
echo "$hdr"
echo "$sep"

status=0
for f in "$DIR"/*.js; do
  wname="$(basename "$f" .js)"
  row="| $wname |"
  ref_check=""
  for idx in "${!engines[@]}"; do
    eng="${engines[$idx]}"
    times=()
    check=""
    for ((r = 0; r < RUNS; r++)); do
      out="$("$eng" "$f" 2>/dev/null | grep "^$wname," | tail -1)" || true
      if [ -z "$out" ]; then check="ERR"; break; fi
      IFS=',' read -r _ ms ck <<<"$out"
      times+=("$ms"); check="$ck"
    done
    if [ "$check" = "ERR" ] || [ ${#times[@]} -eq 0 ]; then
      row="$row fail |"
      status=1
      continue
    fi
    # Checksum must agree across engines — otherwise engines did different work.
    if [ -z "$ref_check" ]; then
      ref_check="$check"
    elif [ "$check" != "$ref_check" ]; then
      row="$row MISMATCH($check!=$ref_check) |"
      status=1
      continue
    fi
    row="$row $(median "${times[@]}") |"
  done
  echo "$row"
done
exit "$status"
