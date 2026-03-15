# GameMode v2 — Implementation Plan

## What's Changing

v1 was hardcoded: one app (GeForce Now), two keyboard settings (Fn keys + Spotlight),
hardcoded mouse speeds, no UI beyond a menu. v2 makes everything configurable through
a proper Settings window, adds smart app detection, and generalizes keyboard shortcut
management to any macOS symbolic hotkey.

---

## 1. New File Structure

```
GameMode/
├── GameMode.xcodeproj/
├── GameMode/
│   ├── App/
│   │   ├── GameModeApp.swift              ← @main, Window scene for Settings
│   │   └── AppDelegate.swift              ← Menu bar, game mode orchestration
│   ├── Core/
│   │   ├── AppMonitor.swift               ← NSWorkspace watcher (refactored)
│   │   ├── AppDetector.swift              ← NEW: scan disk + categorize apps
│   │   ├── SettingsManager.swift          ← Generalized shortcut toggling
│   │   ├── StateJournal.swift             ← NEW: crash recovery state file
│   │   └── ConfigStore.swift              ← NEW: UserDefaults ↔ Codable
│   ├── Models/
│   │   ├── GameModeConfig.swift           ← NEW: top-level config struct
│   │   ├── MonitoredApp.swift             ← NEW: app entry model
│   │   ├── ShortcutEntry.swift            ← NEW: keyboard shortcut model
│   │   └── SymbolicHotkeys.swift          ← NEW: key ID → name mapping
│   ├── Views/
│   │   ├── SettingsWindow.swift           ← NEW: main settings window (TabView)
│   │   ├── ShortcutsSettingsView.swift    ← NEW: keyboard shortcuts list
│   │   ├── AppsSettingsView.swift         ← NEW: trigger apps management
│   │   ├── MouseSettingsView.swift        ← NEW: sensitivity config
│   │   ├── SystemSettingsView.swift       ← NEW: recovery & safety config
│   │   └── AppPickerSheet.swift           ← NEW: add app from running/file
│   └── Info.plist
└── build.sh
```

---

## 2. Data Model

All config persisted via `UserDefaults` as JSON (through `ConfigStore`).

### GameModeConfig (top-level)

```swift
struct GameModeConfig: Codable {
    var monitoredApps: [MonitoredApp]          // apps that trigger game mode
    var shortcuts: [ShortcutEntry]             // keyboard shortcuts to disable
    var functionKeysInGamingMode: Bool          // toggle Fn key behavior
    var mouse: MouseConfig                     // sensitivity settings
    var system: SystemConfig                   // safety & recovery settings
}
```

### MonitoredApp

```swift
struct MonitoredApp: Codable, Identifiable, Hashable {
    let id: UUID
    var bundleID: String                       // exact or prefix pattern
    var name: String                           // display name
    var isEnabled: Bool                        // whether this app triggers game mode
    var source: AppSource                      // how it got here

    enum AppSource: String, Codable {
        case preset     // built-in (GeForce Now, Steam pattern, Epic, etc.)
        case detected   // found by scanning /Applications + category check
        case manual     // user-added
    }
}
```

### ShortcutEntry

```swift
struct ShortcutEntry: Codable, Identifiable, Hashable {
    let id: Int                                // symbolic hotkey ID (e.g. 64)
    var name: String                           // "Show Spotlight Search"
    var category: String                       // "Spotlight", "Input Sources", etc.
    var disableInGamingMode: Bool              // toggle per shortcut
}
```

### MouseConfig

```swift
struct MouseConfig: Codable {
    var isEnabled: Bool                        // master switch — false hides mouse from menu entirely
    var gamingSpeed: Double                     // user-configurable (default 3.0)
    var normalSpeed: Double                    // user-configurable (default from system)
    var capturedSystemSpeed: Double?           // auto-read before first activation
    var autoCapture: Bool                      // read live speed on each activation
    var isMouseBoostEnabled: Bool              // the on/off toggle (only when isEnabled = true)
}
```

When `isEnabled = false`:
- Mouse toggle is **hidden** from the menu bar entirely
- Mouse speed is never touched during activation/deactivation
- The Mouse settings tab still exists (so the user can re-enable it), but
  sliders are greyed out

### SystemConfig

```swift
struct SystemConfig: Codable {
    var restoreOnLaunch: Bool                  // auto-restore if app starts with stale state (default true)
    var restoreOnShutdown: Bool                // deactivate before macOS shuts down (default true)
}
```

