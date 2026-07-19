#!/bin/bash
set -euo pipefail

# chrome-to-safari.sh — PortKit engine. Convert any Chrome / WebExtension into a
# signed, installed Safari extension. No paid Apple Developer ID needed.
#
# Usage:
#   ./chrome-to-safari.sh <input> [flags]
#     <input>  a folder, a .crx/.zip/.xpi file, a Chrome Web Store URL,
#              or a direct .crx/.zip download URL
#   flags:
#     --build-only   convert + build, don't install to /Applications
#     --analyze      report Safari-compat issues and exit (no build)
#     --json         with --analyze, print machine-readable JSON
#     --temp-load    stage for Safari's "Add Temporary Extension" (no Xcode)
#     --keep-module  keep background.type:"module" (default strips it)
#   ./chrome-to-safari.sh --ui                     # open the PortKit app UI
#
# Env overrides (all optional):
#   APP_NAME   display name        (default: "name" from manifest.json)
#   BUNDLE_ID  bundle identifier   (default: com.converted.<slug>)
#   TEAM_ID    Apple team ID       (default: auto-detected from your keychain)
#   OUT_DIR    output directory    (default: ./<slug>-safari next to the input)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/lib"

# --- Native UI ----------------------------------------------------------------
# compiled from ui.swift on the user's own machine, so Gatekeeper never sees it
if [ "${1:-}" = "--ui" ]; then
  UI_SRC="$SCRIPT_DIR/ui.swift"
  UI_BIN="$SCRIPT_DIR/.ui/PortKit"
  if [ ! -x "$UI_BIN" ] || [ "$UI_SRC" -nt "$UI_BIN" ]; then
    echo "==> Compiling the UI (first run only)..."
    mkdir -p "$SCRIPT_DIR/.ui"
    swiftc -O -parse-as-library "$UI_SRC" -o "$UI_BIN"
  fi
  exec env C2S_SCRIPT="$SCRIPT_DIR/chrome-to-safari.sh" "$UI_BIN"
fi

# --- Parse args ---------------------------------------------------------------
INPUT="${1:?usage: chrome-to-safari.sh <folder|.crx|.zip|url> [--build-only|--analyze|--temp-load], or --ui}"
shift || true
BUILD_ONLY="" ANALYZE="" JSON="" TEMP_LOAD="" KEEP_MODULE=""
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --analyze)    ANALYZE=1 ;;
    --json)       JSON=1 ;;
    --temp-load)  TEMP_LOAD=1 ;;
    --keep-module) KEEP_MODULE=1 ;;
    *) echo "ERROR: unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# --- Resolve input to a directory containing manifest.json --------------------
# EXT_DIR ends up pointing at the unpacked extension. FROM_TEMP marks that the
# source lives in a temp dir, so build output must not be written beside it.
EXT_DIR="" FROM_TEMP=""

unpack_archive() {   # $1 = archive file -> echoes the dir holding manifest.json
  local file="$1" magic dest
  magic="$(head -c 4 "$file" | xxd -p 2>/dev/null || true)"
  case "$magic" in
    43723234*) : ;;   # "Cr24" — CRX (a zip with a signed header)
    504b0304*) : ;;   # "PK\x03\x04" — ZIP / XPI
    *) echo "ERROR: $file is not a .crx/.zip/.xpi (magic bytes: ${magic:-none})" >&2; exit 1 ;;
  esac
  dest="$(mktemp -d)/unpacked"
  mkdir -p "$dest"
  # a .crx carries a binary header before the zip; unzip skips it but exits nonzero
  unzip -qo "$file" -d "$dest" 2>/dev/null || true
  # manifest at root, or wrapped one folder deep
  local mf
  mf="$(find "$dest" -maxdepth 2 -name manifest.json 2>/dev/null | head -1)"
  [ -n "$mf" ] || { echo "ERROR: no manifest.json inside $file" >&2; exit 1; }
  dirname "$mf"
}

