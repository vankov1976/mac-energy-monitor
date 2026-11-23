#!/bin/bash
# App audit: what the app REALLY shows, read like VoiceOver (tools/axdump) from the real views, drawn in an invisible
# window outside the screen (nothing appears on screen), then compared between views by tools/appaudit.py.
# For each period: History, and "Sleep only" with its three tabs. Usage: tools/appaudit.sh [app binary] [out folder]
cd "$(dirname "$0")/.."
B=${1:-"build/tests/Mac Energy Monitor.app/Contents/MacOS/MacEnergyMonitor"}
OUT=${2:-$(mktemp -d)}; mkdir -p "$OUT"
# Keep the display awake while this runs: with the display asleep macOS draws no windows, not even invisible ones.
caffeinate -d -i -w $$ &
AX=build/axdump
[ -x "$AX" ] || swiftc -O -o "$AX" tools/axdump.swift || exit 1
shot() {   # like shot1, a second time if the view didn't come up (it rarely doesn't, seen on a MacBook Air)
  shot1 "$@"
  grep -qE "$2" "$1" 2>/dev/null || shot1 "$@"
}
shot1() {   # file, text that shows the view is ready, then env settings: draws the view off-screen and reads it
  local f=$1 ready=$2; shift 2
  env MEM_SHOT_W=1400 MEM_SHOT_H=4000 MEM_SHOT_WAIT=240 "$@" "$B" --background --windowshot /dev/null >/dev/null 2>&1 &
  local bp=$!
  for i in $(seq 1 45); do
    sleep 2
    "$AX" $bp dump > "$f" 2>/dev/null
    if grep -q "Energy while asleep\|Whole Mac" "$f" && grep -qE "$ready" "$f" && grep -qE "StaticText: [0-9][0-9.,]* Wh|No sleep|No wake-ups|No times found" "$f"; then
      # Finished loading only when two readings 4 s apart are the same (views update once the sleep log is read).
      for j in $(seq 1 10); do
        sleep 4; "$AX" $bp dump > "$f.2" 2>/dev/null
        cmp -s <(grep -v "until full\|left\|Calculating" "$f") <(grep -v "until full\|left\|Calculating" "$f.2") && break
        mv "$f.2" "$f"
      done
      rm -f "$f.2"; break
    fi
  done
  kill $bp 2>/dev/null; wait $bp 2>/dev/null
}
for p in "24 hours" "7 days" "All"; do
  f="$OUT/$(echo "$p" | tr ' ' '_')"
  shot "$f.history.txt" "Whole Mac" MEM_SHOT_PRESET="$p"
  shot "$f.sleeps.txt"  "Row:|No sleep" MEM_SHOT_PRESET="$p" MEM_SHOT_SLEEP=1
  shot "$f.wakes.txt"   "Row:|No wake-ups" MEM_SHOT_PRESET="$p" MEM_SHOT_SLEEP=1 MEM_SHOT_TAB=wakes
  shot "$f.nosleep.txt" "Row:|No times found" MEM_SHOT_PRESET="$p" MEM_SHOT_SLEEP=1 MEM_SHOT_TAB=nosleep
done
python3 tools/appaudit.py "$OUT"