### GameModeState (runtime state journal — separate from config)

Written to `~/Library/Application Support/GameMode/state.json`.
This is NOT user config — it's an operational journal that records what the app
has changed so it can undo everything even after a crash or force-reboot.

```swift
struct GameModeState: Codable {
    var isActive: Bool                         // true while gaming mode is on
    var activatedAt: Date?                     // when it was activated
    var appliedChanges: AppliedChanges         // exactly what was changed

    struct AppliedChanges: Codable {
        var functionKeysChanged: Bool          // did we flip fnState?
        var disabledShortcutIDs: [Int]         // which hotkeys did we disable?
        var mouseSpeedChanged: Bool            // did we change mouse speed?
        var previousMouseSpeed: Double?        // what was it before we touched it?
    }
}
```

The state journal is written **synchronously before any settings change** and
cleared **after all settings are restored**. This guarantees that even if the
process is killed between write and restore, the next launch knows exactly
what to undo.

### ConfigStore

```swift
class ConfigStore: ObservableObject {
    @Published var config: GameModeConfig

    static let shared = ConfigStore()
    private let key = "GameModeConfig"

    init() {
        // Load from UserDefaults, or create defaults
    }

    func save() {
        // Encode to JSON, write to UserDefaults.standard
    }

    /// First-run: populate presets + scan for games
    func populateDefaults(detector: AppDetector) {
        // Add preset apps
        // Run detector.scanForGames()
        // Add default shortcuts (Spotlight, Input Sources)
    }
}
```

---

## 3. App Detection Engine (`AppDetector.swift`)

### Three layers of detection

#### Layer 1: Presets (always present, even if not installed)

```
┌─────────────────────────┬──────────────────────────────────┐
│ Name                    │ Bundle ID                        │
├─────────────────────────┼──────────────────────────────────┤
│ GeForce Now             │ com.nvidia.gfnpc.mall            │
│ Steam (game processes)  │ PREFIX: com.valvesoftware.steam.  │
│ Epic Games Launcher     │ com.epicgames.EpicGamesLauncher  │
│ GOG Galaxy              │ com.gog.galaxy                   │
│ Battle.net              │ net.battle.app                   │
│ Xbox / Game Pass        │ com.microsoft.gamepass            │
│ Crossover               │ com.codeweavers.CrossOver        │
│ Parallels (games)       │ com.parallels.desktop.console    │
│ RetroArch               │ com.libretro.RetroArch           │
│ OpenEmu                 │ org.openemu.OpenEmu              │
└─────────────────────────┴──────────────────────────────────┘
```

