# macSTT

`macSTT` is a macOS-native speech-to-text app for dictation. It listens for a configured trigger, captures microphone audio, runs local speech-to-text, and types the final transcript at the current cursor location.

## Why It Matters

- Native macOS app instead of a browser-based dictation flow
- Local model lifecycle with visible readiness and download state
- Release pipeline that builds, notarizes, signs, and publishes a DMG

## Download

[Download the latest macSTT release](https://github.com/itsklimov/macSTT/releases/latest/download/macSTT.dmg)

Released builds install as a standard `.app` bundle and support Sparkle-based updates.

## Quick Start

1. Download the latest DMG and move `macSTT.app` to `/Applications`.
2. Launch the app and grant microphone permission.
3. Grant Accessibility permission so the app can type into other apps.
4. Choose your trigger in Settings and wait for model status to reach `Ready`.
5. Put the cursor in any app, trigger capture, speak, and let `macSTT` type the transcript.

## Development Requirements

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

Development builds run via `swift run` rather than a bundled `.app`.

`run.sh` will optionally codesign the debug binary if `CODE_SIGN_IDENTITY` is set:

```bash
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./run.sh
```

Features like `Launch at Login` require a bundled `.app`; in dev mode the control is shown but disabled.

## Runtime Notes

- Model status is shown in Settings as `Initializing`, `Checking Models`, `Downloading Models`, `Loading Models`, `Ready`, or `Error`.
- Models are stored under `~/Library/Application Support/macSTT/Models`.
- The app needs microphone permission for capture.
- The app needs Accessibility permission to type transcriptions into other apps.

## Build a Local App Bundle

```bash
# Generate Xcode project + build signed .app
fastlane mac build
```

Output: `build/macSTT.app`

This path requires a local `DEVELOPMENT_TEAM` and a matching Developer ID signing identity. Sparkle is disabled for this local build path by default.

## Release Process

```bash
# Bump patch version, build, notarize, create DMG, publish to GitHub
fastlane mac release
```

This flow bumps the version in `project.yml`, builds a signed `.app`, notarizes it with Apple, creates a DMG, publishes to GitHub Releases, and updates the Sparkle appcast on the `gh-pages` branch.

Official release credentials are only needed for this path:
`DEVELOPMENT_TEAM`, `FASTLANE_USER`, `APPLE_ID`, `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD`

The official Sparkle public key is committed in `fastlane/Fastfile` because it is not secret and is embedded in every release build. Set `SPARKLE_PUBLIC_ED_KEY` only when intentionally overriding it. Set `RELEASE_NOTES_FILE` to publish curated GitHub release notes instead of generated notes.

## License

Apache 2.0. See [LICENSE](LICENSE).
