# GameMode — macOS Menu Bar App for GeForce Now

A native Swift menu bar app that automatically toggles keyboard/mouse settings when GeForce Now launches and quits.

---

## What It Does

| Setting | Gaming Mode (GFN Running) | Normal Mode (GFN Quit) |
|---------|--------------------------|----------------------|
| Function Keys | F1–F12 act as standard function keys | F1–F12 control brightness, volume, etc. |
| Spotlight Shortcut | ⌘Space **disabled** | ⌘Space **enabled** |
| Mouse Sensitivity | Maxed out (manual toggle) | Your normal value (manual toggle) |

**Keyboard settings** change automatically when GeForce Now opens/closes.
**Mouse sensitivity** is toggled manually via the menu bar (since you only use the gaming mouse for CS2, not every GFN session).

---

## Architecture

```
┌─────────────────────────────────────────────┐
│              GameMode.app                    │
│  ┌────────────────────────────────────────┐  │
│  │         MenuBarManager (SwiftUI)       │  │
│  │  • Status item with SF Symbol icon     │  │
│  │  • Shows current mode (Gaming/Normal)  │  │
│  │  • Manual mouse toggle button          │  │
│  │  • "Quit" button                       │  │
│  └─────────────────┬──────────────────────┘  │
│                    │                          │
│  ┌─────────────────▼──────────────────────┐  │
│  │         AppMonitor                     │  │
│  │  • NSWorkspace notifications           │  │
│  │  • didLaunchApplication                │  │
│  │  • didTerminateApplication             │  │
│  │  • Checks for GeForce Now bundle ID    │  │
│  └─────────────────┬──────────────────────┘  │
│                    │                          │
│  ┌─────────────────▼──────────────────────┐  │
│  │         SettingsManager                │  │
│  │  • Executes shell commands via Process │  │
│  │  • defaults write / PlistBuddy        │  │
│  │  • activateSettings -u                 │  │
│  └────────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

### Key Design Decisions

- **Menu bar only** — no Dock icon, no main window. Uses `LSUIElement = true` in Info.plist.
- **Login item** — registers via `SMAppService` so it auto-starts on boot.
- **No admin privileges needed** — all `defaults write` commands operate on the current user's preferences.
- **Shell-based settings manipulation** — uses `Process` to run `defaults`, `PlistBuddy`, and `activateSettings`. This is the most reliable approach since Apple provides no public Swift API for these settings.

---

## Prerequisites

Before building, run these commands in Terminal to capture your current "normal" values:

```bash
# Check your current function key state
defaults read NSGlobalDomain com.apple.keyboard.fnState
# Returns: 0 (special keys) or 1 (function keys)

# Check your current mouse scaling
defaults read -g com.apple.mouse.scaling
# Returns something like: 1.5 or 2.0

# Check your Spotlight shortcut state
defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys | grep -A 10 '"64"'
```

Note the mouse scaling value — you'll use it as `normalMouseSpeed` in the app.

Also find the GeForce Now bundle identifier:

```bash
# With GeForce Now installed, run:
mdls -name kMDItemCFBundleIdentifier /Applications/GeForce\ NOW.app
# Expected: "com.nvidia.gfnpc.mall"
```

---

## Xcode Project Setup

1. **Create project**: File → New → Project → macOS → App
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Product Name: **GameMode**
   - Bundle Identifier: `com.yourname.GameMode`

2. **Info.plist** — add these keys:
   - `LSUIElement` = `YES` (hides from Dock)
   - `NSAppleEventsUsageDescription` = "GameMode needs to monitor running applications."

3. **Signing & Capabilities**:
   - Disable App Sandbox (required for `defaults write` and `Process` shell commands)
   - Or if you want to keep Sandbox, you'll need a helper tool — **recommended to disable sandbox for this utility**

4. **Deployment Target**: macOS 14.0+ (Sonoma) recommended, or 13.0+ (Ventura)

---

## Source Code

### File: `GameModeApp.swift`

The app entry point. Sets up the menu bar and starts monitoring.

```swift
import SwiftUI

