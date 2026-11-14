#!/bin/bash
# Runs the saved-history gap tests (--gaptest) with made-up days in a temporary test folder,
# never in the real history folder. The test folder is deleted afterwards.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="build/Mac Energy Monitor.app/Contents/MacOS/MacEnergyMonitor"
T=$(mktemp -d "${TMPDIR:-/tmp}/mem-gaptest.XXXXXX")
trap 'rm -rf "$T"' EXIT
rc=0
MEM_ARCHIVE_DIR="$T/main" TZ=Europe/Berlin "$BIN" --gaptest all || rc=1
MEM_ARCHIVE_DIR="$T/tz" TZ=Europe/Berlin "$BIN" --gaptest tzwrite >/dev/null || rc=1
MEM_ARCHIVE_DIR="$T/tz" TZ=America/New_York "$BIN" --gaptest tzread || rc=1
[ $rc -eq 0 ] && echo "ALL GAP TESTS PASSED" || echo "SOME GAP TESTS FAILED"
exit $rc
