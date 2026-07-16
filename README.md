# chrome-to-safari

Turn any Chrome extension (or any WebExtension) into a working, signed Safari extension with one command — **no paid Apple Developer ID required**.

```bash
./chrome-to-safari.sh /path/to/your-extension
```

It also works straight from a Chrome Web Store link — the script downloads and unpacks the extension for you:

```bash
./chrome-to-safari.sh "https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh"
```

Prefer clicking to typing? There's a native Mac app too:

```bash
./chrome-to-safari.sh --ui
```

Paste a store link or drop your unpacked extension folder onto the window, hit Convert, and watch the steps tick by. An Options section covers the same overrides as the CLI (app name, bundle ID, team ID, output folder, build-only). The app compiles itself from [ui.swift](ui.swift) on first run using the Xcode tools you already have — nothing is downloaded, so there are no Gatekeeper warnings.

That single command converts the extension, builds the wrapper app, signs it with your free Apple Development certificate, installs it to `/Applications`, and opens Safari. Enable the extension once in **Safari → Settings → Extensions** and it stays enabled — even across Safari restarts.

## Why this exists

Safari can run WebExtensions, but Apple makes it painful:

- Safari requires extensions to be wrapped in a native macOS app built with Xcode.
- Unsigned extensions get **disabled every time Safari restarts**, forcing you to re-enable "Allow unsigned extensions" in the Develop menu over and over.
- Apple's converter (`safari-web-extension-converter`) generates an Xcode project but leaves signing, building, and installing to you.

This script automates the whole pipeline, and uses the free Apple developer tier for signing so the "unsigned extension" problem disappears.

## Requirements

- macOS with **Xcode** installed (the full app, not just Command Line Tools — the converter and build need it)
- A free Apple Development certificate (one-time setup, see below)

## One-time setup: free signing certificate

1. Open **Xcode → Settings → Accounts**
2. Click **+** and sign in with your Apple ID — no paid membership needed
3. Select your account → **Manage Certificates…** → **+** → **Apple Development**

The script auto-detects this certificate on every run. If it's missing, the script stops and prints these same instructions.

## Usage

```bash
# Convert, build, sign, install to /Applications, launch Safari
./chrome-to-safari.sh /path/to/extension

# Same, but starting from a Chrome Web Store link
./chrome-to-safari.sh "https://chromewebstore.google.com/detail/<name>/<id>"

# Just convert and build — don't install
./chrome-to-safari.sh /path/to/extension --build-only

# Open the native app instead of using the command line
./chrome-to-safari.sh --ui
```

### Options (environment variables)

| Variable    | Default                              | Purpose                          |
|-------------|--------------------------------------|----------------------------------|
| `APP_NAME`  | `"name"` field from `manifest.json`  | Display name of the wrapper app  |
| `BUNDLE_ID` | `com.converted.<slug>`               | Bundle identifier                |
| `TEAM_ID`   | auto-detected from your keychain     | Apple team ID (if you have several certificates) |
| `OUT_DIR`   | `<extension-parent>/<slug>-safari`   | Where the Xcode project and build output go |

Example:

```bash
APP_NAME="My Cool Extension" BUNDLE_ID=com.me.coolext ./chrome-to-safari.sh ./my-extension
```

## What it does, step by step

1. **Downloads the extension first, if you gave it a store link.** It pulls the `.crx` from Google's own update endpoint (the same one Chrome uses), unpacks it, and strips the store's `_metadata` folder. Note: fetching a `.crx` outside Chrome is technically against the Web Store terms — fine for converting an extension for your own use, but know that's what's happening.
2. **Reads `manifest.json`** to name the app (handles `__MSG_*__` i18n placeholders by falling back to the folder name).
3. **Converts** with Apple's `xcrun safari-web-extension-converter`, copying your extension's resources into a fresh Xcode project.
4. **Fixes a converter quirk**: the generated app and extension targets can end up with mismatched bundle identifiers, which breaks the build with *"Embedded binary's bundle identifier is not prefixed with the parent app's bundle identifier"*. The script normalizes the extension ID to `<app ID>.Extension`.
5. **Builds** with `xcodebuild`, injecting your team ID so both targets are signed with your free Apple Development certificate.
6. **Verifies** the code signature.
7. **Installs** the app to `/Applications`, registers it with Launch Services, and launches it plus Safari.
8. **Cleans up after itself**: once the app is in `/Applications`, the generated Xcode project and build tree are deleted so you don't end up with duplicate copies of the extension. Pass `--build-only` if you want to keep them.

Re-running the script is safe: it re-converts and rebuilds from scratch each time, so just run it again after changing your extension's source.

## Limitations

- **Signing is per-machine.** A development-signed app only counts as signed on the Mac that built it. You can't distribute the built app to other people — they should clone your extension's source and run this script themselves. Public distribution requires a paid Apple Developer account and notarization; nothing scriptable gets around that.
- **Not every Chrome API exists in Safari.** The converter warns about unsupported `manifest.json` keys during conversion — read its output. Check [Safari's WebExtension API support](https://developer.apple.com/documentation/safariservices/safari_web_extensions) for details.
- **Free certificates expire after about a year.** Re-run the script to re-sign when that happens.

## Troubleshooting

- **"No Apple Development certificate found"** — do the one-time setup above.
- **Extension doesn't appear in Safari** — quit and reopen Safari, then check Safari → Settings → Extensions. Make sure the wrapper app ran at least once.
- **Multiple certificates / wrong team** — pass `TEAM_ID=XXXXXXXXXX` explicitly. Find yours with `security find-identity -v -p codesigning`.

## License

MIT — see [LICENSE](LICENSE).