@main
struct GameModeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No window — menu bar only
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var appMonitor: AppMonitor!
    private let settingsManager = SettingsManager()
    private var isGamingMode = false
    private var isMouseBoosted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupAppMonitor()
        registerAsLoginItem()

        // Check if GeForce Now is already running
        let runningApps = NSWorkspace.shared.runningApplications
        if runningApps.contains(where: { $0.bundleIdentifier == AppMonitor.geforceNowBundleID }) {
            activateGamingMode()
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "GameMode")
        }

        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()

        // Status
        let statusTitle = isGamingMode ? "⚡ Gaming Mode Active" : "😴 Normal Mode"
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Mouse toggle
        let mouseTitle = isMouseBoosted ? "🖱 Mouse: GAMING (Max Speed)" : "🖱 Mouse: Normal"
        let mouseItem = NSMenuItem(title: mouseTitle, action: #selector(toggleMouse), keyEquivalent: "m")
        mouseItem.target = self
        menu.addItem(mouseItem)

        menu.addItem(NSMenuItem.separator())

        // Manual overrides
        let forceGaming = NSMenuItem(title: "Force Gaming Mode", action: #selector(forceGamingMode), keyEquivalent: "g")
        forceGaming.target = self
        menu.addItem(forceGaming)

        let forceNormal = NSMenuItem(title: "Force Normal Mode", action: #selector(forceNormalMode), keyEquivalent: "n")
        forceNormal.target = self
        menu.addItem(forceNormal)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit GameMode", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleMouse() {
        isMouseBoosted.toggle()
        if isMouseBoosted {
            settingsManager.setMouseSpeed(.gaming)
        } else {
            settingsManager.setMouseSpeed(.normal)
        }
        updateMenu()
    }

    @objc private func forceGamingMode() {
        activateGamingMode()
    }

    @objc private func forceNormalMode() {
        deactivateGamingMode()
    }

    @objc private func quitApp() {
        // Restore normal settings before quitting
        if isGamingMode {
            deactivateGamingMode()
        }
        if isMouseBoosted {
            isMouseBoosted = false
            settingsManager.setMouseSpeed(.normal)
        }
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Gaming Mode

    func activateGamingMode() {
        guard !isGamingMode else { return }
        isGamingMode = true

        settingsManager.setFunctionKeys(enabled: true)
        settingsManager.setSpotlightShortcut(enabled: false)

        updateMenu()
        showNotification(title: "Gaming Mode On", body: "Function keys enabled, Spotlight shortcut disabled")
    }

    func deactivateGamingMode() {
        guard isGamingMode else { return }
        isGamingMode = false

        settingsManager.setFunctionKeys(enabled: false)
        settingsManager.setSpotlightShortcut(enabled: true)

        // Also reset mouse if boosted
        if isMouseBoosted {
            isMouseBoosted = false
            settingsManager.setMouseSpeed(.normal)
        }

        updateMenu()
        showNotification(title: "Normal Mode Restored", body: "Settings reverted to defaults")
    }

    // MARK: - App Monitor

    private func setupAppMonitor() {
        appMonitor = AppMonitor(
            onGeForceNowLaunched: { [weak self] in
                self?.activateGamingMode()
            },
            onGeForceNowTerminated: { [weak self] in
                self?.deactivateGamingMode()
            }
        )
    }

    // MARK: - Login Item

    private func registerAsLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                print("Failed to register as login item: \(error)")
            }
        }
    }

    // MARK: - Notification

    private func showNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = nil
        NSUserNotificationCenter.default.deliver(notification)
    }
}
```

### File: `AppMonitor.swift`

Watches for GeForce Now launch and termination events.

```swift
import AppKit

class AppMonitor {
    static let geforceNowBundleID = "com.nvidia.gfnpc.mall"
    // If the above doesn't match, try: "com.nvidia.GeForceNOW"
    // Verify with: mdls -name kMDItemCFBundleIdentifier /Applications/GeForce\ NOW.app