Steam games deserve special handling: Steam itself is `com.valvesoftware.Steam`,
but each game it launches gets a bundle ID like `com.valvesoftware.steam.app.730`
(that's CS2). The monitor should use **prefix matching** for Steam entries:
any `com.valvesoftware.steam.app.*` launch triggers game mode, while the
Steam client itself does not.

#### Layer 2: Category scan (automatic)

Scan `/Applications`, `~/Applications`, and known Steam/Epic directories.
For each `.app` bundle, read its `Info.plist` and check `LSApplicationCategoryType`.
Any app whose category starts with `public.app-category.` and contains `game`
is flagged as a detected game.

Game category UTIs:
```
public.app-category.action-games
public.app-category.adventure-games
public.app-category.arcade-games
public.app-category.board-games
public.app-category.card-games
public.app-category.casino-games
public.app-category.dice-games
public.app-category.educational-games
public.app-category.family-games
public.app-category.kids-games
public.app-category.music-games
public.app-category.puzzle-games
public.app-category.racing-games
public.app-category.role-playing-games
public.app-category.simulation-games
public.app-category.sports-games
public.app-category.strategy-games
public.app-category.trivia-games
public.app-category.word-games
public.app-category.games           ← generic
```

#### Layer 3: Apple Game Mode piggyback

macOS Sonoma+ activates Game Mode when a full-screen app has a game
`LSApplicationCategoryType`. There's no public API to query Game Mode state,
but we can replicate the same detection logic:

1. Listen for `NSWorkspace.didActivateApplicationNotification`
2. Check if the frontmost app's bundle has a game category
3. Check if it's in full-screen (`NSApp.presentationOptions` / screen frame check)
4. If both true → activate GameMode (if not already triggered by bundle ID match)

This is additive — it catches games that aren't in the user's app list.
Can be toggled off in Settings under "Auto-detect Apple Game Mode apps".

#### Manual additions

The user can add apps by:
1. **Pick from running apps** — show a sheet listing currently running apps
   (from `NSWorkspace.shared.runningApplications`), user taps one to add.
2. **Browse** — file picker filtered to `.app` bundles, read bundle ID from
   its `Info.plist`.
3. **Type bundle ID** — text field for power users.

### AppMonitor refactoring

Current `AppMonitor` watches for a single hardcoded bundle ID. Refactored version:

```swift
class AppMonitor {
    private let configStore: ConfigStore
    private var activeGameCount = 0   // track how many monitored apps are running

    /// Called by NSWorkspace.didLaunchApplicationNotification
    func appDidLaunch(_ app: NSRunningApplication) {
        guard shouldMonitor(app) else { return }
        activeGameCount += 1
        if activeGameCount == 1 {
            onActivate()   // first game → activate
        }
    }

    /// Called by NSWorkspace.didTerminateApplicationNotification
    func appDidTerminate(_ app: NSRunningApplication) {
        guard shouldMonitor(app) else { return }
        activeGameCount = max(0, activeGameCount - 1)
        if activeGameCount == 0 {
            onDeactivate()   // last game closed → deactivate
        }
    }

    private func shouldMonitor(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }

        return configStore.config.monitoredApps.contains { entry in
            guard entry.isEnabled else { return false }

            // Prefix matching for Steam-style entries
            if entry.bundleID.hasSuffix(".*") {
                let prefix = String(entry.bundleID.dropLast(2))
                return bundleID.hasPrefix(prefix)
            }

            return bundleID == entry.bundleID
        }
    }
}
```

Key change: **`activeGameCount`** — if you launch GeForce Now AND a Steam game,
game mode stays active until BOTH close. No premature deactivation.

---

## 4. Keyboard Shortcuts Management

### Complete symbolic hotkey ID → name map

This ships as a static dictionary in `SymbolicHotkeys.swift`.
The user sees these grouped by category in the Shortcuts settings tab.

```
Spotlight
  64  Show Spotlight Search
  65  Show Finder Search Window

Input Sources
  60  Select Previous Input Source
  61  Select Next Input Source

Mission Control
  32  Mission Control (All Windows)
  33  Application Windows
  34  Mission Control (All Windows, secondary)
  35  Application Windows (secondary)
  36  Show Desktop
  37  Show Desktop (secondary)
  62  Show Dashboard
  63  Show Dashboard (secondary)
  79  Move Left a Space
  80  Move Left a Space (secondary)
  81  Move Right a Space
  82  Move Right a Space (secondary)

Accessibility
  59  Turn VoiceOver On/Off
  162 Show Accessibility Controls

Display
  53  Decrease Display Brightness
  54  Increase Display Brightness
  55  Decrease Display Brightness (dedicated key)
  56  Increase Display Brightness (dedicated key)

Dock
  52  Turn Dock Hiding On/Off

Launchpad
  160 Show Launchpad

Other
  70  Look Up in Dictionary
  73  Front Row
  175 Siri
  190 Toggle Focus
```

### How toggling works

Same approach as v1 Spotlight — only flip `enabled` flag via PlistBuddy `Set`,
never touch the `value` dict. Generalized:

```swift
/// Disable a list of shortcuts by their symbolic hotkey IDs.
func writeShortcuts(ids: [Int], enabled: Bool) {
    let plistPath = "~/Library/Preferences/com.apple.symbolichotkeys.plist"

    for id in ids {
        let result = shell(
            plistBuddyBin,
            "-c", "Set :AppleSymbolicHotKeys:\(id):enabled \(enabled)",
            plistPath
        )
        if result.exitCode != 0 {
            // Key doesn't exist — skip (don't create, we don't know the binding)
            print("[SettingsManager] Shortcut \(id) not found in plist, skipping")
        }
    }
}
```

Important: if a key doesn't exist in the user's plist, we **skip it** rather than
creating it with hardcoded values. This preserves the "don't touch what isn't ours"
principle from the v1 Spotlight fix.

The `applyKeyboardChanges()` method remains unchanged — one `cfprefsd` restart +
one `activateSettings -u` after all writes.

### Function keys toggle

Stays as-is (`defaults write NSGlobalDomain com.apple.keyboard.fnState`),
but now controlled by `config.functionKeysInGamingMode` toggle in Settings.

---

## 5. Menu Bar (Simplified)

### When game mode is ON:
```
┌─────────────────────────────────────────┐
│  Gaming Mode Active                     │   ← status (disabled text)
│─────────────────────────────────────────│
│  Disable Game Mode                  ⌘G  │   ← single toggle, shows action
│  Disable Mouse Boost                ⌘M  │   ← HIDDEN if mouse.isEnabled = false
│─────────────────────────────────────────│
│  Settings...                        ⌘,  │
│─────────────────────────────────────────│
│  Quit GameMode                      ⌘Q  │
└─────────────────────────────────────────┘
```

### When game mode is OFF:
```
┌─────────────────────────────────────────┐
│  Normal Mode                            │
│─────────────────────────────────────────│
│  Enable Game Mode                   ⌘G  │
│  Enable Mouse Boost                 ⌘M  │   ← HIDDEN if mouse.isEnabled = false
│─────────────────────────────────────────│
│  Settings...                        ⌘,  │
│─────────────────────────────────────────│
│  Quit GameMode                      ⌘Q  │
└─────────────────────────────────────────┘
```

The mouse toggle is only shown when `config.mouse.isEnabled` is true.
Users who don't need mouse management see a cleaner menu.

### Menu bar icon

- **Game mode off** → `gamecontroller` (outline SF Symbol)
- **Game mode on**  → `gamecontroller.fill` (filled SF Symbol)

```swift
private func updateMenuBarIcon() {
    let symbolName = isGamingMode ? "gamecontroller.fill" : "gamecontroller"
    statusItem.button?.image = NSImage(
        systemSymbolName: symbolName,
        accessibilityDescription: "GameMode"
    )
}
```

---

## 6. Settings Window

Compact SwiftUI window, ~500×420, opened from the menu bar "Settings..." item.
Uses `TabView` with icons.

### GameModeApp.swift changes

```swift
@main
struct GameModeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var configStore = ConfigStore.shared

    var body: some Scene {
        Settings {
            EmptyView()  // still need this to suppress default window
        }

        // Settings window opened programmatically via NSWindow
        // (or use WindowGroup with handlesExternalEvents for a single-window approach)
    }
}
```

The Settings window is opened via `NSWindow` / `NSHostingController` from
`AppDelegate` when "Settings..." is clicked, giving full control over size
and single-instance behavior.

### Tab 1: Shortcuts

```
┌──────────────────────────────────────────────────┐
│  Keyboard Shortcuts                              │
│──────────────────────────────────────────────────│
│                                                  │
│  ☑ Use F1, F2, etc. as standard function keys   │
│                                                  │
│  ─── Spotlight ──────────────────────────────    │
│  ☑ Show Spotlight Search                         │
│  ☐ Show Finder Search Window                     │
│                                                  │
│  ─── Input Sources ──────────────────────────    │
│  ☑ Select Previous Input Source                  │
│  ☐ Select Next Input Source                      │
│                                                  │
│  ─── Mission Control ────────────────────────    │
│  ☐ Mission Control                               │
│  ☐ Application Windows                           │
│  ☐ Show Desktop                                  │
│  ☐ Move Left a Space                             │
│  ☐ Move Right a Space                            │
│  ...                                             │
│                                                  │
│  Checked shortcuts will be disabled in game mode │
└──────────────────────────────────────────────────┘
```

Each toggle means "disable this shortcut when gaming mode is active."
The list is populated by reading the user's actual
`com.apple.symbolichotkeys.plist` and cross-referencing against
the known ID map — only shortcuts that exist in THEIR plist are shown.
This ensures we never show shortcuts that don't apply to their macOS version.

### Tab 2: Applications

```
┌──────────────────────────────────────────────────┐
│  Trigger Applications                            │
│──────────────────────────────────────────────────│
│                                                  │
│  ☑ Auto-detect games (Apple Game Mode logic)     │
│                                                  │
│  ─── Presets ────────────────────────────────    │
│  [icon] GeForce Now         com.nvidia.gfn...  ☑│
│  [icon] Steam Games         com.valvesoftw...*  ☑│
│  [icon] Epic Games          com.epicgames....   ☐│
│  [icon] Battle.net          net.battle.app      ☐│
│                                                  │
│  ─── Detected Games ────────────────────────    │
│  [icon] Baldur's Gate 3     com.larian.bg3      ☑│
│  [icon] Stardew Valley      com.stardew...      ☐│
│                                                  │
│  ─── Custom ────────────────────────────────    │
│  [icon] My Custom Game      com.custom.game     ☑│
│                                                  │
│  [+ Add App]  [↻ Re-scan]                       │
│                                                  │
└──────────────────────────────────────────────────┘
```

**"+ Add App"** opens `AppPickerSheet`:

```
┌──────────────────────────────────────────────────┐
│  Add Application                                 │
│──────────────────────────────────────────────────│
│                                                  │
│  ─── Running Apps ───────────────────────────    │
│  [icon] Safari                            [Add]  │
│  [icon] Discord                           [Add]  │
│  [icon] Factorio                          [Add]  │
│  [icon] Steam                             [Add]  │
│  ...                                             │
│                                                  │
│  ─── Or ─────────────────────────────────────    │
│  [Browse .app...]                                │
│  Bundle ID: [________________________] [Add]     │
│                                                  │
│                                    [Cancel]      │
└──────────────────────────────────────────────────┘
```

Running apps list filtered to exclude system processes, sorted by name.
Each shows the app icon (from `NSRunningApplication.icon`).

### Tab 3: Mouse

```
┌──────────────────────────────────────────────────┐
│  Mouse Sensitivity                               │
│──────────────────────────────────────────────────│
│                                                  │
│  ☑ Enable mouse sensitivity management           │
│    When disabled, GameMode will never touch       │
│    your mouse settings. The menu bar toggle       │
│    is also hidden.                                │
│                                                  │
│  ─── Speed Settings ─────────────────────────    │  ← greyed out if disabled
│                                                  │
│  Gaming Speed                                    │
│  ├─────────────────────●──────┤  3.0             │
│  0.0                                        5.0  │
│                                                  │
│  Normal Speed                                    │
│  ├──●─────────────────────────┤  0.5             │
│  0.0                                        5.0  │
│                                                  │
│  ☑ Auto-capture current speed before gaming      │
│    When enabled, reads your live mouse speed     │
│    each time gaming mode activates and restores  │
│    that exact value when it deactivates.         │
│                                                  │
│  Current system speed: 0.5                       │
│  [↻ Read Current Speed]                          │
│                                                  │
└──────────────────────────────────────────────────┘
```

### Tab 4: System

```
┌──────────────────────────────────────────────────┐
│  System & Recovery                               │
│──────────────────────────────────────────────────│
│                                                  │
│  ─── Shutdown Protection ────────────────────    │
│                                                  │
│  ☑ Restore settings on shutdown / restart        │
│    Deactivates gaming mode before macOS shuts    │
│    down, so your system starts clean.            │
│                                                  │
│  ─── Crash Recovery ─────────────────────────    │
│                                                  │
│  ☑ Auto-restore on launch                        │
│    If the app was killed or the Mac was force-   │
│    rebooted while gaming mode was active,        │
│    restore all settings on next launch.          │
│                                                  │
│  ─── State ──────────────────────────────────    │
│                                                  │
│  Gaming mode: Inactive                           │
│  State file: ~/Library/Application Support/      │
│              GameMode/state.json                 │
│                                                  │
│  [Force Restore All Settings]                    │
│    Emergency button: reads the state journal     │
│    and restores every setting to pre-gaming      │
│    values. Use if something feels stuck.         │
│                                                  │
└──────────────────────────────────────────────────┘
```

**Auto-capture** works like this:
1. Game mode activates
2. Before changing anything, read `defaults read -g com.apple.mouse.scaling`
3. Store that as `capturedSystemSpeed`
4. Apply `gamingSpeed`
5. When game mode deactivates, restore `capturedSystemSpeed` (not the configured
   `normalSpeed`) — this means if the user changed their mouse speed in System
   Settings between sessions, we respect that.

If auto-capture is off, it uses the configured `normalSpeed` value.

---

## 7. SettingsManager Changes

### Generalized shortcut toggling

Replace `writeSpotlightShortcut(enabled:)` with a generic method:

```swift
/// Toggle a list of symbolic hotkey IDs.
/// Only flips the `enabled` flag — never touches the key binding.
func writeShortcuts(ids: [Int], enabled: Bool) {
    let plistPath = "\(NSHomeDirectory())/Library/Preferences/com.apple.symbolichotkeys.plist"

    for id in ids {
        let result = shell(
            plistBuddyBin,
            "-c", "Set :AppleSymbolicHotKeys:\(id):enabled \(enabled ? "true" : "false")",
            plistPath
        )
        if result.exitCode != 0 {
            print("[SettingsManager] Shortcut \(id) not in plist — skipping")
        }
    }
}
```

### Mouse with auto-capture

```swift
/// Read current mouse speed from system preferences.
func readCurrentMouseSpeed() -> Double? {
    let result = shell(defaultsBin, "read", "-g", "com.apple.mouse.scaling")
    return Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
}
```

### Full activation flow (with state journal)

```swift
func activateGamingMode() {
    let config = configStore.config

    // 0. Auto-capture mouse speed BEFORE we touch anything
    var capturedMouseSpeed: Double? = nil
    if config.mouse.isEnabled && config.mouse.isMouseBoostEnabled && config.mouse.autoCapture {
        capturedMouseSpeed = settingsManager.readCurrentMouseSpeed()
    }

    // 1. Compute what we're about to change
    let shortcutIDs = config.shortcuts
        .filter { $0.disableInGamingMode }
        .map { $0.id }
    let willChangeFunction = config.functionKeysInGamingMode
    let willChangeMouse = config.mouse.isEnabled && config.mouse.isMouseBoostEnabled

    // 2. WRITE STATE JOURNAL FIRST (before any settings change)
    let state = GameModeState(
        isActive: true,
        activatedAt: Date(),
        appliedChanges: AppliedChanges(
            functionKeysChanged: willChangeFunction,
            disabledShortcutIDs: shortcutIDs,
            mouseSpeedChanged: willChangeMouse,
            previousMouseSpeed: capturedMouseSpeed ?? config.mouse.normalSpeed
        )
    )
    StateJournal.write(state)   // synchronous, atomic

    // 3. Now apply changes (safe — journal is on disk)
    if willChangeFunction {
        settingsManager.writeFunctionKeys(enabled: true)
    }
    settingsManager.writeShortcuts(ids: shortcutIDs, enabled: false)
    settingsManager.applyKeyboardChanges()

    if willChangeMouse {
        settingsManager.applyMouseSpeed(config.mouse.gamingSpeed)
    }
}

func deactivateGamingMode() {
    let config = configStore.config
    let state = StateJournal.load()

    // 1. Restore keyboard from what we actually changed (journal is truth)
    if state.appliedChanges.functionKeysChanged {
        settingsManager.writeFunctionKeys(enabled: false)
    }
    if !state.appliedChanges.disabledShortcutIDs.isEmpty {
        settingsManager.writeShortcuts(
            ids: state.appliedChanges.disabledShortcutIDs, enabled: true
        )
    }
    settingsManager.applyKeyboardChanges()

    // 2. Restore mouse
    if state.appliedChanges.mouseSpeedChanged {
        let restoreSpeed: Double
        if config.mouse.autoCapture, let captured = state.appliedChanges.previousMouseSpeed {
            restoreSpeed = captured   // restore exactly what was captured
        } else {
            restoreSpeed = config.mouse.normalSpeed
        }
        settingsManager.applyMouseSpeed(restoreSpeed)
    }

    // 3. Clear journal — everything is restored
    StateJournal.clear()
}
```

Key principle: **deactivation reads the journal, not the config**, to know
what to restore. This handles the case where the user changes their config
while gaming mode is active — we still restore the right things.

---

## 8. System Safety & State Recovery

This is the most critical piece of v2. Without it, a force-reboot or crash
leaves the system stuck in gaming mode with no app running to restore it.

### The problem

Gaming mode changes system-wide settings. These persist across reboots:
- `com.apple.keyboard.fnState` (function keys)
- `com.apple.symbolichotkeys` (Spotlight, input sources, etc.)
- `com.apple.mouse.scaling` (mouse speed)

If the app is killed (force quit, power button hold, kernel panic, macOS update
reboot, or simply launching before a monitored game on reboot), the user's
system is stuck in gaming state.

### Solution: state journal + three recovery layers

#### Layer 1: State journal (covers all cases)

File: `~/Library/Application Support/GameMode/state.json`

```swift
struct GameModeState: Codable {
    var isActive: Bool
    var activatedAt: Date?
    var appliedChanges: AppliedChanges
}

struct AppliedChanges: Codable {
    var functionKeysChanged: Bool
    var disabledShortcutIDs: [Int]
    var mouseSpeedChanged: Bool
    var previousMouseSpeed: Double?
}
```

**Write protocol** — the journal is updated at two critical moments:

1. **Before activation** — write `isActive = true` + full list of what we're
   about to change + captured mouse speed. This write MUST complete before
   any settings are modified. Use synchronous file I/O (`Data.write(to:options:.atomic)`).

2. **After deactivation** — write `isActive = false` + clear `appliedChanges`.
   This write happens after all settings are restored.

The window between write-1 and write-2 is the "dirty" window. If the process
dies during this window, the journal says "I was active and here's what I
changed" — enough information for recovery.

#### Layer 2: Graceful shutdown detection

Register for system power events on launch:

```swift
// In AppDelegate.applicationDidFinishLaunching:

// 1. macOS shutdown / restart / logout
NSWorkspace.shared.notificationCenter.addObserver(
    self,
    selector: #selector(systemWillPowerOff),
    name: NSWorkspace.willPowerOffNotification,
    object: nil
)

// 2. App termination (Cmd+Q, Activity Monitor kill, etc.)
NotificationCenter.default.addObserver(
    self,
    selector: #selector(appWillTerminate),
    name: NSApplication.willTerminateNotification,
    object: nil
)

// 3. Prevent macOS from killing us during shutdown before we finish cleanup
ProcessInfo.processInfo.disableSuddenTermination()
```

When either notification fires:
```swift
@objc func systemWillPowerOff(_ notification: Notification) {
    if isGamingMode {
        deactivateGamingMode()  // restore everything synchronously
    }
}
```

`disableSuddenTermination()` tells macOS: "don't SIGKILL me during logout —
I have cleanup to do." macOS will send `willTerminate` and wait for us to
finish before proceeding with shutdown. This covers restart, shutdown, and
logout — but NOT holding the power button (that's a hardware-level kill).

#### Layer 3: Crash recovery on launch

In `applicationDidFinishLaunching`, before anything else:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // FIRST: check for stale gaming state from a previous crash/force-reboot
    if config.system.restoreOnLaunch {
        recoverIfNeeded()
    }

    // ... then proceed with normal setup
}

private func recoverIfNeeded() {
    let state = StateJournal.load()

    guard state.isActive else { return }  // clean exit last time, nothing to do

    // We were in gaming mode when the process died. Restore everything.
    let changes = state.appliedChanges

    if changes.functionKeysChanged {
        settingsManager.writeFunctionKeys(enabled: false)
    }

    if !changes.disabledShortcutIDs.isEmpty {
        settingsManager.writeShortcuts(ids: changes.disabledShortcutIDs, enabled: true)
    }

    // Apply keyboard changes in one shot
    if changes.functionKeysChanged || !changes.disabledShortcutIDs.isEmpty {
        settingsManager.applyKeyboardChanges()
    }

    if changes.mouseSpeedChanged, let previousSpeed = changes.previousMouseSpeed {
        settingsManager.applyMouseSpeed(previousSpeed)
    }

    // Clear the journal
    StateJournal.clear()

    // Notify the user
    showNotification(
        title: "GameMode — Settings Recovered",
        body: "System settings restored after unexpected shutdown"
    )
}
```

### Edge case: app launches before games on reboot

This is the "normal reboot" case. The user restarts their Mac, and GameMode
launches at login (it's a login item) but no games are running yet.

- Layer 2 (graceful shutdown) already handled this: the `willPowerOff`
  notification fired before shutdown, gaming mode was deactivated, and the
  state journal was cleared.
- If Layer 2 succeeded → `state.isActive == false` → no recovery needed.
- If Layer 2 failed (user held power button) → Layer 3 kicks in and restores.

### Edge case: hard power button (5-second hold)

This is the worst case. macOS has no chance to send notifications.

- The state journal on disk says `isActive = true` with the full change list.
- On next boot, GameMode launches as a login item.
- `recoverIfNeeded()` reads the journal and restores everything.
- The user sees a notification: "Settings Recovered."

### Edge case: macOS update reboot

macOS updates sometimes reboot without giving apps the full `willTerminate`
cycle. Same as hard power button — Layer 3 handles it.

### Force Restore button (Settings > System tab)

For the paranoid or when something feels stuck:

```swift
@objc func forceRestoreAllSettings() {
    // Restore ALL managed settings to their non-gaming defaults,
    // regardless of what the state journal says.
    settingsManager.writeFunctionKeys(enabled: false)

    let allShortcutIDs = configStore.config.shortcuts.map { $0.id }
    settingsManager.writeShortcuts(ids: allShortcutIDs, enabled: true)
    settingsManager.applyKeyboardChanges()

    if let captured = configStore.config.mouse.capturedSystemSpeed {
        settingsManager.applyMouseSpeed(captured)
    } else {
        settingsManager.applyMouseSpeed(configStore.config.mouse.normalSpeed)
    }

    // Clear state
    isGamingMode = false
    StateJournal.clear()
    updateMenu()

    showNotification(
        title: "GameMode — Force Restored",
        body: "All settings reverted to pre-gaming values"
    )
}
```

### StateJournal implementation

```swift
class StateJournal {
    private static let directory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("GameMode")
    }()

    private static let fileURL: URL = {
        directory.appendingPathComponent("state.json")
    }()

    /// Write state atomically (must complete before settings change).
    static func write(_ state: GameModeState) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let data = try? JSONEncoder().encode(state)
        try? data?.write(to: fileURL, options: .atomic)
    }

    /// Load state (returns inactive state if file missing/corrupt).
    static func load() -> GameModeState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(GameModeState.self, from: data)
        else {
            return GameModeState(isActive: false, activatedAt: nil,
                                 appliedChanges: .empty)
        }
        return state
    }

    /// Clear journal after successful restore.
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
```

---

## 9. Notification Wording

All notifications use clean, professional text. No emoji. Short and factual.

```
ACTIVATION
  title: "Game Mode — Active"
  body:  "Keyboard shortcuts and function keys adjusted"
  (if mouse also changed:)
  body:  "Keyboard, shortcuts, and mouse sensitivity adjusted"

