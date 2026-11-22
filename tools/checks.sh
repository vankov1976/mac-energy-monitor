#!/bin/bash
# All correctness checks on this Mac (test build). Usage: tools/checks.sh [--no-build]
# Never `open` the app while this runs: the test build has the same bundle id.
cd "$(dirname "$0")/.."
[ "$1" = "--no-build" ] || ./build.sh --tests >/dev/null || exit 1
B="build/tests/Mac Energy Monitor.app/Contents/MacOS/MacEnergyMonitor"
# archive check: whole days (saved summaries cover whole days)
from=$(date -j -v-7d -v0H -v0M -v0S +%s); pretend=$(date -j -v-3d -v0H -v0M -v0S +%s)
# unknown check: needs summaries WITHOUT sleep data -> copy of an old archive (set OLD_ARCHIVE), else skipped
OLD_ARCHIVE=${OLD_ARCHIVE:-}
run() { echo "== $1"; shift; timeout 900 "$@" 2>&1 | awk '/FAIL:/ {print; next} {l[NR%2]=$0} END {print l[(NR+1)%2]; print l[NR%2]}'; }   # every FAIL line, then the last 2 lines
run verify "$B" --verify
MEM_PRETEND_LAG=3600 run "verify lag" "$B" --verify
T=$(mktemp -d); cp -R ~/Library/Application\ Support/MacEnergyMonitor/Daily/. "$T" 2>/dev/null
TZ=America/New_York MEM_ARCHIVE_DIR="$T" run "verify NY (temp archive)" "$B" --verify; rm -rf "$T"
if [ -n "$OLD_ARCHIVE" ]; then
  T=$(mktemp -d); cp -R "$OLD_ARCHIVE"/. "$T"
  MEM_ARCHIVE_DIR="$T" run unknown "$B" --unknowncheck $(date -j -f "%Y-%m-%d %H:%M" "2026-11-11 00:00" +%s) $(date -j -f "%Y-%m-%d %H:%M" "2026-11-14 00:00" +%s)
  rm -rf "$T"
else echo "== unknown: skipped (set OLD_ARCHIVE)"; fi
echo "== archive"; timeout 900 "$B" --archivecheck $from $pretend 2>&1 | grep -E "saved|whole"
run filter "$B" --filtercheck
run sleep "$B" --sleepcheck 7
run battery "$B" --batterycheck
run charges "$B" --chargecheck
run sleepcompare "$B" --sleepcompare
echo "== layout (smallest window)"; tools/layoutcheck.sh "$B" 2>&1 | grep -v "^screenshots"
echo "== gap"; tools/gaptest.sh 2>&1 | tail -3