    private let onLaunched: () -> Void
    private let onTerminated: () -> Void

    init(onGeForceNowLaunched: @escaping () -> Void,
         onGeForceNowTerminated: @escaping () -> Void) {
        self.onLaunched = onGeForceNowLaunched
        self.onTerminated = onGeForceNowTerminated

        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter

        center.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.geforceNowBundleID else {
            return
        }
        print("[GameMode] GeForce Now launched")
        DispatchQueue.main.async { self.onLaunched() }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.geforceNowBundleID else {
            return
        }
        print("[GameMode] GeForce Now terminated")
        DispatchQueue.main.async { self.onTerminated() }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
```

### File: `SettingsManager.swift`

Handles all macOS system settings manipulation via shell commands.

```swift
import Foundation

class SettingsManager {

    // MARK: - Configuration

    /// Your normal mouse speed. Run `defaults read -g com.apple.mouse.scaling` to find yours.
    private let normalMouseSpeed: Double = 2.0  // <-- CHANGE THIS to your value
    /// Max mouse speed for gaming. 3.0 is the System Settings max; you can go higher.
    private let gamingMouseSpeed: Double = 3.0   // <-- Adjust if needed (try 5.0 for very fast)

    enum MouseMode {
        case gaming
        case normal
    }

    // MARK: - Function Keys

    /// Toggle "Use F1, F2, etc. keys as standard function keys"
    /// - Parameter enabled: true = F1-F12 act as function keys (gaming), false = special keys (normal)
    func setFunctionKeys(enabled: Bool) {
        let value = enabled ? "true" : "false"
        shell("defaults", "write", "NSGlobalDomain", "com.apple.keyboard.fnState", "-bool", value)

        // Kill cfprefsd to force the preference daemon to re-read.
        // macOS auto-restarts it. This avoids needing a logout.
        shell("killall", "-u", NSUserName(), "cfprefsd")

        print("[SettingsManager] Function keys standard mode: \(enabled)")
    }

    // MARK: - Spotlight Shortcut

    /// Toggle the ⌘Space Spotlight shortcut
    /// - Parameter enabled: true = Spotlight shortcut active, false = disabled
    func setSpotlightShortcut(enabled: Bool) {
        let plistPath = "\(NSHomeDirectory())/Library/Preferences/com.apple.symbolichotkeys.plist"
        let enabledStr = enabled ? "true" : "false"

        // Use PlistBuddy to modify the symbolic hot keys plist
        // Key 64 = "Show Spotlight search" (⌘Space)
        // Key 65 = "Show Finder search window" (⌥⌘Space)

        // First, try to set enabled flag. If the key structure doesn't exist, create it.
        let buddy = "/usr/libexec/PlistBuddy"

        // Delete and recreate to avoid "entry already exists" errors
        shellIgnoringErrors(buddy, "-c", "Delete :AppleSymbolicHotKeys:64", plistPath)
        shell(buddy, "-c", "Add :AppleSymbolicHotKeys:64:enabled bool \(enabledStr)", plistPath)
        shell(buddy, "-c", "Add :AppleSymbolicHotKeys:64:value:type string standard", plistPath)
        shell(buddy, "-c", "Add :AppleSymbolicHotKeys:64:value:parameters array", plistPath)
        shell(buddy, "-c", "Add :AppleSymbolicHotKeys:64:value:parameters: integer 32", plistPath)   // ASCII space
        shell(buddy, "-c", "Add :AppleSymbolicHotKeys:64:value:parameters: integer 49", plistPath)   // Virtual key code for space
        shell(buddy, "-c", "Add :AppleSymbolicHotKeys:64:value:parameters: integer 1048576", plistPath)  // ⌘ modifier mask

        // Apply changes instantly using the private activateSettings utility
        // This is the key trick — without this, changes require a reboot
        shell("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", "-u")

        print("[SettingsManager] Spotlight shortcut enabled: \(enabled)")
    }

    // MARK: - Mouse Speed

    /// Set mouse tracking speed
    func setMouseSpeed(_ mode: MouseMode) {
        let speed: Double
        switch mode {
        case .gaming:
            speed = gamingMouseSpeed
        case .normal:
            speed = normalMouseSpeed
        }

        shell("defaults", "write", "-g", "com.apple.mouse.scaling", "-float", String(speed))

        // Kill cfprefsd to apply without logout
        shell("killall", "-u", NSUserName(), "cfprefsd")

        print("[SettingsManager] Mouse speed set to: \(speed)")
    }

    // MARK: - Shell Execution

    @discardableResult
    private func shell(_ args: String...) -> (output: String, exitCode: Int32) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[SettingsManager] Failed to run \(args.joined(separator: " ")): \(error)")
            return ("", -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }

    @discardableResult
    private func shellIgnoringErrors(_ args: String...) -> (output: String, exitCode: Int32) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Silently ignore — expected for "delete non-existing key"
            return ("", -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }
}
```

---

## How Each Setting Is Changed

### Function Keys (`com.apple.keyboard.fnState`)

```bash
# Enable standard function keys (Gaming)
defaults write NSGlobalDomain com.apple.keyboard.fnState -bool true

# Restore special keys (Normal)
defaults write NSGlobalDomain com.apple.keyboard.fnState -bool false

# Force preference daemon to re-read (avoids logout)
killall -u $(whoami) cfprefsd
```

This writes to `~/Library/Preferences/.GlobalPreferences.plist`. The `killall cfprefsd` trick forces the preferences daemon to restart and re-read the plist, making the change take effect for newly launched apps without a full logout.

**Caveat**: Already-running apps may not pick up the change until they're relaunched. Since you're launching GeForce Now *after* the setting changes, this is fine for your workflow.

### Spotlight Shortcut (`com.apple.symbolichotkeys` key 64)

```bash
# Disable ⌘Space for Spotlight
/usr/libexec/PlistBuddy ~/Library/Preferences/com.apple.symbolichotkeys.plist \
  -c "Delete :AppleSymbolicHotKeys:64" \
  -c "Add :AppleSymbolicHotKeys:64:enabled bool false" \
  -c "Add :AppleSymbolicHotKeys:64:value:parameters array" \
  -c "Add :AppleSymbolicHotKeys:64:value:parameters: integer 32" \
  -c "Add :AppleSymbolicHotKeys:64:value:parameters: integer 49" \
  -c "Add :AppleSymbolicHotKeys:64:value:parameters: integer 1048576" \
  -c "Add :AppleSymbolicHotKeys:64:type string standard"

# CRITICAL: Apply instantly without reboot
/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
```

The `activateSettings -u` binary is a private macOS utility that reads `com.apple.symbolichotkeys` and rebinds all system shortcuts immediately. Without it, changes only take effect after reboot.

### Mouse Sensitivity (`com.apple.mouse.scaling`)

```bash
# Max speed (gaming) — System Settings slider max is 3.0, but you can go higher
defaults write -g com.apple.mouse.scaling -float 3.0

# Normal speed (your value)
defaults write -g com.apple.mouse.scaling -float 2.0

# Force re-read
killall -u $(whoami) cfprefsd
```

System Settings UI shows a slider from 0.0 to 3.0. Values above 3.0 work but aren't exposed in the UI. If 3.0 isn't fast enough, try 5.0 or even 7.0.

---

## Permissions Required

After building and running the app for the first time:

1. **Accessibility**: System Settings → Privacy & Security → Accessibility → Add GameMode.app
   - Needed for `activateSettings` to bind/unbind system shortcuts

2. **Notifications** (optional): Allow notifications so you get a banner when modes switch

3. **App Sandbox must be disabled** in Xcode → Signing & Capabilities. The app needs to:
   - Run shell commands (`Process`)
   - Write to `~/Library/Preferences/` plists
   - Call `activateSettings` from a private framework

---

## Testing

### Manual Test Commands

Run these in Terminal to verify each setting change works on your system before building:

```bash
# Test 1: Function keys
defaults write NSGlobalDomain com.apple.keyboard.fnState -bool true
killall -u $(whoami) cfprefsd
# Open a new app and check if F1-F12 behave as function keys
# Revert:
defaults write NSGlobalDomain com.apple.keyboard.fnState -bool false
killall -u $(whoami) cfprefsd

# Test 2: Spotlight
/usr/libexec/PlistBuddy ~/Library/Preferences/com.apple.symbolichotkeys.plist \
  -c "Delete :AppleSymbolicHotKeys:64" \
  -c "Add :AppleSymbolicHotKeys:64:enabled bool false" \
  -c "Add :AppleSymbolicHotKeys:64:value:parameters array" \
  -c "Add :AppleSymbolicHotKeys:64:value:parameters: integer 32" \
  -c "Add :AppleSymbolicHotKeys:64:value:parameters: integer 49" \
  -c "Add :AppleSymbolicHotKeys:64:value:parameters: integer 1048576" \
  -c "Add :AppleSymbolicHotKeys:64:type string standard"
/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
# Try ⌘Space — should NOT open Spotlight
# Revert:
/usr/libexec/PlistBuddy ~/Library/Preferences/com.apple.symbolichotkeys.plist \
  -c "Delete :AppleSymbolicHotKeys:64" \
  -c "Add :AppleSymbolicHotKeys:64:enabled bool true" \
  -c "Add :AppleSymbolicHotKeys:64:value:parameters array" \
  -c "Add :AppleSymbolicHotKeys:64:value:parameters: integer 32" \
  -c "Add :AppleSymbolicHotKeys:64:value:parameters: integer 49" \
  -c "Add :AppleSymbolicHotKeys:64:value:parameters: integer 1048576" \
  -c "Add :AppleSymbolicHotKeys:64:type string standard"
/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u

# Test 3: Mouse speed
defaults read -g com.apple.mouse.scaling   # note your current value
defaults write -g com.apple.mouse.scaling -float 3.0
killall -u $(whoami) cfprefsd
# Move mouse — should feel faster
# Revert to your value:
defaults write -g com.apple.mouse.scaling -float YOUR_VALUE
killall -u $(whoami) cfprefsd
```

---

## Known Limitations & Workarounds

| Issue | Detail | Workaround |
|-------|--------|------------|
| Function key change may not apply to already-running apps | `cfprefsd` restart only affects new preference reads | GeForce Now launches *after* the toggle, so this is fine |
| `activateSettings` is a private utility | Ships with macOS but is undocumented; could break in a future macOS update | If it breaks, fall back to `killall cfprefsd` + `killall SystemUIServer` |
| Mouse speed might need logout on some macOS versions | The `cfprefsd` kill trick works on most versions but not guaranteed | If it doesn't work, you may need `killall Dock` or worst case re-open System Settings → Mouse once |
| NSUserNotification is deprecated in macOS 14+ | Apple wants you to use UNUserNotificationCenter | Replace with `UNUserNotificationCenter` if targeting macOS 14+ |
| GeForce Now bundle ID may vary | Different versions or regions might use different IDs | Check with `mdls` command, update `geforceNowBundleID` constant |

---

## Future Enhancements

- **IOKit HID device monitoring**: Auto-detect when your gaming mouse is plugged in and toggle mouse speed automatically (no manual button needed). Uses `IOHIDManager` to watch for USB device attach/detach events by vendor/product ID.
- **Per-game profiles**: Different settings for CS2 vs casual games (e.g., mouse speed only for competitive titles).
- **Settings backup**: On first launch, snapshot all current settings values so "Normal Mode" always restores exactly what you had.
- **SwiftUI Settings window**: A proper preferences panel to configure mouse speed values, GeForce Now bundle ID, etc. without editing source code.
