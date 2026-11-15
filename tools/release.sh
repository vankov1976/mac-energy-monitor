#!/bin/bash
# Release build: builds the app, signs it with your "Developer ID Application" certificate (hardened runtime),
# has Apple notarize it, staples the ticket and writes build/Mac-Energy-Monitor.zip.
# Needs an Apple Developer Program membership, the certificate in your keychain and a notarytool profile:
#   xcrun notarytool store-credentials notary --apple-id <your Apple ID> --team-id <your team ID>
# Optional: NOTARY_PROFILE (default "notary"), DEVELOPER_ID (default: the first Developer ID Application identity).
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-notary}"
ID="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[ -n "$ID" ] || { echo "No 'Developer ID Application' certificate found in the keychain." >&2; exit 1; }

APP="build/Mac Energy Monitor.app"
ZIP="build/Mac-Energy-Monitor.zip"

./build.sh
echo "Signing with: $ID"
codesign --force --options runtime --timestamp --sign "$ID" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "Notarizing (usually a few minutes)…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling…"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release: $ZIP"
