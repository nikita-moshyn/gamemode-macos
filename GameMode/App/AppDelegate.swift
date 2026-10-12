//
//  AppDelegate.swift
//  GameMode
//
//  Created by Nikita Moshyn on 11/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import Combine
import Carbon
import Sparkle
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.arguments.contains("--testing")
    }
    private static let isPreview = ProcessInfo.processInfo.arguments.contains("--ui-preview")
    private static let settingsQueue = DispatchQueue(label: "com.nikita.GameMode.settings", qos: .userInitiated)
    private let transitionStateQueue = DispatchQueue(label: "com.nikita.GameMode.transitionState")
    private let configStore: ConfigStore = {
        if AppDelegate.isTesting || AppDelegate.isPreview {
            return ConfigStore(defaults: UserDefaults(suiteName: "GameMode.Preview.\(UUID().uuidString)")!, isPreview: true)
        }
        return .shared
    }()
    private let settingsManager = SettingsManager()
    private let refreshRateLock = RefreshRateLock()
    private let hotkeyManager = HotkeyManager()
    private var appMonitor: AppMonitor?
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var gameModeItem: NSMenuItem!
    private var mouseItem: NSMenuItem!
    private var recoveryItem: NSMenuItem!
    private var gameModeRow: MenuToggleRow!
    private var mouseRow: MenuToggleRow!
    private var mouseRevealView: MenuRowRevealView!
    private var menuIsOpen = false
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private let windowPresentation = AppWindowPresentation()
    private lazy var updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var cancellables = Set<AnyCancellable>()
    private var targetGameModeState = false
    private var appliedGameModeState = false
    private var isProcessingGameModeTransitions = false
    private var isProcessingMouseChange = false
    private var isProcessingInputGuardChange = false
    private var inputGuardUpdatePending = false
    private var recoveryReady = false
    private var isTerminating = false
    private var transitionSequence: UInt64 = 0
    private var visibleTarget = false
    private var visibleMouseTarget: Bool?
    private var statusSymbolName: String?
    private var needsInitialAppScan = true

    private lazy var recovery = RecoveryController(journal: .shared, operations: .init(
        stopDisplays: { [unowned self] in self.refreshRateLock.stop().failedDisplays },
        restoreDisplays: { [unowned self] in self.refreshRateLock.restorePersistedDisplayModes($0) },
        restoreKeyboard: { [unowned self] in self.settingsManager.restoreKeyboardSettings(from: $0) },
        restorePower: { PowerManager.restoreLowPowerModeSettings($0) },
        readMouse: { [unowned self] in self.settingsManager.readCurrentMouseSpeed() },
        applyMouse: { [unowned self] in self.settingsManager.applyMouseSpeed($0) }
    ))

    private struct TransitionTrace {
        let id: UInt64
        let name: String
        private let startedAt = CFAbsoluteTimeGetCurrent()
        func log(_ message: String) {
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            Log.debug("[\(name)#\(id)] \(message) (+\(String(format: "%.3f", elapsed))s)", category: "GameMode")
        }
    }

    private struct DisplayRefreshPolicyState: Equatable {
        let isEnabled: Bool
        let manageBuiltInProMotionDisplay: Bool
        let manageExternalDisplays: Bool
        let preferExactModeSwitching: Bool
        let allowOverlayFallback: Bool
        let managedDisplays: [ManagedDisplayPreference]
        init(config: DisplayConfig) {
            isEnabled = config.isRefreshRateLockEnabled
            manageBuiltInProMotionDisplay = config.manageBuiltInProMotionDisplay
            manageExternalDisplays = config.manageExternalDisplays
            preferExactModeSwitching = config.preferExactModeSwitching
            allowOverlayFallback = config.allowOverlayFallback
            managedDisplays = config.managedDisplays
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted XCTest must never run recovery, monitors, permissions, or setters.
        guard !Self.isTesting else { return }
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        if Self.isPreview {
            configStore.isAccessibilityGranted = true
            openSettings()
            return
        }
        configStore.isTransitioning = true
        ProcessInfo.processInfo.disableSuddenTermination()
        installDisplayCheckpoints()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if configStore.isFirstLaunch {
            configStore.refreshDetectedShortcuts()
            AppDetector.scanForGames().forEach { configStore.addApp($0) }
        }
        appMonitor = AppMonitor(configStore: configStore,
                                onActivate: { [weak self] in self?.requestGameModeTransition(to: true, source: "automatic") },
                                onDeactivate: { [weak self] in self?.requestGameModeTransition(to: false, source: "automatic") },
                                onMonitoredAppLaunched: { [weak self] _ in self?.refreshDisplayPolicyForRunningApps() },
                                onMonitoredAppTerminated: { [weak self] _ in self?.refreshDisplayPolicyForRunningApps() })
        if !HotkeyManager.isAccessibilityGranted { HotkeyManager.requestAccessibilityPermission() }
        registerHotkeys()
        observeConfigurationChanges()
        updaterController.startUpdater()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillPowerOff), name: NSWorkspace.willPowerOffNotification, object: nil)
        recoverIfNeeded(isStartup: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let settingsWindow, settingsWindow.isVisible, settingsWindow.isKeyWindow else { return }
        configStore.refreshDetectedShortcuts()
    }

    private func installDisplayCheckpoints() {
        refreshRateLock.willChangeDisplay = { record in
            let state = try StateJournal.shared.load()
            if let existing = state.appliedChanges.displayRestores.first(where: { $0.displayUUID == record.displayUUID }) {
                guard existing == record else { throw JournalError.changedBaseline }
                return
            }
            try StateJournal.shared.update { $0.appliedChanges.displayRestores.append(record) }
        }
        refreshRateLock.didRestoreDisplay = { uuid in
            try StateJournal.shared.update { $0.appliedChanges.displayRestores.removeAll { $0.displayUUID == uuid } }
        }
    }

    private func observeConfigurationChanges() {
        ShortcutRecordingSession.shared.$activeID.removeDuplicates().sink { [weak self] recorder in
            guard let self else { return }
            if recorder != nil { self.hotkeyManager.unregisterAll() }
            else { self.registerHotkeys() }
        }.store(in: &cancellables)
        configStore.$config.map(\.mouse.isEnabled).removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.refreshMenu()
                if !enabled { self?.restoreDisabledMouseProfile() }
            }.store(in: &cancellables)
        configStore.$config.map(\.inputGuardPolicy).removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateInputGuardForCurrentSession() }
            .store(in: &cancellables)
        configStore.$config.map(\.monitoredApps).removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDisplayPolicyForRunningApps() }
            .store(in: &cancellables)
        configStore.$config.map { DisplayRefreshPolicyState(config: $0.display) }.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.configStore.canChangeMode,
                      self.transitionStateQueue.sync(execute: { self.appliedGameModeState && self.recoveryReady }) else { return }
                Self.settingsQueue.async { [weak self] in
                    guard let self else { return }
                    guard self.transitionStateQueue.sync(execute: { self.recoveryReady && self.appliedGameModeState && !self.isTerminating }) else { return }
                    let result = self.applyDisplayRefreshPolicy(config: self.currentConfigSnapshot())
                    if !result.failedDisplays.isEmpty { self.reportRecoveryFailure(result.failedDisplays.joined(separator: "\n")) }
                }
            }.store(in: &cancellables)
    }

    // MARK: - Persistent Native Menu

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        gameModeRow = MenuToggleRow(title: "Game Mode", showsStatus: true)
        gameModeRow.onToggle = { [weak self] in self?.toggleGameModeMenuAction() }
        gameModeItem = NSMenuItem(title: "Game Mode", action: #selector(toggleGameModeMenuAction), keyEquivalent: "")
        gameModeItem.target = self
        gameModeItem.view = gameModeRow
        menu.addItem(gameModeItem)
        mouseRow = MenuToggleRow(title: "Mouse Preset", showsStatus: false)
        mouseRow.onToggle = { [weak self] in self?.toggleMouseBoostMenuAction() }
        mouseItem = NSMenuItem(title: "Mouse Preset", action: #selector(toggleMouseBoostMenuAction), keyEquivalent: "")
        mouseItem.target = self
        mouseRevealView = MenuRowRevealView(row: mouseRow, item: mouseItem)
        menu.addItem(mouseItem)
        recoveryItem = addMenuItem("Review Recovery…", action: #selector(reviewRecovery))
        menu.addItem(.separator())
        let settings = addMenuItem("Settings…", action: #selector(openSettings), key: ",")
        settings.keyEquivalentModifierMask = .command
        menu.addItem(.separator())
        _ = addMenuItem("About GameMode", action: #selector(openAbout))
        _ = addMenuItem("Check for Updates…", action: #selector(checkForUpdates))
        menu.addItem(.separator())
        let quit = addMenuItem("Quit GameMode", action: #selector(quitApp), key: "q")
        quit.keyEquivalentModifierMask = .command
        statusItem.menu = menu
        refreshMenu()
    }

    private func addMenuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func refreshMenu() {
        guard menu != nil else { return }
        let blocked = configStore.recoveryRequired || configStore.configurationLoadError != nil
        let presentation = MenuModePresentation(gameModeEnabled: configStore.isGamingMode,
                                                mouseProfileEnabled: configStore.isMouseBoostApplied,
                                                isTransitioning: configStore.isTransitioning,
                                                gameModeTarget: visibleTarget,
                                                mouseProfileTarget: visibleMouseTarget,
                                                requiresRecovery: blocked)
        // Leave the native menu structure alone during mouse-profile changes.
        // Action guards and accessibility still reject input while a change is busy.
        let gameAvailable = !blocked
        let mouseAvailable = !blocked && configStore.isGamingMode && configStore.config.mouse.isEnabled
        let hideMouse = !configStore.isGamingMode || !configStore.config.mouse.isEnabled
        if gameModeItem.isEnabled != gameAvailable { gameModeItem.isEnabled = gameAvailable }
        if mouseItem.isEnabled != mouseAvailable { mouseItem.isEnabled = mouseAvailable }
        if recoveryItem.isHidden != !blocked { recoveryItem.isHidden = !blocked }
        gameModeRow.update(isOn: presentation.gameModeSwitchIsOn,
                           isEnabled: gameAvailable, isBusy: configStore.isTransitioning, status: presentation.status,
                           shortcut: menuShortcut(id: "toggleGameMode", item: gameModeItem))
        mouseRow.update(isOn: presentation.mouseSwitchIsOn,
                        isEnabled: !blocked, isBusy: configStore.isTransitioning || !mouseAvailable,
                        shortcut: menuShortcut(id: "toggleMouseBoost", item: mouseItem))
        mouseRevealView.setExpanded(!hideMouse, animated: menuIsOpen)
        let symbolName = configStore.isGamingMode ? "gamecontroller.fill" : "gamecontroller"
        if statusSymbolName != symbolName {
            statusSymbolName = symbolName
            statusItem.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "GameMode")
        }
        statusItem.button?.setAccessibilityLabel("GameMode: \(presentation.status)")
    }

    private func menuShortcut(id: String, item: NSMenuItem) -> String? {
        let hotkey = configStore.config.hotkeys.first { $0.id == id && $0.isEnabled }
        let equivalent = hotkey?.keyCode.flatMap { KeyCodeMap.menuKeyEquivalent(for: $0) } ?? ""
        let modifiers: NSEvent.ModifierFlags = equivalent.isEmpty ? [] : NSEvent.ModifierFlags(rawValue: hotkey?.modifiers ?? 0).intersection(.deviceIndependentFlagsMask)
        if item.keyEquivalent != equivalent { item.keyEquivalent = equivalent }
        if item.keyEquivalentModifierMask != modifiers { item.keyEquivalentModifierMask = modifiers }
        return equivalent.isEmpty ? nil : hotkey?.displayString
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        gameModeRow.setMenuHighlighted(item === gameModeItem, clearPointer: item != nil && item !== gameModeItem)
        mouseRow.setMenuHighlighted(item === mouseItem, clearPointer: item != nil && item !== mouseItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        mouseRevealView.finishAnimation()
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        mouseRevealView.finishAnimation()
        gameModeRow.setMenuHighlighted(false, clearPointer: true)
        mouseRow.setMenuHighlighted(false, clearPointer: true)
    }

    // MARK: - Serialized Transitions

    private func requestGameModeTransition(to desiredState: Bool, source: String) {
        if !Thread.isMainThread {
            onMain { [weak self] in self?.requestGameModeTransition(to: desiredState, source: source) }
            return
        }
        if Self.isPreview {
            configStore.isGamingMode = desiredState
            if !desiredState { configStore.isMouseBoostApplied = false }
            refreshMenu()
            return
        }
        guard configStore.configurationLoadError == nil,
              transitionStateQueue.sync(execute: { recoveryReady && !isTerminating }) else { return }
        if source != "automatic" && configStore.isTransitioning { return }
        visibleTarget = desiredState
        configStore.isTransitioning = true
        let shouldProcess = transitionStateQueue.sync { () -> Bool in
            targetGameModeState = desiredState
            guard !isProcessingGameModeTransitions else { return false }
            isProcessingGameModeTransitions = true
            return true
        }
        refreshMenu()
        if shouldProcess { Self.settingsQueue.async { [weak self] in self?.processPendingGameModeTransitions() } }
    }

    private func processPendingGameModeTransitions() {
        while let transition = nextPendingGameModeTransition() {
            do {
                if transition.desiredState { try performGameModeActivation(trace: transition.trace) }
                else { try recovery.restore() }
                transitionStateQueue.sync { appliedGameModeState = transition.desiredState }
                publishAppliedState(transition.desiredState)
                enqueueNotification(title: transition.desiredState ? "Game Mode — Enabled" : "Game Mode — Disabled",
                                    body: transition.desiredState ? "Your gaming settings are active." : "Your original settings were restored.")
            } catch {
                reportRecoveryFailure(error.localizedDescription)
                transitionStateQueue.sync {
                    targetGameModeState = appliedGameModeState
                    isProcessingGameModeTransitions = false
                }
                return
            }
        }
        finishPresentationTransition()
    }

    private func finishPresentationTransition() {
        onMain { [weak self] in
            guard let self else { return }
            self.configStore.isTransitioning = self.transitionStateQueue.sync {
                self.isProcessingGameModeTransitions || self.isProcessingMouseChange || self.isProcessingInputGuardChange
            }
            self.refreshMenu()
        }
    }

    private func nextPendingGameModeTransition() -> (desiredState: Bool, trace: TransitionTrace)? {
        transitionStateQueue.sync {
            guard recoveryReady, appliedGameModeState != targetGameModeState else {
                isProcessingGameModeTransitions = false
                return nil
            }
            transitionSequence += 1
            return (targetGameModeState, TransitionTrace(id: transitionSequence, name: targetGameModeState ? "GameModeOn" : "GameModeOff"))
        }
    }

    private func performGameModeActivation(trace: TransitionTrace) throws {
        let config = currentConfigSnapshot()
        let policy = config.inputGuardPolicy
        let snapshot = settingsManager.captureKeyboardSettings(functionKeysEnabled: policy.functionKeysEnabled,
                                                               shortcutIDs: policy.shortcutIDs,
                                                               gestures: policy.gestures)
        let shouldDisablePower = config.display.autoDisableLowPowerMode && PowerManager.isLowPowerModeEnabled
            && PowerManager.isBatteryAboveThreshold(config.display.lowPowerModeBatteryThreshold)
        let power = shouldDisablePower ? PowerManager.captureLowPowerModeSettings() : nil
        let state = GameModeState(isActive: true, activatedAt: Date(), appliedChanges: AppliedChanges(
            functionKeysChanged: snapshot.functionKeysChanged,
            previousFunctionKeysEnabled: snapshot.previousFunctionKeysEnabled,
            disabledShortcutIDs: snapshot.shortcutIDsToDisable,
            previousShortcutStates: snapshot.previousShortcutStates,
            mouseSpeedChanged: false, previousMouseSpeed: nil,
            gesturesChanged: !snapshot.gesturesToDisable.isEmpty,
            previousGestureValues: snapshot.previousGestureValues,
            lowPowerModeChanged: power != nil, previousLowPowerModeEnabled: nil,
            previousLowPowerModeSettings: power
        ))
        try recovery.activate(state) {
            trace.log("recovery checkpoint committed")
            try settingsManager.applyKeyboardSettings(snapshot)
            // Existing setters retain their order: keyboard, power, mouse, display.
            if power != nil && !PowerManager.setLowPowerMode(enabled: false) {
                throw RecoveryController.Failure.message("Low Power Mode could not be changed. Retry recovery to restore the saved settings.")
            }
            if config.mouse.isEnabled && config.mouse.isMouseBoostEnabled {
                try recovery.applyMouseProfile(speed: config.mouse.gamingSpeed)
            }
            let isDeactivationPending = transitionStateQueue.sync { !targetGameModeState }
            if !isDeactivationPending {
                let result = applyDisplayRefreshPolicy(config: config)
                if !result.failedDisplays.isEmpty {
                    throw RecoveryController.Failure.message(result.failedDisplays.joined(separator: "\n"))
                }
            }
        }
        trace.log("activation complete")
    }

    private func currentConfigSnapshot() -> GameModeConfig {
        if Thread.isMainThread { return configStore.config }
        return DispatchQueue.main.sync { configStore.config }
    }

    private func publishAppliedState(_ active: Bool) {
        let state = try? StateJournal.shared.load()
        onMain { [weak self] in
            guard let self else { return }
            self.configStore.isGamingMode = active
            self.configStore.isMouseBoostApplied = active && state?.appliedChanges.mouseSpeedChanged == true
            self.configStore.sessionMouseBaselineSpeed = state?.appliedChanges.previousMouseSpeed
            self.refreshMenu()
        }
    }

    private func reportRecoveryFailure(_ message: String) {
        transitionStateQueue.sync { recoveryReady = false }
        Log.error(message, category: "Recovery")
        onMain { [weak self] in
            self?.configStore.isTransitioning = false
            self?.configStore.recoveryRequired = true
            self?.configStore.recoveryMessage = message
            self?.refreshMenu()
        }
    }

    // MARK: - Display Policy (existing selection and application behavior)

    private func refreshDisplayPolicyForRunningApps() {
        // Queue changes even while another setting is in flight. The first app's
        // activation applies displays itself; avoid restarting that same effect.
        Self.settingsQueue.async { [weak self] in
            guard let self, self.transitionStateQueue.sync(execute: {
                self.recoveryReady && self.appliedGameModeState && self.targetGameModeState && !self.isTerminating
            }) else { return }
            let result = self.applyDisplayRefreshPolicy(config: self.currentConfigSnapshot(), onlyIfActivationChanged: true)
            if !result.failedDisplays.isEmpty { self.reportRecoveryFailure(result.failedDisplays.joined(separator: "\n")) }
        }
    }

    private func applyDisplayRefreshPolicy(config: GameModeConfig, onlyIfActivationChanged: Bool = false) -> DisplayRefreshActivationResult {
        // AppMonitor and the display engine own their runtime state on main.
        let runtimeState = DispatchQueue.main.sync {
            (needsRefresh: self.appMonitor?.anyActiveAppNeedsRefreshRateLock() == true, isDisplayActive: self.refreshRateLock.isActive)
        }
        let shouldApply = config.display.isRefreshRateLockEnabled && runtimeState.needsRefresh
        if onlyIfActivationChanged && shouldApply == runtimeState.isDisplayActive { return DisplayRefreshActivationResult() }
        guard shouldApply else {
            if runtimeState.isDisplayActive {
                let restored = refreshRateLock.stop()
                var result = DisplayRefreshActivationResult()
                result.failedDisplays = restored.failedDisplays
                return result
            }
            return DisplayRefreshActivationResult()
        }
        return refreshRateLock.start(config: config.display)
    }

    // MARK: - Input Guard

    private func updateInputGuardForCurrentSession() {
        guard !Self.isPreview, !Self.isTesting, configStore.configurationLoadError == nil, !configStore.recoveryRequired else { return }
        let shouldProcess = transitionStateQueue.sync {
            guard recoveryReady, appliedGameModeState, !isTerminating else { return false }
            inputGuardUpdatePending = true
            guard !isProcessingInputGuardChange else { return false }
            isProcessingInputGuardChange = true
            return true
        }
        guard shouldProcess else { return }
        configStore.isTransitioning = true
        refreshMenu()
        Self.settingsQueue.async { [weak self] in
            guard let self else { return }
            while self.takePendingInputGuardUpdate() {
                do {
                    try self.recovery.updateInputGuard(self.currentConfigSnapshot().inputGuardPolicy, capture: { policy in
                        self.settingsManager.captureKeyboardSettings(functionKeysEnabled: policy.functionKeysEnabled,
                                                                     shortcutIDs: policy.shortcutIDs, gestures: policy.gestures)
                    }, apply: { try self.settingsManager.applyKeyboardSettings($0) })
                } catch {
                    self.transitionStateQueue.sync {
                        self.inputGuardUpdatePending = false
                        self.isProcessingInputGuardChange = false
                    }
                    self.reportRecoveryFailure(error.localizedDescription)
                    return
                }
            }
            self.finishPresentationTransition()
        }
    }

    private func takePendingInputGuardUpdate() -> Bool {
        transitionStateQueue.sync {
            guard inputGuardUpdatePending, recoveryReady, appliedGameModeState, targetGameModeState, !isTerminating else {
                inputGuardUpdatePending = false
                isProcessingInputGuardChange = false
                return false
            }
            inputGuardUpdatePending = false
            return true
        }
    }

    // MARK: - Mouse Profile

    @objc private func toggleGameModeMenuAction() {
        requestGameModeTransition(to: !configStore.isGamingMode, source: "menu")
    }

    @objc private func toggleMouseBoostMenuAction() { changeMouseProfile(apply: !configStore.isMouseBoostApplied) }

    private func applyConfiguredMouseSpeedLive() { changeMouseProfile(apply: true) }

    private func changeMouseProfile(apply: Bool) {
        guard configStore.canChangeMode, configStore.isGamingMode, configStore.config.mouse.isEnabled else { return }
        if Self.isPreview {
            configStore.isMouseBoostApplied = apply
            refreshMenu()
            return
        }
        configStore.isTransitioning = true
        visibleTarget = configStore.isGamingMode
        visibleMouseTarget = apply
        transitionStateQueue.sync { isProcessingMouseChange = true }
        refreshMenu()
        Self.settingsQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.transitionStateQueue.sync { self.isProcessingMouseChange = false }
                self.onMain {
                    self.visibleMouseTarget = nil
                    self.finishPresentationTransition()
                }
            }
            guard self.transitionStateQueue.sync(execute: { self.recoveryReady && self.appliedGameModeState && !self.isTerminating }) else { return }
            do {
                if apply { try self.recovery.applyMouseProfile(speed: self.currentConfigSnapshot().mouse.gamingSpeed) }
                else { try self.recovery.restoreMouseProfile() }
                self.publishAppliedState(true)
            } catch { self.reportRecoveryFailure(error.localizedDescription) }
        }
    }

    private func restoreDisabledMouseProfile() {
        guard !Self.isPreview else { configStore.isMouseBoostApplied = false; refreshMenu(); return }
        Self.settingsQueue.async { [weak self] in
            guard let self, self.transitionStateQueue.sync(execute: { self.recoveryReady && self.appliedGameModeState }) else { return }
            do {
                try self.recovery.restoreMouseProfile()
                self.publishAppliedState(true)
            } catch { self.reportRecoveryFailure(error.localizedDescription) }
        }
    }

    // MARK: - Recovery and Shutdown

    private func recoverIfNeeded(isStartup: Bool = false) {
        guard !Self.isPreview else { return }
        let autoRestore = configStore.config.system.restoreOnLaunch
        transitionStateQueue.sync { recoveryReady = false }
        configStore.isTransitioning = true
        visibleTarget = false
        refreshMenu()
        Self.settingsQueue.async { [weak self] in
            guard let self else { return }
            do {
                if isStartup { try self.recovery.prepareForLaunch(restoreAutomatically: autoRestore) }
                else { try self.recovery.restore() }
                self.finishRecovery(recheckApps: true)
            } catch { self.reportRecoveryFailure(error.localizedDescription) }
        }
    }

    private func finishRecovery(recheckApps: Bool) {
        refreshRateLock.resumeAutomaticRecovery()
        transitionStateQueue.sync {
            recoveryReady = true
            appliedGameModeState = false
            targetGameModeState = false
            isProcessingGameModeTransitions = false
        }
        onMain { [weak self] in
            guard let self else { return }
            self.configStore.recoveryRequired = false
            self.configStore.recoveryMessage = "No settings are waiting for recovery."
            self.configStore.isTransitioning = false
            self.configStore.isGamingMode = false
            self.configStore.isMouseBoostApplied = false
            self.configStore.sessionMouseBaselineSpeed = nil
            self.refreshMenu()
            if self.configStore.configurationLoadError == nil {
                let activateIfRunning = recheckApps && self.needsInitialAppScan
                self.needsInitialAppScan = false
                self.appMonitor?.checkRunningApps(activateIfRunning: activateIfRunning)
            }
        }
    }

    func forceRestoreAllSettings() {
        guard !configStore.isTransitioning else { return }
        recoverIfNeeded()
    }

    private func acceptCurrentSettings() {
        guard !configStore.isTransitioning else { return }
        if Self.isPreview { configStore.recoveryRequired = false; configStore.recoveryMessage = nil; refreshMenu(); return }
        transitionStateQueue.sync { recoveryReady = false }
        configStore.isTransitioning = true
        refreshMenu()
        Self.settingsQueue.async { [weak self] in
            guard let self else { return }
            self.refreshRateLock.pauseAutomaticRecovery()
            do {
                try self.recovery.acceptCurrentSettings()
                self.refreshRateLock.abandonCurrentSession()
                self.settingsManager.stopOwnedEffects()
                self.finishRecovery(recheckApps: false)
            } catch {
                // The clean manifest may have committed before a final flush error.
                // Keep automatic retries paused until an explicit action resolves it.
                self.reportRecoveryFailure(error.localizedDescription)
            }
        }
    }

    func resetAllSavedData() {
        guard !configStore.isTransitioning else { return }
        if Self.isPreview { configStore.resetAllSavedData(); refreshMenu(); return }
        transitionStateQueue.sync { recoveryReady = false }
        configStore.isTransitioning = true
        refreshMenu()
        Self.settingsQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.recovery.reset()
                self.onMain {
                    self.configStore.resetAllSavedData()
                    self.registerHotkeys()
                }
                self.finishRecovery(recheckApps: false)
            } catch { self.reportRecoveryFailure(error.localizedDescription) }
        }
    }

    @objc private func systemWillPowerOff() {
        guard !Self.isTesting, !Self.isPreview else { return }
        transitionStateQueue.sync { isTerminating = true; targetGameModeState = false }
        guard configStore.config.system.restoreOnShutdown else { return }
        Self.settingsQueue.async { [weak self] in
            do { try self?.recovery.restore() }
            catch { self?.reportRecoveryFailure(error.localizedDescription) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isTesting, !Self.isPreview else { return .terminateNow }
        transitionStateQueue.sync { isTerminating = true; targetGameModeState = false }
        guard configStore.config.system.restoreOnShutdown else { return .terminateNow }
        // Do not synchronously wait on the worker from main: power/display setters need main.
        Self.settingsQueue.async { [weak self] in
            do { try self?.recovery.restore() }
            catch { Log.error("Termination left recovery pending: \(error.localizedDescription)", category: "Recovery") }
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - Windows

    @objc private func reviewRecovery() {
        configStore.requestedSettingsSection = "system"
        openSettings()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let root = SettingsWindow(configStore: configStore,
                                      onApplyConfiguredMouseSpeed: { [weak self] in self?.applyConfiguredMouseSpeedLive() },
                                      onForceRestore: { [weak self] in self?.forceRestoreAllSettings() },
                                      onResetAllSavedData: { [weak self] in self?.resetAllSavedData() },
                                      onHotkeysChanged: { [weak self] in self?.registerHotkeys() },
                                      onAcceptCurrentSettings: { [weak self] in self?.acceptCurrentSettings() },
                                      onCheckForUpdates: { [weak self] in self?.checkForUpdates() })
                .defaultAppStorage(configStore.preferences)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "GameMode Settings"
            window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbar = NSToolbar(identifier: "GameModeSettingsToolbar")
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 820, height: 600))
            window.contentMinSize = NSSize(width: 720, height: 500)
            window.isReleasedWhenClosed = false
            window.center()
            if !Self.isPreview {
                window.setFrameAutosaveName("GameModeSettings")
                window.setFrameUsingName("GameModeSettings")
            }
            settingsWindow = window
            NotificationCenter.default.addObserver(self, selector: #selector(settingsWindowWillClose), name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(settingsWindowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
        }
        if let settingsWindow { windowPresentation.show(settingsWindow) }
        if !Self.isPreview { configStore.startAccessibilityPolling() }
    }

    @objc private func settingsWindowWillClose(_ notification: Notification) { configStore.stopAccessibilityPolling() }

    @objc private func settingsWindowDidBecomeKey(_ notification: Notification) { configStore.refreshDetectedShortcuts() }

    @objc func openAbout() {
        if aboutWindow == nil {
            let hostingController = NSHostingController(rootView: AboutView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "About GameMode"
            window.styleMask = [.titled, .closable]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.setContentSize(hostingController.view.fittingSize)
            window.isReleasedWhenClosed = false
            window.center()
            aboutWindow = window
        }
        if let aboutWindow { windowPresentation.show(aboutWindow) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowPresentation.reopenLastWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func checkForUpdates() {
        guard !Self.isPreview else { return }
        updaterController.checkForUpdates(nil)
    }

    private func registerHotkeys() {
        if !Self.isPreview && !Self.isTesting {
            hotkeyManager.register(hotkeys: configStore.config.hotkeys, handlers: [
                "toggleGameMode": { [weak self] in
                    guard let self else { return }
                    self.requestGameModeTransition(to: !self.configStore.isGamingMode, source: "hotkey")
                },
                "toggleMouseBoost": { [weak self] in self?.toggleMouseBoostMenuAction() },
                "toggleInputSource": { [weak self] in self?.toggleInputSource() }
            ])
        }
        refreshMenu()
    }

    /// Main-run-loop updates also execute while a native menu is tracking.
    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() }
        else { RunLoop.main.perform(inModes: [.common, .eventTracking], block: action) }
    }

    private func enqueueNotification(title: String, body: String) {
        guard !Self.isTesting, !Self.isPreview else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    private func toggleInputSource() {
        // Use Carbon TIS API to cycle to the next input source
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource],
              sourceList.count >= 2 else {
            Log.warning("Cannot toggle input source: fewer than 2 sources available", category: "Hotkeys")
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
            Log.warning("Fewer than 2 selectable input sources", category: "Hotkeys")
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
        Log.info("Switched input source", category: "Hotkeys")
    }


}
