# macSTT

macOS-native speech-to-text app for dictation on macOS.

The app listens for a configured trigger, captures microphone audio, runs local speech-to-text, and types the final transcript at the current cursor location.

## Requirements

- macOS 15+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [Fastlane](https://fastlane.tools): `brew install fastlane`

## Development

```bash
# Build and run (kills any running instance first)
./run.sh

# Build only
swift build

# Run tests
swift test
```

Development builds run via `swift run` (bare binary, not `.app` bundle).

`run.sh` will optionally codesign the debug binary if `CODE_SIGN_IDENTITY` is set:

```bash
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./run.sh
```

Features like `Launch at Login` require a bundled `.app`; in dev mode the control is shown but disabled.

## Runtime Notes

- Model status is shown in the settings window as `Initializing`, `Checking Models`, `Downloading Models`, `Loading Models`, `Ready`, or `Error`.
- Models are stored under `~/Library/Application Support/macSTT/Models`.
- The app needs microphone permission for capture.
- The app needs Accessibility permission to type transcriptions into other apps.

## Build .app

```bash
# Generate Xcode project + build signed .app
fastlane mac build
```

Output: `build/macSTT.app`. Open it directly or drag to `/Applications/`.

This path requires a local `DEVELOPMENT_TEAM` and a matching Developer ID signing identity.
Sparkle is disabled for this local build path by default.

## Release

```bash
# Bump patch version, build, notarize, create DMG, publish to GitHub
fastlane mac release
```

This bumps the version in `project.yml`, builds a signed `.app`, notarizes it with Apple, creates a DMG, publishes to the `itsklimov/macSTT` GitHub releases, and updates the Sparkle appcast on the repository's `gh-pages` branch.

Official release credentials are only needed for this path:
`DEVELOPMENT_TEAM`, `FASTLANE_USER`, `APPLE_ID`, `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD`, `SPARKLE_PUBLIC_ED_KEY`.
