# Architecture

GameMode is a SwiftUI and AppKit menu bar app. The Composable Architecture manages application state, settings, and session transitions. Dependency clients keep system work separate from the reducers and replaceable in tests.

## Repository layout

| Location | Contents |
|----------|----------|
| `GameMode/App/` | App entry point, menu bar, windows, and Sparkle integration |
| `GameMode/Core/` | Reducers, dependency clients, settings changes, detection, and recovery |
| `GameMode/Models/` | Configuration, monitored apps, shortcuts, gestures, hotkeys, and display models |
| `GameMode/Views/` | SwiftUI settings and menu controls |
| `GameModeTests/` | Reducer, persistence, recovery, input, and presentation tests |
| `Config/FeatureFlags.xcconfig` | Shared build channel and beta feature conditions |
| `scripts/` | Release metadata, packaging, publication, and tooling tests |
| `.github/workflows/` | Pull request checks and the manual release workflow |

## Application flow

1. [AppDelegate](../GameMode/App/AppDelegate.swift) creates the persistent store and menu. The store outlives settings windows, so closing a window doesn't cancel restoration.
2. [GameModeFeature](../GameMode/Core/GameModeFeature.swift) coordinates launch, app events, user actions, and recovery. [AppSettings](../GameMode/Core/AppSettings.swift) owns editable configuration and settings actions.
3. [AppPlatformClient](../GameMode/Core/AppPlatformClient.swift) supplies application launch and termination events, global hotkeys, and shutdown notifications. Enabled apps match exact bundle identifiers or preset prefixes.
4. [GameSession](../GameMode/Core/GameSession.swift) tracks requested and applied modes. It waits for each transition to finish before starting another.
5. [GameEngine](../GameMode/Core/GameEngineClient.swift) serializes system changes through [RecoveryController](../GameMode/Core/RecoveryController.swift). Startup recovery completes before a new session can begin.

The app has no Dock icon (`LSUIElement=true`). The App Sandbox is disabled because the app needs direct access to system preferences and IOKit.

## System changes

| Setting | Implementation |
|---------|----------------|
| Function keys | Temporary IOKit HID mode changes, verified against the live keyboard state |
| System shortcuts | A process-owned event tap blocks selected symbolic hotkeys |
| Gestures | CoreFoundation preferences, with original values saved for restoration |
| Mouse tracking speed | IOKit HIDSystem reads and writes the live tracking speed |
| Display refresh rate | Display mode switching and an optional built-in ProMotion fallback |
| Low Power Mode | `pmset` through an administrator approval prompt |

[SettingsManager](../GameMode/Core/SettingsManager.swift) handles input and mouse changes. [RefreshRateLock](../GameMode/Core/RefreshRateLock.swift) and [PowerManager](../GameMode/Core/PowerManager.swift) handle display and power changes in beta builds. Restoration remains available in every channel.

## Preferences and recovery

[SettingsClient](../GameMode/Core/SettingsClient.swift) stores configuration as JSON in UserDefaults under `GameModeConfig_v2`. The bundle identifier is `com.moshyn.nikita.GameMode`. Unreadable configuration is preserved and blocks edits until resolved or explicitly reset.

[StateJournal](../GameMode/Core/StateJournal.swift) stores recovery data separately in `~/Library/Application Support/GameMode/`. `manifest.json` identifies the current recovery state and references two checksummed copies of a snapshot. Writes complete before the corresponding system setting changes. Recovery also understands older `state.json` records.

Restoration uses captured original values from the journal. Editing preferences during a session doesn't replace those values. A setting is removed from pending recovery only after restoration succeeds; failures leave the remaining records available for retry.

If recovery data is invalid or restoration fails, the app blocks new sessions. The user can retry recovery or explicitly accept their current macOS settings as normal from System settings.

## Channels and updates

The shared [feature configuration](../Config/FeatureFlags.xcconfig) controls which beta features are compiled in. Debug includes all beta features by default; Release uses the selected channel. UI visibility and system change entry points are both guarded. Recovery code stays compiled in so stable builds can restore changes made by a beta.

Sparkle reads the shared [appcast](../appcast.xml). The saved **Receive beta updates** preference controls which update channels are allowed, independently of build flags. The [release guide](RELEASING.md) covers version ordering and publication.

## Tests

Reducers use controlled clients in tests, and settings and recovery tests use isolated storage and injected system operations. Hosted tests pass `--testing` and avoid starting the live app's system integration. Run the commands in [Contributing](../CONTRIBUTING.md#run-tests).
