#!/bin/bash
set -euo pipefail

# build-app.sh — assemble PortKit.app (swiftc, no Xcode project) and a DMG.
# The app bundles chrome-to-safari.sh + lib/ and drives them; the script stays
# the single source of truth. Plain app (no App Groups / extension), so ad-hoc
# signing is fine — auto-upgrades to a Developer ID cert if one is present.
#
# Usage: scripts/build-app.sh [--app-only]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PortKit"
BUNDLE_ID="com.portkit"
VERSION="1.0.0"
MIN_MACOS="13.0"

BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> Clean"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "==> Icon"
swift "$ROOT/scripts/make_icon.swift" "$RES/$APP_NAME.icns" >/dev/null

echo "==> Compile UI"
swiftc -O -parse-as-library -target arm64-apple-macos$MIN_MACOS \
  "$ROOT/ui.swift" -o "$MACOS/$APP_NAME" \
  -framework SwiftUI -framework AppKit

echo "==> Bundle engine"
cp "$ROOT/chrome-to-safari.sh" "$RES/"
cp -R "$ROOT/lib" "$RES/lib"
rm -rf "$RES/lib/__pycache__"   # don't ship stale bytecode in a signed bundle
chmod +x "$RES/chrome-to-safari.sh"

echo "==> Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Sign"
# Prefer a Developer ID cert if the machine has one; else ad-hoc. grep exits
# nonzero on no match — tolerate it under set -e.
CERT="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
if [ -n "$CERT" ]; then
  echo "    using: $CERT"
  codesign --force --options runtime --timestamp --sign "$CERT" "$APP"
else
  echo "    ad-hoc (no Developer ID cert found)"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP" && echo "    signature ok"

if [ "${1:-}" = "--app-only" ]; then
  echo ""
  echo "Done. App at: $APP"
  exit 0
fi

echo "==> DMG"
DMG="$BUILD/$APP_NAME.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo ""
echo "Done."
echo "  App: $APP"
echo "  DMG: $DMG"
[ -z "$CERT" ] && echo "  (ad-hoc signed — first launch needs right-click > Open, or System Settings > Privacy & Security > Open Anyway)"
