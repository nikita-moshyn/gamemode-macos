//
//  AppDelegate.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import Carbon
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let configStore = ConfigStore.shared
    private let settingsManager = SettingsManager()
    private var appMonitor: AppMonitor!
    private var hotkeyManager = HotkeyManager()
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    private var isGamingMode: Bool {
        get { configStore.isGamingMode }
        set { configStore.isGamingMode = newValue }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Prevent macOS from killing us during shutdown before cleanup
        ProcessInfo.processInfo.disableSuddenTermination()

        // Crash recovery — check for stale gaming state
        if configStore.config.system.restoreOnLaunch {
            recoverIfNeeded()
        }

        // First launch: detect shortcuts and scan for games
        if configStore.isFirstLaunch {
            let detectedShortcuts = AppDetector.detectAvailableShortcuts()
            configStore.mergeDetectedShortcuts(detectedShortcuts)

            let detectedGames = AppDetector.scanForGames()
            for game in detectedGames {
                configStore.addApp(game)
            }
        }

        // Setup menu bar
        setupStatusItem()
        buildMenu()

        // Start app monitoring
        appMonitor = AppMonitor(
            configStore: configStore,
            onActivate: { [weak self] in self?.activateGamingMode() },
            onDeactivate: { [weak self] in self?.deactivateGamingMode() }
        )
        appMonitor.checkRunningApps()

        // Check Accessibility permission (needed for global hotkeys)
        if !HotkeyManager.isAccessibilityGranted {
            HotkeyManager.requestAccessibilityPermission()
        }

        // Register global hotkeys
        registerHotkeys()

        // Register for shutdown/restart
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()
    }

    private func updateMenuBarIcon() {
        let symbolName = isGamingMode ? "gamecontroller.fill" : "gamecontroller"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "GameMode"
        )
    }

    private func buildMenu() {
        menu = NSMenu()

        // Status
        let statusText = isGamingMode ? "Gaming Mode Active" : "Normal Mode"
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        // Game mode toggle
        let gameModeTitle = isGamingMode ? "Disable Game Mode" : "Enable Game Mode"
        let gameModeItem = NSMenuItem(
            title: gameModeTitle,
            action: #selector(toggleGameMode),
            keyEquivalent: ""
        )
        gameModeItem.target = self
        if let hotkey = configStore.config.hotkeys.first(where: { $0.id == "toggleGameMode" }),
           hotkey.isEnabled, let kc = hotkey.keyCode,
           let equiv = KeyCodeMap.menuKeyEquivalent(for: kc) {
            gameModeItem.keyEquivalent = equiv
            gameModeItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
                .intersection(.deviceIndependentFlagsMask)
        }
        menu.addItem(gameModeItem)

        // Mouse toggle — only shown when mouse management is enabled
        if configStore.config.mouse.isEnabled {
            let mouseTitle = configStore.config.mouse.isMouseBoostEnabled
                ? "Disable Mouse Boost" : "Enable Mouse Boost"
            let mouseItem = NSMenuItem(
                title: mouseTitle,
                action: #selector(toggleMouseBoost),
                keyEquivalent: ""
            )
            mouseItem.target = self
            if let hotkey = configStore.config.hotkeys.first(where: { $0.id == "toggleMouseBoost" }),
               hotkey.isEnabled, let kc = hotkey.keyCode,
               let equiv = KeyCodeMap.menuKeyEquivalent(for: kc) {
                mouseItem.keyEquivalent = equiv
                mouseItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
                    .intersection(.deviceIndependentFlagsMask)
            }
            menu.addItem(mouseItem)
        }

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // About
        let aboutItem = NSMenuItem(
            title: "About GameMode",
            action: #selector(openAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Check for Updates
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit GameMode",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    // MARK: - Game Mode

    private func activateGamingMode() {
        guard !isGamingMode else { return }

        let config = configStore.config

        // Auto-capture mouse speed before we touch anything
        var capturedMouseSpeed: Double? = nil
        if config.mouse.isEnabled && config.mouse.autoCapture {
            capturedMouseSpeed = settingsManager.readCurrentMouseSpeed()
            if let speed = capturedMouseSpeed {
                configStore.config.mouse.capturedSystemSpeed = speed
            }
        }

        // Compute what we're about to change
        let shortcutIDs = config.shortcuts
            .filter { $0.disableInGamingMode }
            .map { $0.id }
        let willChangeFunction = config.functionKeysInGamingMode
        let willChangeMouse = config.mouse.isEnabled && config.mouse.isMouseBoostEnabled

        // Gestures
        let gesturesToDisable = config.gestures.filter { $0.disableInGamingMode }
        let willChangeGestures = !gesturesToDisable.isEmpty
        var capturedGestureValues: [String: Int] = [:]
        if willChangeGestures {
            capturedGestureValues = settingsManager.captureGestureValues(entries: gesturesToDisable)
        }

        // Write state journal FIRST
        let state = GameModeState(
            isActive: true,
            activatedAt: Date(),
            appliedChanges: AppliedChanges(
                functionKeysChanged: willChangeFunction,
                disabledShortcutIDs: shortcutIDs,
                mouseSpeedChanged: willChangeMouse,
                previousMouseSpeed: capturedMouseSpeed ?? config.mouse.normalSpeed,
                gesturesChanged: willChangeGestures,
                previousGestureValues: willChangeGestures ? capturedGestureValues : nil
            )
        )
        StateJournal.write(state)

        // Apply changes
        if willChangeFunction {
            settingsManager.writeFunctionKeys(enabled: true)
        }
        if !shortcutIDs.isEmpty {
            settingsManager.writeShortcuts(ids: shortcutIDs, enabled: false)
        }
        if willChangeGestures {
            settingsManager.writeGestures(entries: gesturesToDisable, value: 0)
        }
        if willChangeFunction || !shortcutIDs.isEmpty || willChangeGestures {
            settingsManager.applyKeyboardChanges()
        }

        if willChangeMouse {
            settingsManager.applyMouseSpeed(config.mouse.gamingSpeed)
        }

        isGamingMode = true
        updateMenuBarIcon()
        buildMenu()

        // Notification
        var adjustments: [String] = []
        if willChangeFunction || !shortcutIDs.isEmpty { adjustments.append("keyboard") }
        if willChangeGestures { adjustments.append("gestures") }
        if willChangeMouse { adjustments.append("mouse sensitivity") }
        let body = adjustments.isEmpty
            ? "Gaming mode enabled"
            : adjustments.joined(separator: ", ").prefix(1).uppercased()
              + adjustments.joined(separator: ", ").dropFirst() + " adjusted"
        showNotification(title: "Game Mode — Active", body: body)
    }

    private func deactivateGamingMode() {
        guard isGamingMode else { return }

        let config = configStore.config
        let state = StateJournal.load()

        // Restore keyboard from journal (truth of what was actually changed)
        if state.appliedChanges.functionKeysChanged {
            settingsManager.writeFunctionKeys(enabled: false)
        }
        if !state.appliedChanges.disabledShortcutIDs.isEmpty {
            settingsManager.writeShortcuts(
                ids: state.appliedChanges.disabledShortcutIDs, enabled: true
            )
        }
        // Restore gestures
        if state.appliedChanges.gesturesChanged,
           let previousValues = state.appliedChanges.previousGestureValues {
            let gestureEntries = configStore.config.gestures.filter { previousValues.keys.contains($0.id) }
            settingsManager.restoreGestures(capturedValues: previousValues, entries: gestureEntries)
        }

        if state.appliedChanges.functionKeysChanged
            || !state.appliedChanges.disabledShortcutIDs.isEmpty
            || state.appliedChanges.gesturesChanged {
            settingsManager.applyKeyboardChanges()
        }

        // Restore mouse
        if state.appliedChanges.mouseSpeedChanged {
            let restoreSpeed: Double
            if config.mouse.autoCapture,
               let captured = state.appliedChanges.previousMouseSpeed {
                restoreSpeed = captured
            } else {
                restoreSpeed = config.mouse.normalSpeed
            }
            settingsManager.applyMouseSpeed(restoreSpeed)
        }

        // Clear journal
        StateJournal.clear()

        isGamingMode = false
        updateMenuBarIcon()
        buildMenu()

        showNotification(title: "Game Mode — Deactivated", body: "All settings restored")
    }

    // MARK: - Actions

    @objc private func toggleGameMode() {
        if isGamingMode {
            deactivateGamingMode()
        } else {
            activateGamingMode()
        }
    }

    @objc private func toggleMouseBoost() {
        configStore.config.mouse.isMouseBoostEnabled.toggle()
        let enabled = configStore.config.mouse.isMouseBoostEnabled

        if isGamingMode {
            // Apply immediately
            if enabled {
                settingsManager.applyMouseSpeed(configStore.config.mouse.gamingSpeed)
            } else if let captured = configStore.config.mouse.capturedSystemSpeed {
                settingsManager.applyMouseSpeed(captured)
            } else {
                settingsManager.applyMouseSpeed(configStore.config.mouse.normalSpeed)
            }
            let title = enabled ? "Mouse Sensitivity — Gaming" : "Mouse Sensitivity — Normal"
            let body = enabled ? "Tracking speed set to maximum" : "Tracking speed restored"
            showNotification(title: title, body: body)
        } else {
            // Save only, don't apply
            showNotification(
                title: "Mouse Sensitivity — Saved",
                body: "Will apply when game mode activates"
            )
        }

        buildMenu()
    }

    @objc private func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingController(
            rootView: SettingsWindow(
                configStore: configStore,
                onForceRestore: { [weak self] in self?.forceRestoreAllSettings() },
                onHotkeysChanged: { [weak self] in self?.registerHotkeys() }
            )
        )

        let window = NSWindow(contentViewController: hostingView)
        window.title = "GameMode Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 520))
        window.minSize = NSSize(width: 620, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)

        // Start polling accessibility status while settings is open
        configStore.startAccessibilityPolling()

        // Observe window close to stop polling
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func settingsWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        configStore.stopAccessibilityPolling()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
    }

    @objc private func openAbout() {
        if let window = aboutWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: hostingView)
        window.title = "About GameMode"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 300, height: 340))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.aboutWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates() {
        if let url = URL(string: "https://github.com/user/GameMode/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        if isGamingMode && configStore.config.system.restoreOnShutdown {
            deactivateGamingMode()
        }
        NSApp.terminate(nil)
    }

    // MARK: - Shutdown / Termination

    @objc private func systemWillPowerOff(_ notification: Notification) {
        if isGamingMode && configStore.config.system.restoreOnShutdown {
            deactivateGamingMode()
        }
    }

    @objc private func appWillTerminate(_ notification: Notification) {
        if isGamingMode && configStore.config.system.restoreOnShutdown {
            deactivateGamingMode()
        }
    }

    // MARK: - Crash Recovery

    private func recoverIfNeeded() {
        let state = StateJournal.load()
        guard state.isActive else { return }

        print("[AppDelegate] Recovering from stale gaming state...")
        let changes = state.appliedChanges

        if changes.functionKeysChanged {
            settingsManager.writeFunctionKeys(enabled: false)
        }
        if !changes.disabledShortcutIDs.isEmpty {
            settingsManager.writeShortcuts(ids: changes.disabledShortcutIDs, enabled: true)
        }
        if changes.gesturesChanged, let previousValues = changes.previousGestureValues {
            let gestureEntries = configStore.config.gestures.filter { previousValues.keys.contains($0.id) }
            settingsManager.restoreGestures(capturedValues: previousValues, entries: gestureEntries)
        }
        if changes.functionKeysChanged || !changes.disabledShortcutIDs.isEmpty || changes.gesturesChanged {
            settingsManager.applyKeyboardChanges()
        }
        if changes.mouseSpeedChanged, let previousSpeed = changes.previousMouseSpeed {
            settingsManager.applyMouseSpeed(previousSpeed)
        }

        StateJournal.clear()
        showNotification(
            title: "GameMode — Settings Recovered",
            body: "System settings restored after unexpected shutdown"
        )
    }

    // MARK: - Force Restore (called from SystemSettingsView)

    func forceRestoreAllSettings() {
        settingsManager.writeFunctionKeys(enabled: false)

        let allShortcutIDs = configStore.config.shortcuts.map { $0.id }
        settingsManager.writeShortcuts(ids: allShortcutIDs, enabled: true)

        // Restore gestures from journal if available, otherwise re-enable all
        let journalState = StateJournal.load()
        if let previousValues = journalState.appliedChanges.previousGestureValues {
            let gestureEntries = configStore.config.gestures.filter { previousValues.keys.contains($0.id) }
            settingsManager.restoreGestures(capturedValues: previousValues, entries: gestureEntries)
        } else {
            // Best effort: re-enable all gestures that were set to be disabled
            let gesturesToRestore = configStore.config.gestures.filter { $0.disableInGamingMode }
            if !gesturesToRestore.isEmpty {
                settingsManager.writeGestures(entries: gesturesToRestore, value: 2)
            }
        }

        settingsManager.applyKeyboardChanges()

        if let captured = configStore.config.mouse.capturedSystemSpeed {
            settingsManager.applyMouseSpeed(captured)
        } else {
            settingsManager.applyMouseSpeed(configStore.config.mouse.normalSpeed)
        }

        isGamingMode = false
        StateJournal.clear()
        updateMenuBarIcon()
        buildMenu()

        showNotification(
            title: "GameMode — Force Restored",
            body: "All settings reverted to pre-gaming values"
        )
    }

    // MARK: - Global Hotkeys

    private func registerHotkeys() {
        let hotkeys = configStore.config.hotkeys
        hotkeyManager.register(hotkeys: hotkeys, handlers: [
            "toggleGameMode": { [weak self] in self?.toggleGameMode() },
            "toggleMouseBoost": { [weak self] in self?.toggleMouseBoost() },
            "toggleInputSource": { [weak self] in self?.toggleInputSource() },
        ])
    }

    private func toggleInputSource() {
        // Use Carbon TIS API to cycle to the next input source
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource],
              sourceList.count >= 2 else {
            print("[Hotkeys] Cannot toggle input source: fewer than 2 sources available")
            return
        }

        // Find selectable keyboard input sources
        let selectableSources = sourceList.filter { source in
            guard let category = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) else { return false }
            let cat = Unmanaged<CFString>.fromOpaque(category).takeUnretainedValue()
            guard cat == kTISCategoryKeyboardInputSource else { return false }
            guard let selectable = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable) else { return false }
            let sel = Unmanaged<CFBoolean>.fromOpaque(selectable).takeUnretainedValue()
            return CFBooleanGetValue(sel)
        }

        guard selectableSources.count >= 2 else {
            print("[Hotkeys] Fewer than 2 selectable input sources")
            return
        }

        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let currentID = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) else { return }
        let currentIDStr = Unmanaged<CFString>.fromOpaque(currentID).takeUnretainedValue() as String

        // Find the next source after the current one
        var foundCurrent = false
        var nextSource: TISInputSource?
        for source in selectableSources {
            if foundCurrent {
                nextSource = source
                break
            }
            guard let srcID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let srcIDStr = Unmanaged<CFString>.fromOpaque(srcID).takeUnretainedValue() as String
            if srcIDStr == currentIDStr {
                foundCurrent = true
            }
        }

        // Wrap around to first source
        let target = nextSource ?? selectableSources[0]
        TISSelectInputSource(target)
        print("[Hotkeys] Switched input source")
    }

    // MARK: - Notifications

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
