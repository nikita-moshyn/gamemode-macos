//
//  AppDelegate.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import Combine
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
    private var cancellables = Set<AnyCancellable>()
    private let transitionStateQueue = DispatchQueue(label: "com.nikita.GameMode.transitionState")
    private var targetGameModeState = false
    private var appliedGameModeState = false
    private var isProcessingGameModeTransitions = false
    private var transitionSequence: UInt64 = 0

    private var isGamingMode: Bool {
        get { configStore.isGamingMode }
        set { configStore.isGamingMode = newValue }
    }

    private struct TransitionTrace {
        let id: UInt64
        let name: String
        private let startedAt = CFAbsoluteTimeGetCurrent()

        func log(_ message: String) {
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            print("[\(name)#\(id)] \(message) (+\(String(format: "%.3f", elapsed))s)")
        }
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
        observeConfigurationChanges()

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

    private func observeConfigurationChanges() {
        configStore.$config
            .map(\.mouse.isEnabled)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.buildMenu()
                guard let self, !isEnabled else { return }
                self.handleMouseSubsystemDisabled()
            }
            .store(in: &cancellables)
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
            action: #selector(toggleGameModeMenuAction),
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

        // Mouse toggle — only shown when mouse management is enabled and gaming mode is active
        if configStore.config.mouse.isEnabled && isGamingMode {
            let mouseTitle = configStore.isMouseBoostApplied
                ? "Disable Mouse Boost" : "Enable Mouse Boost"
            let mouseItem = NSMenuItem(
                title: mouseTitle,
                action: #selector(toggleMouseBoostMenuAction),
                keyEquivalent: ""
            )
            mouseItem.target = self
            mouseItem.isEnabled = true
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

    private static let settingsQueue = DispatchQueue(label: "com.nikita.GameMode.settings", qos: .userInitiated)

    private func activateGamingMode() {
        requestGameModeTransition(to: true, source: "automatic")
    }

    private func deactivateGamingMode() {
        requestGameModeTransition(to: false, source: "automatic")
    }

    private func requestGameModeTransition(to desiredState: Bool, source: String) {
        print("[GameMode] request source=\(source) target=\(desiredState ? "on" : "off")")
        applyVisibleGamingModeState(desiredState)

        transitionStateQueue.async { [weak self] in
            guard let self else { return }
            self.targetGameModeState = desiredState

            guard !self.isProcessingGameModeTransitions else { return }
            self.isProcessingGameModeTransitions = true

            Self.settingsQueue.async { [weak self] in
                self?.processPendingGameModeTransitions()
            }
        }
    }

    private func processPendingGameModeTransitions() {
        while let transition = nextPendingGameModeTransition() {
            transition.trace.log("begin desired=\(transition.desiredState ? "on" : "off")")
            if transition.desiredState {
                performGameModeActivation(trace: transition.trace)
            } else {
                performGameModeDeactivation(trace: transition.trace)
            }
            transitionStateQueue.sync {
                self.appliedGameModeState = transition.desiredState
            }
            transition.trace.log("completed")
        }
    }

    private func nextPendingGameModeTransition() -> (desiredState: Bool, trace: TransitionTrace)? {
        transitionStateQueue.sync {
            guard appliedGameModeState != targetGameModeState else {
                isProcessingGameModeTransitions = false
                return nil
            }

            transitionSequence += 1
            return (
                desiredState: targetGameModeState,
                trace: TransitionTrace(
                    id: transitionSequence,
                    name: targetGameModeState ? "GameModeOn" : "GameModeOff"
                )
            )
        }
    }

    private func nextTrace(named name: String) -> TransitionTrace {
        let id = transitionStateQueue.sync { () -> UInt64 in
            transitionSequence += 1
            return transitionSequence
        }
        return TransitionTrace(id: id, name: name)
    }

    private func performGameModeActivation(trace: TransitionTrace) {
        let config = currentConfigSnapshot()

        // --- Keyboard settings (fn keys + shortcuts + gestures) ---
        let shortcutIDs = config.shortcuts
            .filter { $0.disableInGamingMode }
            .map { $0.id }
        let gesturesToDisable = config.gestures.filter { $0.disableInGamingMode }

        trace.log("keyboard activate start")
        let snapshot = settingsManager.activateKeyboardSettings(
            functionKeysEnabled: config.functionKeysInGamingMode,
            shortcutIDs: shortcutIDs,
            gestures: gesturesToDisable
        )
        trace.log("keyboard activate complete")

        // --- Mouse ---
        let shouldAutoEnableMouseBoost = config.mouse.isEnabled && config.mouse.isMouseBoostEnabled
        let mouseBaselineSpeed = shouldAutoEnableMouseBoost
            ? captureMouseBaselineSpeed(trace: trace)
            : nil
        let shouldApplyMouseBoost = mouseBaselineSpeed != nil

        // --- Journal ---
        let state = GameModeState(
            isActive: true,
            activatedAt: Date(),
            appliedChanges: AppliedChanges(
                functionKeysChanged: config.functionKeysInGamingMode,
                previousFunctionKeysEnabled: snapshot.previousFunctionKeysEnabled,
                disabledShortcutIDs: snapshot.shortcutIDsToDisable,
                previousShortcutStates: snapshot.previousShortcutStates,
                mouseSpeedChanged: shouldApplyMouseBoost,
                previousMouseSpeed: mouseBaselineSpeed,
                gesturesChanged: !gesturesToDisable.isEmpty,
                previousGestureValues: snapshot.previousGestureValues
            )
        )
        StateJournal.write(state)
        trace.log("journal write complete")

        let didApplyMouseBoost: Bool
        if shouldApplyMouseBoost {
            didApplyMouseBoost = applyMouseSpeed(
                config.mouse.gamingSpeed,
                operation: "mouse apply",
                trace: trace
            )
            if !didApplyMouseBoost {
                StateJournal.update { state in
                    state.appliedChanges.mouseSpeedChanged = false
                    state.appliedChanges.previousMouseSpeed = nil
                }
                trace.log("journal update complete")
            }
        } else {
            didApplyMouseBoost = false
        }

        updateRuntimeMouseState(
            isApplied: didApplyMouseBoost,
            baselineSpeed: didApplyMouseBoost ? mouseBaselineSpeed : nil
        )

        var adjustments: [String] = []
        if config.functionKeysInGamingMode || !snapshot.shortcutIDsToDisable.isEmpty { adjustments.append("keyboard") }
        if !gesturesToDisable.isEmpty { adjustments.append("gestures") }
        if didApplyMouseBoost { adjustments.append("mouse sensitivity") }
        let body = adjustments.isEmpty
            ? "Gaming mode enabled"
            : adjustments.joined(separator: ", ").prefix(1).uppercased()
              + adjustments.joined(separator: ", ").dropFirst() + " adjusted"

        enqueueNotification(title: "Game Mode — Active", body: body, trace: trace)
    }

    private func performGameModeDeactivation(trace: TransitionTrace) {
        let state = StateJournal.load()
        trace.log("journal load complete")

        // --- Keyboard settings (fn keys + shortcuts + gestures) ---
        trace.log("keyboard restore start")
        settingsManager.restoreKeyboardSettings(from: state.appliedChanges)
        trace.log("keyboard restore complete")

        let didVerifyFunctionKeys = !state.appliedChanges.functionKeysChanged || verifyFunctionKeys(
            expected: state.appliedChanges.previousFunctionKeysEnabled ?? false,
            operation: "deactivation",
            trace: trace
        )

        if restoreMouseState(from: state, trace: trace) {
            StateJournal.clear()
            trace.log("journal clear complete")
            let body = didVerifyFunctionKeys
                ? "All settings restored"
                : "Mouse restored, but standard function keys could not be confirmed"
            enqueueNotification(title: "Game Mode — Deactivated", body: body, trace: trace)
        } else {
            enqueueNotification(
                title: "Game Mode — Deactivated",
                body: "Keyboard settings restored, but mouse restore will retry from recovery state",
                trace: trace
            )
        }
    }

    private func captureMouseBaselineSpeed(trace: TransitionTrace) -> Double? {
        guard let liveSpeed = settingsManager.readCurrentMouseSpeed() else {
            trace.log("failed to capture live mouse speed; skipping boost")
            return nil
        }
        trace.log("captured live mouse speed \(String(format: "%.2f", liveSpeed))")
        return liveSpeed
    }

    private func resolvedMouseRestoreSpeed(from state: GameModeState) -> Double? {
        state.appliedChanges.previousMouseSpeed
    }

    @discardableResult
    private func verifyFunctionKeys(
        expected: Bool,
        operation: String,
        trace: TransitionTrace? = nil
    ) -> Bool {
        let verified = settingsManager.verifyFunctionKeysEnabled(expected)
        if verified {
            trace?.log("function key \(operation) verified expected=\(expected)")
        } else {
            let actual = settingsManager.readFunctionKeysEnabled()
            trace?.log(
                "function key \(operation) verification failed expected=\(expected) actual=\(actual)"
            )
        }
        return verified
    }

    private func currentConfigSnapshot() -> GameModeConfig {
        if Thread.isMainThread {
            return configStore.config
        }
        return DispatchQueue.main.sync { configStore.config }
    }

    private func applyVisibleGamingModeState(_ active: Bool) {
        let update = { [weak self] in
            guard let self else { return }
            self.isGamingMode = active
            self.updateMenuBarIcon()
            self.buildMenu()
        }

        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func updateRuntimeMouseState(isApplied: Bool, baselineSpeed: Double?) {
        let update = { [weak self] in
            guard let self else { return }
            self.configStore.isMouseBoostApplied = isApplied
            self.configStore.sessionMouseBaselineSpeed = baselineSpeed
            self.buildMenu()
        }

        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func handleMouseSubsystemDisabled() {
        Self.settingsQueue.async { [weak self] in
            guard let self else { return }

            let trace = self.nextTrace(named: "MouseDisable")
            trace.log("mouse subsystem disabled")

            let state = StateJournal.load()
            let mouseRestored = self.restoreMouseState(from: state, trace: trace)

            if state.isActive && mouseRestored {
                StateJournal.update { state in
                    state.appliedChanges.mouseSpeedChanged = false
                    state.appliedChanges.previousMouseSpeed = nil
                }
                trace.log("journal update complete")
            }
        }
    }

    private func enqueueNotification(title: String, body: String, trace: TransitionTrace? = nil) {
        trace?.log("notification enqueue")
        DispatchQueue.main.async { [weak self] in
            self?.showNotification(title: title, body: body)
        }
    }

    // MARK: - Actions

    @objc private func toggleGameModeMenuAction() {
        requestGameModeTransition(to: !isGamingMode, source: "menu")
    }

    private func toggleGameModeHotkey() {
        requestGameModeTransition(to: !isGamingMode, source: "hotkey")
    }

    @objc private func toggleMouseBoostMenuAction() {
        toggleMouseBoost(source: "menu")
    }

    private func toggleMouseBoostHotkey() {
        toggleMouseBoost(source: "hotkey")
    }

    private func toggleMouseBoost(source: String) {
        guard configStore.config.mouse.isEnabled else {
            print("[MouseBoost] Ignored \(source) toggle because mouse management is disabled")
            return
        }
        guard isGamingMode else {
            print("[MouseBoost] Ignored \(source) toggle because gaming mode is inactive")
            return
        }

        let shouldEnable = !configStore.isMouseBoostApplied

        Self.settingsQueue.async { [weak self] in
            self?.setActiveMouseBoost(source: source, enabled: shouldEnable)
        }
    }

    private func setActiveMouseBoost(source: String, enabled: Bool) {
        let trace = nextTrace(named: "MouseBoost")
        trace.log("request source=\(source) enabled=\(enabled)")

        let config = currentConfigSnapshot()
        guard config.mouse.isEnabled else {
            trace.log("ignored because mouse management is disabled")
            return
        }

        let isGameModeApplied = transitionStateQueue.sync { appliedGameModeState }
        guard isGameModeApplied else {
            trace.log("ignored because gaming mode is inactive")
            return
        }

        let state = StateJournal.load()
        trace.log("journal load complete")

        if enabled {
            guard !state.appliedChanges.mouseSpeedChanged else {
                updateRuntimeMouseState(
                    isApplied: true,
                    baselineSpeed: state.appliedChanges.previousMouseSpeed
                )
                enqueueNotification(
                    title: "Mouse Sensitivity — Gaming",
                    body: "Tracking speed is already boosted",
                    trace: trace
                )
                return
            }

            guard let baselineSpeed = captureMouseBaselineSpeed(trace: trace) else {
                enqueueNotification(
                    title: "Mouse Sensitivity — Unchanged",
                    body: "Could not detect the current mouse speed, so boost was not applied",
                    trace: trace
                )
                return
            }
            StateJournal.update { state in
                state.isActive = true
                state.appliedChanges.mouseSpeedChanged = true
                state.appliedChanges.previousMouseSpeed = baselineSpeed
            }
            trace.log("journal update complete")

            guard applyMouseSpeed(
                config.mouse.gamingSpeed,
                operation: "mouse apply",
                trace: trace
            ) else {
                StateJournal.update { state in
                    state.appliedChanges.mouseSpeedChanged = false
                    state.appliedChanges.previousMouseSpeed = nil
                }
                trace.log("journal update complete")
                updateRuntimeMouseState(isApplied: false, baselineSpeed: nil)
                enqueueNotification(
                    title: "Mouse Sensitivity — Unchanged",
                    body: "Could not apply the configured mouse speed",
                    trace: trace
                )
                return
            }

            updateRuntimeMouseState(isApplied: true, baselineSpeed: baselineSpeed)
            enqueueNotification(
                title: "Mouse Sensitivity — Gaming",
                body: "Tracking speed set to maximum",
                trace: trace
            )
            return
        }

        guard state.appliedChanges.mouseSpeedChanged,
              let restoreSpeed = resolvedMouseRestoreSpeed(from: state) else {
            updateRuntimeMouseState(isApplied: false, baselineSpeed: nil)
            enqueueNotification(
                title: "Mouse Sensitivity — Normal",
                body: "Tracking speed already matches your normal setting",
                trace: trace
            )
            return
        }

        guard applyMouseSpeed(restoreSpeed, operation: "mouse restore", trace: trace) else {
            enqueueNotification(
                title: "Mouse Sensitivity — Unchanged",
                body: "Could not restore the baseline mouse speed",
                trace: trace
            )
            return
        }

        StateJournal.update { state in
            state.appliedChanges.mouseSpeedChanged = false
            state.appliedChanges.previousMouseSpeed = nil
        }
        trace.log("journal update complete")
        updateRuntimeMouseState(isApplied: false, baselineSpeed: nil)
        enqueueNotification(
            title: "Mouse Sensitivity — Normal",
            body: "Tracking speed restored",
            trace: trace
        )
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
                onApplyConfiguredMouseSpeed: { [weak self] in self?.applyConfiguredMouseSpeedLive() },
                onForceRestore: { [weak self] in self?.forceRestoreAllSettings() },
                onResetAllSavedData: { [weak self] in self?.resetAllSavedData() },
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
            deactivateSync()
        }
        NSApp.terminate(nil)
    }

    // MARK: - Shutdown / Termination

    @objc private func systemWillPowerOff(_ notification: Notification) {
        if isGamingMode && configStore.config.system.restoreOnShutdown {
            deactivateSync()
        }
    }

    @objc private func appWillTerminate(_ notification: Notification) {
        if isGamingMode && configStore.config.system.restoreOnShutdown {
            deactivateSync()
        }
    }

    /// Synchronous deactivation for shutdown/quit paths where the process is about to exit.
    private func deactivateSync() {
        let state = StateJournal.load()

        settingsManager.restoreKeyboardSettings(from: state.appliedChanges)

        if restoreMouseState(from: state) {
            StateJournal.clear()
            isGamingMode = false
            updateRuntimeMouseState(isApplied: false, baselineSpeed: nil)
            transitionStateQueue.sync {
                targetGameModeState = false
                appliedGameModeState = false
            }
        }
    }

    // MARK: - Crash Recovery

    private func recoverIfNeeded() {
        let settingsManager = self.settingsManager

        Self.settingsQueue.async {
            let state = StateJournal.load()
            guard state.isActive else { return }
            print("[AppDelegate] Recovering from stale gaming state...")

            settingsManager.restoreKeyboardSettings(from: state.appliedChanges)

            if self.restoreMouseState(from: state) {
                StateJournal.clear()
                self.updateRuntimeMouseState(isApplied: false, baselineSpeed: nil)
                self.transitionStateQueue.sync {
                    self.targetGameModeState = false
                    self.appliedGameModeState = false
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.showNotification(
                    title: "GameMode — Settings Recovered",
                    body: "System settings restored after unexpected shutdown"
                )
            }
        }
    }

    // MARK: - Force Restore (called from SystemSettingsView)

    func forceRestoreAllSettings() {
        // Update UI immediately
        isGamingMode = false
        updateMenuBarIcon()
        buildMenu()

        let settingsManager = self.settingsManager

        Self.settingsQueue.async {
            let journalState = StateJournal.load()

            settingsManager.restoreKeyboardSettings(from: journalState.appliedChanges)

            if self.restoreMouseState(from: journalState) {
                StateJournal.clear()
                self.updateRuntimeMouseState(isApplied: false, baselineSpeed: nil)
                self.transitionStateQueue.sync {
                    self.targetGameModeState = false
                    self.appliedGameModeState = false
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.showNotification(
                    title: "GameMode — Force Restored",
                    body: "All settings reverted to pre-gaming values"
                )
            }
        }
    }

    func resetAllSavedData() {
        Self.settingsQueue.async { [weak self] in
            guard let self else { return }

            var restoredJournal = true
            if self.isGamingMode || StateJournal.hasDirtyState {
                restoredJournal = self.restoreSettingsFromJournalSync()
            }

            if restoredJournal {
                StateJournal.clear()
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configStore.resetAllSavedData()
                self.buildMenu()
                self.registerHotkeys()
                self.showNotification(
                    title: "GameMode — Saved Data Reset",
                    body: "All saved configuration and recovery data were cleared"
                )
            }
        }
    }

    @discardableResult
    private func restoreSettingsFromJournalSync() -> Bool {
        let state = StateJournal.load()
        guard state.isActive else { return true }

        settingsManager.restoreKeyboardSettings(from: state.appliedChanges)

        guard restoreMouseState(from: state) else {
            return false
        }

        StateJournal.clear()
        isGamingMode = false
        updateRuntimeMouseState(isApplied: false, baselineSpeed: nil)
        transitionStateQueue.sync {
            targetGameModeState = false
            appliedGameModeState = false
        }
        return true
    }

    // MARK: - Global Hotkeys

    private func applyConfiguredMouseSpeedLive() {
        Self.settingsQueue.async { [weak self] in
            guard let self else { return }

            let trace = self.nextTrace(named: "MouseApply")
            let config = self.currentConfigSnapshot()
            guard config.mouse.isEnabled else {
                trace.log("ignored because mouse management is disabled")
                return
            }

            guard self.applyMouseSpeed(
                config.mouse.gamingSpeed,
                operation: "mouse apply",
                trace: trace
            ) else {
                self.enqueueNotification(
                    title: "Mouse Sensitivity — Unchanged",
                    body: "Could not apply the configured mouse speed",
                    trace: trace
                )
                return
            }

            self.enqueueNotification(
                title: "Mouse Sensitivity — Applied",
                body: "Configured gaming speed applied live without persistence",
                trace: trace
            )
        }
    }

    @discardableResult
    private func applyMouseSpeed(
        _ speed: Double,
        operation: String,
        trace: TransitionTrace? = nil
    ) -> Bool {
        trace?.log("\(operation) start")
        let applied = settingsManager.applyMouseSpeed(speed)
        trace?.log(applied ? "\(operation) complete" : "\(operation) failed")
        return applied
    }

    @discardableResult
    private func restoreMouseState(from state: GameModeState, trace: TransitionTrace? = nil) -> Bool {
        guard state.appliedChanges.mouseSpeedChanged,
              let restoreSpeed = resolvedMouseRestoreSpeed(from: state) else {
            updateRuntimeMouseState(isApplied: false, baselineSpeed: nil)
            trace?.log("mouse restore skipped")
            return true
        }

        guard applyMouseSpeed(restoreSpeed, operation: "mouse restore", trace: trace) else {
            updateRuntimeMouseState(
                isApplied: true,
                baselineSpeed: state.appliedChanges.previousMouseSpeed
            )
            return false
        }

        updateRuntimeMouseState(isApplied: false, baselineSpeed: nil)
        return true
    }

    private func registerHotkeys() {
        let hotkeys = configStore.config.hotkeys
        hotkeyManager.register(hotkeys: hotkeys, handlers: [
            "toggleGameMode": { [weak self] in self?.toggleGameModeHotkey() },
            "toggleMouseBoost": { [weak self] in self?.toggleMouseBoostHotkey() },
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