if [[ "$INPUT" == http*://* ]]; then
  # Store URLs look like .../detail/<slug>/<32-char id> (IDs use a-p only).
  EXT_ID="$(printf '%s' "$INPUT" | grep -oE '[a-p]{32}' | head -1 || true)"
  DL="$(mktemp -d)/download.crx"
  if [ -n "$EXT_ID" ]; then
    echo "==> Downloading $EXT_ID from Chrome Web Store..."
    curl -fsSL -o "$DL" \
      "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=131.0&acceptformat=crx2,crx3&x=id%3D${EXT_ID}%26uc"
  else
    echo "==> Downloading $INPUT ..."
    curl -fsSL -o "$DL" "$INPUT"
  fi
  EXT_DIR="$(unpack_archive "$DL")"
  FROM_TEMP=1
elif [ -f "$INPUT" ]; then
  echo "==> Unpacking $INPUT ..."
  EXT_DIR="$(unpack_archive "$INPUT")"
  FROM_TEMP=1
elif [ -d "$INPUT" ]; then
  EXT_DIR="$(cd "$INPUT" && pwd)"
else
  echo "ERROR: $INPUT is not a folder, file, or URL" >&2; exit 1
fi

MANIFEST="$EXT_DIR/manifest.json"
[ -f "$MANIFEST" ] || { echo "ERROR: no manifest.json in $EXT_DIR — is this a WebExtension?" >&2; exit 1; }

# --- Analyze: report and stop, no staging, no build ---------------------------
if [ -n "$ANALYZE" ]; then
  python3 "$LIB/manifest_fix.py" "$MANIFEST" --analyze ${JSON:+--json}
  exit 0
fi

# --- Names --------------------------------------------------------------------
if [ -z "${APP_NAME:-}" ]; then
  APP_NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$MANIFEST")"
  # i18n manifests use "__MSG_key__" placeholders; fall back to folder name
  case "$APP_NAME" in ""|__MSG_*) APP_NAME="$(basename "$EXT_DIR")";; esac
fi
SLUG="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')"
BUNDLE_ID="${BUNDLE_ID:-com.converted.$SLUG}"
[ -n "$FROM_TEMP" ] && OUT_BASE="$PWD" || OUT_BASE="$(dirname "$EXT_DIR")"
OUT_DIR="${OUT_DIR:-$OUT_BASE/$SLUG-safari}"

# --- Stage: copy, fix the manifest, inject the compat shim --------------------
# We never mutate the user's source; everything happens in a throwaway copy that
# the converter (or --temp-load) then consumes.
echo "==> Staging a Safari-ready copy..."
STAGE_DIR="$(mktemp -d)/staged"
mkdir -p "$STAGE_DIR"
cp -R "$EXT_DIR/." "$STAGE_DIR/"
cp "$LIB/shim.js" "$STAGE_DIR/shim.js"
python3 "$LIB/manifest_fix.py" "$STAGE_DIR/manifest.json" --shim shim.js ${KEEP_MODULE:+--keep-module}

# Inject the shim as the first <script> in every extension HTML page (popup,
# options, side panel). Reference it by a path relative to each page's depth so
# a page in a subfolder still resolves it, and a CSP of 'self' still allows it.
while IFS= read -r -d '' html; do
  rel=""
  d="$(dirname "${html#$STAGE_DIR/}")"
  if [ "$d" != "." ]; then
    IFS='/' read -ra parts <<< "$d"
    for _ in "${parts[@]}"; do rel="../$rel"; done
  fi
  tag="<script src=\"${rel}shim.js\"></script>"
  if grep -qi '<head' "$html"; then
    TAG="$tag" perl -0pi -e 's|(<head\b[^>]*>)|$1."\n".$ENV{TAG}|ie' "$html"
  else
    printf '%s\n' "$tag" | cat - "$html" > "$html.tmp" && mv "$html.tmp" "$html"
  fi
done < <(find "$STAGE_DIR" -name '*.html' -print0)

# --- Temp-load: stage only, no Xcode ------------------------------------------
if [ -n "$TEMP_LOAD" ]; then
  echo ""
  echo "Staged for Safari temporary loading:"
  echo "  $STAGE_DIR"
  echo ""
  echo "In Safari: Settings > Advanced > 'Show features for web developers',"
  echo "then Develop menu > 'Add Temporary Extension...' and pick that folder."
  echo "(Temporary extensions must be re-added after each Safari restart.)"
  exit 0
fi

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
xcrun safari-web-extension-converter "$STAGE_DIR" \
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

if [ -n "$BUILD_ONLY" ]; then
  echo ""
  echo "Done (build only). App at: $APP"
  exit 0
fi

# --- Install + launch ---------------------------------------------------------
echo "==> Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
mv "$APP" /Applications/

/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f -R -trusted "/Applications/$APP_NAME.app"

open -a "/Applications/$APP_NAME.app"
sleep 2
open -a Safari

# The generated project and build tree hold extra copies of the extension.
# Once the app is in /Applications they're dead weight; a re-run regenerates
# everything from scratch anyway. Use --build-only if you want to keep them.
# Only remove the two directories this script created, never OUT_DIR wholesale.
rm -rf "$OUT_DIR/$APP_NAME" "$OUT_DIR/build"
rmdir "$OUT_DIR" 2>/dev/null || true

echo ""
echo "Done. Enable it in Safari > Settings > Extensions."
