# Privacy Policy

**chrome-to-safari** runs entirely on your Mac. It has no server, no account system, and no telemetry.

## What we collect

Nothing. This project has no backend, no analytics, no crash reporting, and no tracking of any kind. Nothing about you or your usage is transmitted to the author or to any third party by this tool.

## Network requests the tool makes

The only outbound network request the tool itself makes is optional:

- **Chrome Web Store link input.** If you paste a Chrome Web Store URL, the script fetches the `.crx` package directly from Google's public update endpoint (the same one Chrome uses). This request goes from your Mac to Google. The author never sees it and never logs it.

Xcode and `xcodebuild`, which the tool invokes on your machine, may make their own network requests to Apple (e.g., for provisioning). Those are governed by Apple's privacy policy, not this one.

## Data on your Mac

The tool reads the extension folder you point it at, writes a generated Xcode project and build output to disk, and installs the resulting app to `/Applications`. All of that stays on your machine.

## Contact

Questions or concerns: <https://github.com/Vatsal057/chrome-to-safari/issues>

_Last updated: 2026-07-16_
