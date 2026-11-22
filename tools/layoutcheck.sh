#!/bin/bash
# Layout check: every view drawn off-screen at the smallest window size (content 940 × 470 pt, as the window's
# minimum in App.swift); fails when the top controls, the footer or the content lie outside the window.
# Usage: tools/layoutcheck.sh [app binary] [png folder]. Prints "FAIL: …" lines on problems.
B=${1:-"$(dirname "$0")/../build/tests/Mac Energy Monitor.app/Contents/MacOS/MacEnergyMonitor"}
OUT=${2:-$(mktemp -d)}; mkdir -p "$OUT"
W=940; H=470
shot() {   # name, then env settings
  local name=$1; shift
  env MEM_SHOT_W=$W MEM_SHOT_H=$H MEM_SHOT_WAIT=${MEM_SHOT_WAIT:-10} MEM_SHOT_CHECK="$name" "$@" \
    timeout 120 "$B" --background --windowshot "$OUT/$(echo "$name" | tr ' ' '-').png" 2>&1 | grep -E "^(layout|FAIL)"
}
shot "Live" MEM_SHOT_PRESET=Live
shot "History 24 h" MEM_SHOT_PRESET="24 hours"
shot "Sleep only Sleeps" MEM_SHOT_PRESET="24 hours" MEM_SHOT_SLEEP=1
shot "Sleep only Wake-ups" MEM_SHOT_PRESET="24 hours" MEM_SHOT_SLEEP=1 MEM_SHOT_TAB=wakes
shot "Sleep only Didn't sleep" MEM_SHOT_PRESET="24 hours" MEM_SHOT_SLEEP=1 MEM_SHOT_TAB=nosleep
shot "Battery" MEM_SHOT_PRESET="24 hours" MEM_SHOT_BATTERY=1
echo "screenshots: $OUT"