DEACTIVATION
  title: "Game Mode — Deactivated"
  body:  "All settings restored"

MOUSE TOGGLE (while gaming mode is ON)
  title: "Mouse Sensitivity — Gaming"
  body:  "Tracking speed set to maximum"

  title: "Mouse Sensitivity — Normal"
  body:  "Tracking speed restored"

MOUSE TOGGLE (while gaming mode is OFF)
  title: "Mouse Sensitivity — Saved"
  body:  "Will apply when game mode activates"

CRASH RECOVERY
  title: "GameMode — Settings Recovered"
  body:  "System settings restored after unexpected shutdown"

FORCE RESTORE
  title: "GameMode — Force Restored"
  body:  "All settings reverted to pre-gaming values"
```

---

## 11. Migration from v1

On first launch of v2, if no `GameModeConfig` exists in UserDefaults:

1. Create default config with:
   - GeForce Now preset (enabled)
   - Steam Games prefix preset (enabled)
   - Spotlight (key 64) shortcut toggle (enabled — to match v1 behavior)
   - Input Sources (key 60) shortcut toggle (enabled — commonly conflicts)
   - Function keys toggle ON
   - Mouse: gamingSpeed = 3.0, normalSpeed = 0.5, autoCapture = true
2. Run `AppDetector.scanForGames()` to find installed games
3. Present Settings window so user can review

---

## 12. Implementation Order

### Phase 1: Data layer + persistence
1. `GameModeConfig.swift`, `MonitoredApp.swift`, `ShortcutEntry.swift`, `SystemConfig`
2. `SymbolicHotkeys.swift` (static ID → name map)
3. `ConfigStore.swift` (UserDefaults + JSON)
4. `StateJournal.swift` (file-based state for crash recovery)

### Phase 2: Core engine updates
5. `AppDetector.swift` (scan + categorize)
6. Refactor `AppMonitor.swift` (multi-app, prefix matching, active count)
7. Refactor `SettingsManager.swift` (generic shortcut toggle, auto-capture mouse, mouse.isEnabled gate)

### Phase 3: System safety
8. Shutdown detection (`willPowerOffNotification`, `willTerminateNotification`)
9. Crash recovery (`recoverIfNeeded()` on launch)
10. State journal write/read during activation/deactivation
11. `disableSuddenTermination()` integration

### Phase 4: UI
12. `SettingsWindow.swift` (TabView shell)
13. `ShortcutsSettingsView.swift`
14. `AppsSettingsView.swift` + `AppPickerSheet.swift`
15. `MouseSettingsView.swift` (with master enable/disable toggle)
16. `SystemSettingsView.swift` (recovery toggles + force restore button)

### Phase 5: Menu bar + integration
17. Refactor `AppDelegate.swift` (new menu layout, icon toggle, open Settings, mouse visibility gate)
18. Refactor `GameModeApp.swift` (window management)
19. Wire everything together

### Phase 6: Polish
20. Professional notification wording (no emoji, clean text)
21. First-launch migration + defaults
22. Re-scan button
23. Edge cases (multiple games, rapid launch/quit, config change while active)
24. Test: force-reboot recovery, clean install, shutdown detection
