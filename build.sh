#!/bin/bash
# Builds "Mac Energy Monitor.app" into ./build (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

# `./build.sh --tests`: a test build with the command-line checks (Sources/Diagnostics) in build/tests.
APP="build/Mac Energy Monitor.app"; EXTRA=()
if [ "${1:-}" = "--tests" ]; then
  APP="build/tests/Mac Energy Monitor.app"; EXTRA=(-D DIAGNOSTICS Sources/Diagnostics/*.swift)
fi
rm -rf "$APP" build/icon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos14 \
  -o "$APP/Contents/MacOS/MacEnergyMonitor" \
  Sources/*.swift ${EXTRA[@]+"${EXTRA[@]}"}

echo "Making icon…"
swift tools/make_icon.swift build/icon.iconset
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/icon.iconset

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mac Energy Monitor</string>
  <key>CFBundleDisplayName</key><string>Mac Energy Monitor</string>
  <key>CFBundleIdentifier</key><string>local.mac-energy-monitor</string>
  <key>CFBundleExecutable</key><string>MacEnergyMonitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.1.7</string>
  <key>CFBundleVersion</key><string>2.1.7</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST


codesign --force --sign - "$APP" >/dev/null
echo "Built: $APP"
