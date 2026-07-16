#!/bin/bash
set -euo pipefail

# chrome-to-safari.sh — convert any Chrome / WebExtension into a signed,
# installed Safari extension. No paid Apple Developer ID needed.
#
# Usage:
#   ./chrome-to-safari.sh /path/to/extension              # convert + build + install + launch
#   ./chrome-to-safari.sh <chrome-web-store-url>          # download from the store, then same
#   ./chrome-to-safari.sh /path/to/extension --build-only # convert + build, don't install
#   ./chrome-to-safari.sh --ui                            # open the native app UI
#
# Env overrides (all optional):
#   APP_NAME    display name        (default: "name" from manifest.json)
#   BUNDLE_ID   bundle identifier   (default: com.converted.<slug>)
#   TEAM_ID     Apple team ID       (default: auto-detected from your keychain)
#   OUT_DIR     output directory    (default: ./<slug>-safari next to the extension)

# --- Native UI ----------------------------------------------------------------
# compiled from ui.swift on the user's own machine, so Gatekeeper never sees it
if [ "${1:-}" = "--ui" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  UI_SRC="$SCRIPT_DIR/ui.swift"
  UI_BIN="$SCRIPT_DIR/.ui/ChromeToSafari"
  if [ ! -x "$UI_BIN" ] || [ "$UI_SRC" -nt "$UI_BIN" ]; then
    echo "==> Compiling the UI (first run only)..."
    mkdir -p "$SCRIPT_DIR/.ui"
    swiftc -O -parse-as-library "$UI_SRC" -o "$UI_BIN"
  fi
  exec env C2S_SCRIPT="$SCRIPT_DIR/chrome-to-safari.sh" "$UI_BIN"
fi

EXT_DIR="${1:?usage: chrome-to-safari.sh /path/to/extension|<store-url> [--build-only], or --ui}"
BUILD_ONLY="${2:-}"

# --- Chrome Web Store URL? Download and unpack first --------------------------
if [[ "$EXT_DIR" == http*://* ]]; then
  # store URLs: .../detail/<slug>/<32-char-id>; IDs use letters a-p only
  EXT_ID="$(printf '%s' "$EXT_DIR" | grep -oE '[a-p]{32}' | head -1)"
  if [ -z "$EXT_ID" ]; then
    echo "ERROR: no extension ID in that URL. Expected a Chrome Web Store link like" >&2
    echo "  https://chromewebstore.google.com/detail/<name>/<32-char-id>" >&2
    exit 1
  fi
  # use the URL's name slug as the folder name so APP_NAME falls back to it
  URL_SLUG="$(printf '%s' "$EXT_DIR" | sed -n 's|.*/detail/\([^/]*\)/.*|\1|p')"
  DL_DIR="$(mktemp -d)/${URL_SLUG:-$EXT_ID}"
  mkdir -p "$DL_DIR"
  echo "==> Downloading $EXT_ID from Chrome Web Store..."
  curl -fsSL -o "$DL_DIR.crx" \
    "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=131.0&acceptformat=crx2,crx3&x=id%3D${EXT_ID}%26uc"
  # a .crx is a zip with a binary header; unzip skips the junk but exits nonzero
  unzip -qo "$DL_DIR.crx" -d "$DL_DIR" 2>/dev/null || true
  if [ ! -f "$DL_DIR/manifest.json" ]; then
    echo "ERROR: download failed — no manifest.json in the downloaded package" >&2
    exit 1
  fi
  rm -rf "$DL_DIR/_metadata"   # store signing artifacts; the converter chokes on them
  EXT_DIR="$DL_DIR"
  OUT_BASE="$PWD"              # don't leave build output in the temp dir
fi

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
OUT_DIR="${OUT_DIR:-${OUT_BASE:-$(dirname "$EXT_DIR")}/$SLUG-safari}"

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
