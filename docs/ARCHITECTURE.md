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

The app, independent crash helper, and exported recovery tool all use `RecoveryController`. Its [shared native adapter](../GameMode/Core/RecoveryController+System.swift) supplies the same keyboard, mouse, display, and power restoration operations to every entry point. Full-session recovery always finishes before an optional override repair begins; both use the same durable journal. The helper holds the same process lock as the app and avoids interactive authorization or display retries outside that lock.

Function-key setup is one dropdown in **Input Guard**, behind its master switch. **System > Recovery** is the only recovery section. Its detail page and the standalone `GameMode Recovery.app` use the shared `RecoveryContentView`. The settings sidebar selects top-level panes; a `NavigationStack` in the detail column presents Recovery under System and Add Applications under Auto-Activation. `SettingsWindowController` owns the native `NSSplitViewController` and `NSToolbar`. An `NSTrackingSeparatorToolbarItem` binds the toolbar to the actual divider, so AppKit animates the sidebar and toolbar together. SwiftUI hosts the sidebar list and detail content without bridging a competing toolbar. AppKit displays the window title, a separate sidebar toggle, and a persistent Back/Forward group. The detail viewport is clipped and constrained to the system safe area below the toolbar. `AppSettings` keeps bounded, transient navigation history across panes and child pages; history contains only locations. Leaving a child clears its imported file review or unfinished application entry. Forward navigation creates fresh child state and cannot reopen the application picker while editing is blocked. Back and Forward are also available from the View menu with Command-[ and Command-]. There are no separate launch/shutdown recovery switches; legacy preferences are decoded for compatibility but no longer disable recovery.

Expandable settings share `SettingsDisclosureGroupStyle`: the whole header is a button, while revealed controls retain independent hit testing. Hotkeys use a native `NSTableView` with checkbox, action, and shortcut columns. Double-clicking the shortcut cell or pressing Return starts the existing recorder; Escape cancels and Delete clears. `AppSettings` owns recording and persistence, and restoring hotkey defaults preserves all other preferences.

Only actual changes that can outlive the process require a durable record and helper readiness. Event-tap shortcut blocking and display activity overlays are process-owned. Normal deactivation stops these effects even for a session with no recovery file. The first later mouse, gesture, keyboard, or display-mode change creates its checkpoint before applying the setter.

`RecoveryBackup` exports typed originals for all available settings, overlaying pending journal originals while gaming. The bounded, checksummed `.gamemoderecovery` file is tied to its Mac and user. Imports validate values and gesture domains, show a selection preview, and require an explicit restore action. The engine commits the reviewed restore intent before setters; interrupted file restores resume through ordinary crash recovery. Damaged local evidence is archived before a reviewed file replaces it. Newer saved function-key preferences still take precedence.

New display and power snapshots and their selectable recovery rows follow `FEATURE_DISPLAYS`. The app, crash helper, and standalone app share the same channel configuration. Recovery still decodes and restores pending display and power changes from earlier builds when the feature is disabled, so switching channels cannot strand a previous session.

The signed standalone app is embedded in `Contents/Helpers` and copied beside the exported data file without modifying its signature. It shares the native recovery adapter and process lock, and needs no third-party frameworks or main app installation. The older command-line helper remains available for compatibility and process-death tests; users interact with the recovery UI.

If recovery data is invalid or restoration fails, new gaming sessions remain blocked. Users can retry, review a saved file, or explicitly keep their current settings. Successfully restored records are retired; failed records remain pending.

## Channels and updates

The shared [feature configuration](../Config/FeatureFlags.xcconfig) controls which beta features are compiled in. Debug includes all beta features by default; Release uses the selected channel. UI visibility and system change entry points are both guarded. Recovery code stays compiled in so stable builds can restore changes made by a beta.

Sparkle reads the shared [appcast](../appcast.xml). The saved **Receive beta updates** preference controls which update channels are allowed, independently of build flags. The [release guide](RELEASING.md) covers version ordering and publication.

## Tests

Reducers use controlled clients in tests, and settings and recovery tests use isolated storage and injected system operations. Hosted tests pass `--testing` and avoid starting the live app's system integration. Run the commands in [Contributing](../CONTRIBUTING.md#run-tests).
