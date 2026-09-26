#!/bin/zsh
# Builds "Claude Permission Inspector.app" into ./build and ad-hoc signs it.
#
# Note: with ad-hoc signing, every rebuild changes the code signature, so a
# Full Disk Access grant from a previous build stops applying. After
# rebuilding, remove the app from the Full Disk Access list and add it again.
set -euo pipefail
cd "${0:A:h}"

APP="build/Claude Permission Inspector.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/ClaudePermInspector.swift \
  -o "$APP/Contents/MacOS/ClaudePermInspector"
cp Info.plist "$APP/Contents/Info.plist"

# App icon: Resources/AppIcon.svg -> .iconset -> AppIcon.icns
rm -rf build/AppIcon.iconset
swift Scripts/make-iconset.swift Resources/AppIcon.svg build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

codesign --force --sign - "$APP"

echo "Built: $PWD/$APP"
