//
//  AppDelegate.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2025 Nikita Moshyn. All rights reserved.
//

import AppKit
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let configStore = ConfigStore.shared
    private let settingsManager = SettingsManager()
    private var appMonitor: AppMonitor!
    private var settingsWindow: NSWindow?

    private var isGamingMode = false

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
            keyEquivalent: "g"
        )
        gameModeItem.target = self
        gameModeItem.keyEquivalentModifierMask = .command
        menu.addItem(gameModeItem)

        // Mouse toggle — only shown when mouse management is enabled
        if configStore.config.mouse.isEnabled {
            let mouseTitle: String
            if isGamingMode {
                mouseTitle = configStore.config.mouse.isMouseBoostEnabled
                    ? "Disable Mouse Boost" : "Enable Mouse Boost"
            } else {
                mouseTitle = configStore.config.mouse.isMouseBoostEnabled
                    ? "Disable Mouse Boost" : "Enable Mouse Boost"
            }
            let mouseItem = NSMenuItem(
                title: mouseTitle,
                action: #selector(toggleMouseBoost),
                keyEquivalent: "m"
            )
            mouseItem.target = self
            mouseItem.keyEquivalentModifierMask = .command
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

        // Write state journal FIRST
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
        StateJournal.write(state)

        // Apply changes
        if willChangeFunction {
            settingsManager.writeFunctionKeys(enabled: true)
        }
        if !shortcutIDs.isEmpty {
            settingsManager.writeShortcuts(ids: shortcutIDs, enabled: false)
        }
        if willChangeFunction || !shortcutIDs.isEmpty {
            settingsManager.applyKeyboardChanges()
        }

        if willChangeMouse {
            settingsManager.applyMouseSpeed(config.mouse.gamingSpeed)
        }

        isGamingMode = true
        updateMenuBarIcon()
        buildMenu()

        // Notification
        let body = willChangeMouse
            ? "Keyboard, shortcuts, and mouse sensitivity adjusted"
            : "Keyboard shortcuts and function keys adjusted"
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
        if state.appliedChanges.functionKeysChanged
            || !state.appliedChanges.disabledShortcutIDs.isEmpty {
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
                onForceRestore: { [weak self] in self?.forceRestoreAllSettings() }
            )
        )

        let window = NSWindow(contentViewController: hostingView)
        window.title = "GameMode Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        self.settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
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
        if changes.functionKeysChanged || !changes.disabledShortcutIDs.isEmpty {
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
