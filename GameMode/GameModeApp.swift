//
//  GameModeApp.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI
import ServiceManagement
import UserNotifications

@main
struct GameModeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu-bar-only app — no window needed
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var appMonitor: AppMonitor!
    private let settingsManager = SettingsManager()

    /// Whether gaming mode is currently active (keyboard settings applied).
    private var isGamingMode = false

    /// Whether the user wants gaming mouse speed.
    /// This is a *preference toggle* — it records intent, not necessarily the live state.
    /// • Game mode OFF  → toggling this just saves the preference (no apply).
    /// • Game mode ON   → toggling this applies the change immediately via IOKit.
    private var isMouseBoosted = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestNotificationPermission()
        setupMenuBar()
        setupAppMonitor()
        registerAsLoginItem()

        // If GeForce Now is already running when we launch, activate immediately
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == AppMonitor.geforceNowBundleID
        }) {
            activateGamingMode()
        }
    }

    // MARK: - Notifications Setup

    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("[GameMode] Notification permission error: \(error)")
            }
        }
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "gamecontroller",
                accessibilityDescription: "GameMode"
            )
        }

        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()

        // — Status indicator
        let statusTitle = isGamingMode ? "⚡ Gaming Mode Active" : "😴 Normal Mode"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // — Mouse speed toggle
        let mouseTitle: String
        if isMouseBoosted {
            mouseTitle = isGamingMode
                ? "🖱 Mouse: GAMING (Active)"
                : "🖱 Mouse: GAMING (will apply in game mode)"
        } else {
            mouseTitle = "🖱 Mouse: Normal"
        }
        let mouseItem = NSMenuItem(
            title: mouseTitle,
            action: #selector(toggleMouse),
            keyEquivalent: "m"
        )
        mouseItem.target = self
        menu.addItem(mouseItem)

        menu.addItem(NSMenuItem.separator())

        // — Manual overrides
        let forceGaming = NSMenuItem(
            title: "Force Gaming Mode",
            action: #selector(forceGamingMode),
            keyEquivalent: "g"
        )
        forceGaming.target = self
        menu.addItem(forceGaming)

        let forceNormal = NSMenuItem(
            title: "Force Normal Mode",
            action: #selector(forceNormalMode),
            keyEquivalent: "n"
        )
        forceNormal.target = self
        menu.addItem(forceNormal)

        menu.addItem(NSMenuItem.separator())

        // — Quit
        let quitItem = NSMenuItem(
            title: "Quit GameMode",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleMouse() {
        isMouseBoosted.toggle()
        let mode: SettingsManager.MouseMode = isMouseBoosted ? .gaming : .normal

        if isGamingMode {
            // Game mode ON → apply immediately via IOKit (instant, no freeze)
            settingsManager.applyMouseSpeed(mode)
            showNotification(
                title: isMouseBoosted ? "Mouse: Gaming" : "Mouse: Normal",
                body: isMouseBoosted ? "Sensitivity maxed out" : "Sensitivity restored"
            )
        } else {
            // Game mode OFF → just save preference, will apply when gaming starts
            settingsManager.persistMouseSpeed(mode)
            showNotification(
                title: isMouseBoosted ? "Mouse: Gaming (saved)" : "Mouse: Normal (saved)",
                body: "Will apply when gaming mode activates"
            )
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
        // Restore everything before quitting
        if isGamingMode {
            deactivateGamingMode()
        }
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Gaming Mode

    func activateGamingMode() {
        guard !isGamingMode else { return }
        isGamingMode = true

        // Write keyboard preferences (no daemon restart yet)
        settingsManager.writeFunctionKeys(enabled: true)
        settingsManager.writeSpotlightShortcut(enabled: false)

        // ONE cfprefsd restart + activateSettings for all keyboard changes
        settingsManager.applyKeyboardChanges()

        // Apply mouse if the user has it boosted (IOKit — instant, no freeze)
        if isMouseBoosted {
            settingsManager.applyMouseSpeed(.gaming)
        }

        updateMenu()
        showNotification(
            title: "⚡ Gaming Mode On",
            body: isMouseBoosted
                ? "Function keys + Spotlight + Mouse applied"
                : "Function keys enabled, Spotlight shortcut disabled"
        )
    }

    func deactivateGamingMode() {
        guard isGamingMode else { return }
        isGamingMode = false

        // Write keyboard preferences (no daemon restart yet)
        settingsManager.writeFunctionKeys(enabled: false)
        settingsManager.writeSpotlightShortcut(enabled: true)

        // ONE cfprefsd restart + activateSettings for all keyboard changes
        settingsManager.applyKeyboardChanges()

        // Restore normal mouse speed if it was boosted (IOKit — instant, no freeze)
        if isMouseBoosted {
            settingsManager.applyMouseSpeed(.normal)
        }

        updateMenu()
        showNotification(
            title: "😴 Normal Mode Restored",
            body: "All settings reverted to defaults"
        )
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
                print("[GameMode] Registered as login item")
            } catch {
                print("[GameMode] Failed to register as login item: \(error)")
            }
        }
    }

    // MARK: - Notification Helper

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[GameMode] Notification error: \(error)")
            }
        }
    }
}
