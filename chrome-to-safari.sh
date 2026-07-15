#!/bin/bash
set -euo pipefail

# chrome-to-safari.sh — convert any Chrome / WebExtension into a signed,
# installed Safari extension. No paid Apple Developer ID needed.
#
# Usage:
#   ./chrome-to-safari.sh /path/to/extension              # convert + build + install + launch
#   ./chrome-to-safari.sh /path/to/extension --build-only # convert + build, don't install
#
# Env overrides (all optional):
#   APP_NAME    display name        (default: "name" from manifest.json)
#   BUNDLE_ID   bundle identifier   (default: com.converted.<slug>)
#   TEAM_ID     Apple team ID       (default: auto-detected from your keychain)
#   OUT_DIR     output directory    (default: ./<slug>-safari next to the extension)

EXT_DIR="${1:?usage: chrome-to-safari.sh /path/to/extension [--build-only]}"
BUILD_ONLY="${2:-}"

EXT_DIR="$(cd "$EXT_DIR" && pwd)"
MANIFEST="$EXT_DIR/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: no manifest.json in $EXT_DIR — is this a WebExtension?" >&2
  exit 1
fi

# --- Names ------------------------------------------------------------------
if [ -z "${APP_NAME:-}" ]; then
  APP_NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$MANIFEST")"
  # i18n manifests use "__MSG_key__" placeholders; fall back to folder name
  case "$APP_NAME" in ""|__MSG_*) APP_NAME="$(basename "$EXT_DIR")";; esac
fi

SLUG="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')"
BUNDLE_ID="${BUNDLE_ID:-com.converted.$SLUG}"
OUT_DIR="${OUT_DIR:-$(dirname "$EXT_DIR")/$SLUG-safari}"

echo "==> App name:  $APP_NAME"
echo "==> Bundle ID: $BUNDLE_ID"
echo "==> Output:    $OUT_DIR"

# --- Signing identity ---------------------------------------------------------
# ponytail: picks first Apple Development cert; set TEAM_ID env var to override
TEAM_ID="${TEAM_ID:-$(security find-certificate -c "Apple Development" -p 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null \
  | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')}"

if [ -z "$TEAM_ID" ]; then
  cat >&2 <<'EOF'
ERROR: No Apple Development certificate found.

One-time setup (free, no paid developer account needed):
  1. Open Xcode > Settings > Accounts
  2. Click "+" and sign in with your Apple ID
  3. Select your account > "Manage Certificates..." > "+" > "Apple Development"
  4. Re-run this script

Without this, Safari treats the extension as unsigned and disables it
on every restart.
EOF
  exit 1
fi
echo "==> Team ID:   $TEAM_ID"

# --- Convert ------------------------------------------------------------------
echo "==> Converting with safari-web-extension-converter..."
xcrun safari-web-extension-converter "$EXT_DIR" \
  --project-location "$OUT_DIR" \
  --app-name "$APP_NAME" \
  --bundle-identifier "$BUNDLE_ID" \
  --macos-only --copy-resources --no-open --no-prompt --force

PROJECT="$OUT_DIR/$APP_NAME/$APP_NAME.xcodeproj"
if [ ! -d "$PROJECT" ]; then
  echo "ERROR: converter did not produce $PROJECT" >&2
  exit 1
fi

# The converter sometimes derives the app's bundle ID from the app name while
# giving the extension the ID passed via --bundle-identifier. If they differ
# (even by case), the build fails with "Embedded binary's bundle identifier is
# not prefixed with the parent app's bundle identifier". Normalize: make the
# extension's ID always be <app ID>.Extension.
PBX="$PROJECT/project.pbxproj"
APP_ID="$(grep -o 'PRODUCT_BUNDLE_IDENTIFIER = "\{0,1\}[^";]*' "$PBX" \
  | sed 's/.*= "\{0,1\}//' | grep -v '\.Extension$' | head -1)"
sed -i '' "s/PRODUCT_BUNDLE_IDENTIFIER = \"\{0,1\}[^\";]*\.Extension\"\{0,1\};/PRODUCT_BUNDLE_IDENTIFIER = \"$APP_ID.Extension\";/g" "$PBX"

# --- Build --------------------------------------------------------------------
echo "==> Building..."
rm -rf "$OUT_DIR/build/Build/Products"   # no stale products from failed runs
xcodebuild \
  -project "$PROJECT" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$OUT_DIR/build" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  build 2>&1 | grep -E "BUILD|error|Cycle"

APP="$OUT_DIR/build/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$APP" ]; then
  echo "ERROR: build product not found at $APP" >&2
  exit 1
fi

echo "==> Verifying signature..."
codesign --verify --deep --strict "$APP"

if [ "$BUILD_ONLY" = "--build-only" ]; then
  echo ""
  echo "Done (build only). App at: $APP"
  exit 0
fi

# --- Install + launch -----------------------------------------------------------
echo "==> Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP" /Applications/

/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f -R -trusted "/Applications/$APP_NAME.app"

open -a "/Applications/$APP_NAME.app"
sleep 2
open -a Safari

echo ""
echo "Done. Enable it in Safari > Settings > Extensions."
