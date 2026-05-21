## macSTT 0.1.13

This release focuses on the first-run experience, Settings polish, permission handling, and making the app clearly communicate when it is actually ready for dictation.

### Redesigned Settings

- Rebuilt Settings around a compact native macOS grouped layout.
- Added a cleaner Settings header with a microphone symbol and removed redundant app-name chrome inside the window.
- Reworked row alignment so trigger, language, permissions, and model status use a consistent label/value structure.
- Replaced the language radio buttons with a native segmented control.
- Tightened spacing throughout the panel so the window feels closer to a small Apple-style utility preference surface.
- Updated button typography so permission actions match the rest of the Settings text.
- Kept icons minimal: Settings now uses one header icon instead of adding decorative icons to every row.
- Improved row separators, group backgrounds, and fixed sizing so the window no longer shifts awkwardly as values change.
- Fixed trigger-pill sizing so keyboard and mouse trigger values remain stable in the right column.

### Clearer Permission Flow

- Simplified the visible setup requirements to the two permissions users actually need to understand: Microphone and Accessibility.
- Removed the confusing Input Monitoring / Activation row from Settings.
- Kept global trigger setup internal so users are not sent to a System Settings pane where there may be nothing actionable to select.
- Added active permission polling so Settings updates after permissions are granted without requiring the user to close and reopen the window.
- Fixed microphone permission refresh so granting microphone access is recognized correctly.
- Improved missing-permission status text so Settings shows exactly what still needs attention.

### First-Run Restart Handling

- Added a native restart prompt after the app detects that required permissions have been granted.
- The restart makes macOS apply Accessibility/global-trigger changes reliably before the user starts dictating.
- After that restart, Settings opens once to confirm the app is ready.
- That confirmation is one-time only: later launches stay quiet in the menu bar unless attention is needed.
- Added a small persisted one-shot setup flag so this onboarding state survives the restart and is consumed immediately afterward.

### Automatic Start at Login

- macSTT now enables Start at Login automatically after the first successful permission setup and restart.
- The app only attempts this after onboarding is complete, not on every launch.
- Existing Start at Login settings are respected.
- If macOS requires separate user approval for the login item, the menu toggle reflects that state without interrupting the onboarding flow with another System Settings jump.

### More Accurate Readiness

- The menu bar and Settings status now avoid showing Ready while the model is still loading.
- Model loading progress is shown directly in the Model row instead of reserving a large empty area elsewhere in the window.
- Ready is shown only when the local model is loaded and the app has the permissions it needs to start capture.
- Settings now distinguishes loading, missing permissions, errors, and ready state more clearly.
- The Ready state is visually emphasized so users can tell when they can start speaking.

### Trigger Reliability

- Improved trigger monitor synchronization after permission state changes.
- Added retry behavior so the event tap can start once macOS makes event access available.
- Added clearer logging when global trigger monitoring cannot start yet.
- Capture remains blocked with an explicit status when required permissions are missing, instead of silently ignoring the trigger.

### Release and Update Pipeline

- The official Sparkle public key is now stored as a non-secret release fallback in the Fastlane configuration.
- `SPARKLE_PUBLIC_ED_KEY` remains available as an override, but release builds no longer require setting it manually.
- Release automation now supports `RELEASE_NOTES_FILE` so GitHub Releases and the Sparkle appcast can use curated release notes instead of generated notes.
- The appcast release notes page will point back to the GitHub release for full details.

### Quality

- Added behavior-focused tests for the new permission lifecycle, one-shot readiness confirmation, launch-at-login policy, Settings rows, and trigger retry behavior.
- Verified the release build path with Fastlane local build and Developer ID signing before preparing this release.

[View release on GitHub](https://github.com/itsklimov/macSTT/releases/tag/v0.1.13)
