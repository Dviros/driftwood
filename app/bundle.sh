#!/usr/bin/env bash
# Build the SwiftUI launcher and wrap it into a double-clickable .app.
# Needs only Command Line Tools (no full Xcode). Ad-hoc signs so it runs locally.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="driftwood.app"
BIN=".build/release/Driftwood"

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/driftwood"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>driftwood</string>
  <key>CFBundleDisplayName</key><string>driftwood</string>
  <key>CFBundleIdentifier</key><string>io.driftwood.launcher</string>
  <key>CFBundleExecutable</key><string>driftwood</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep -s - "${APP}" >/dev/null 2>&1 || true
echo "built ${APP}  —  run it with:  open ${APP}"
