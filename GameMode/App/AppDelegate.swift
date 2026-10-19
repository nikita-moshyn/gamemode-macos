//
//  AppDelegate.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import Combine
import ComposableArchitecture
import Sparkle
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.arguments.contains("--testing")
    }
    private static let isPreview = ProcessInfo.processInfo.arguments.contains("--ui-preview")
    private lazy var engine = GameEngine()
    private let platformAdapter = AppPlatformAdapter()
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var gameModeItem: NSMenuItem!
    private var mouseItem: NSMenuItem!
    private var recoveryItem: NSMenuItem!
    private var gameModeRow: MenuToggleRow!
    private var mouseRow: MenuToggleRow!
    private var mouseRevealView: MenuRowRevealView!
    private var menuIsOpen = false
    private var statusSymbolName: String?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private let windowPresentation = AppWindowPresentation()
    private lazy var updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var observation: AnyCancellable?

    /// The store outlives every window and menu. Closing UI cannot cancel recovery.
    private lazy var store: StoreOf<GameModeFeature> = {
        let preview = Self.isPreview || Self.isTesting
        let defaults = preview ? UserDefaults(suiteName: "GameMode.Preview.\(UUID().uuidString)")! : .standard
        let preferences = SettingsClient.preferences(defaults, detectShortcuts: { preview ? [] : AppDetector.detectAvailableShortcuts() })
        var initial = preferences.load()
        initial.isPreview = preview
        var platform = platformAdapter.client { [weak self] in self?.perform($0) }
        let clients: (GameEngineClient, GameSessionClient)
        if preview {
            platform.events = { .finished }
            platform.runningBundleIDs = { [] }
            platform.accessibilityGranted = { true }
            platform.configureHotkeys = { _ in }
            clients = (.init(execute: { _, report in await report(.completed(.init())) }, snapshot: { .init() }), .init(transition: { _ in .applied }))
        } else {
            clients = engine.clients { [unowned self] in self.store.state.engineContext }
        }
        return Store(initialState: GameModeFeature.State(settings: initial)) { GameModeFeature() } withDependencies: {
            $0.settingsClient = preferences
            $0.settingsViewClient = preview ? .previewValue : .liveValue
            $0.gameEngine = clients.0
            $0.gameSession = clients.1
            $0.appPlatform = platform
        }
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted tests must never launch the live app or mutate system settings.
        guard !Self.isTesting else { return }
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        observation = store.publisher.removeDuplicates().sink { [weak self] _ in self?.refreshMenu() }
        store.send(.launched)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let settingsWindow, settingsWindow.isVisible, settingsWindow.isKeyWindow else { return }
        store.send(.settingsBecameKey)
    }

    private func perform(_ command: AppPlatformClient.Command) {
        switch command {
        case .showSettings: presentSettings()
        case .showAbout: presentAbout()
        case .reopenWindow: windowPresentation.reopenLastWindow()
        case .start:
            guard !Self.isPreview, !Self.isTesting else { return }
            AppPlatformAdapter.perform(command)
            updaterController.startUpdater()
        case .checkForUpdates: updaterController.checkForUpdates(nil)
        case .resetUpdateCycle: updaterController.updater.resetUpdateCycleAfterShortDelay()
        default:
            guard !Self.isPreview, !Self.isTesting else { return }
            AppPlatformAdapter.perform(command)
        }
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
        let blocked = store.settings.runtime.recoveryRequired || store.settings.configurationLoadError != nil
        let presentation = MenuModePresentation(gameModeEnabled: store.settings.runtime.isGamingMode,
                                                mouseProfileEnabled: store.settings.runtime.isMouseBoostApplied,
                                                isTransitioning: store.settings.runtime.isTransitioning,
                                                gameModeTarget: store.session.desiredMode,
                                                mouseProfileTarget: store.state.visibleMouseTarget,
                                                requiresRecovery: blocked)
        // Leave the native menu structure alone during mouse-profile changes.
        // Action guards and accessibility still reject input while a change is busy.
        let gameAvailable = !blocked
        let mouseAvailable = !blocked && store.settings.runtime.isGamingMode && store.settings.config.mouse.isEnabled
        let hideMouse = !store.settings.runtime.isGamingMode || !store.settings.config.mouse.isEnabled
        if gameModeItem.isEnabled != gameAvailable { gameModeItem.isEnabled = gameAvailable }
        if mouseItem.isEnabled != mouseAvailable { mouseItem.isEnabled = mouseAvailable }
        if recoveryItem.isHidden != !blocked { recoveryItem.isHidden = !blocked }
        gameModeRow.update(isOn: presentation.gameModeSwitchIsOn,
                           isEnabled: gameAvailable, isBusy: store.settings.runtime.isTransitioning, status: presentation.status,
                           shortcut: menuShortcut(id: "toggleGameMode", item: gameModeItem))
        mouseRow.update(isOn: presentation.mouseSwitchIsOn,
                        isEnabled: !blocked, isBusy: store.settings.runtime.isTransitioning || !mouseAvailable,
                        shortcut: menuShortcut(id: "toggleMouseBoost", item: mouseItem))
        mouseRevealView.setExpanded(!hideMouse, animated: menuIsOpen)
        let symbolName = store.settings.runtime.isGamingMode ? "gamecontroller.fill" : "gamecontroller"
        if statusSymbolName != symbolName {
            statusSymbolName = symbolName
            statusItem.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "GameMode")
        }
        statusItem.button?.setAccessibilityLabel("GameMode: \(presentation.status)")
    }

    private func menuShortcut(id: String, item: NSMenuItem) -> String? {
        let hotkey = store.settings.config.hotkeys.first { $0.id == id && $0.isEnabled }
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

    @objc private func toggleGameModeMenuAction() { store.send(.toggleMode(.menu)) }
    @objc private func toggleMouseBoostMenuAction() { store.send(.toggleMouse) }
    @objc private func reviewRecovery() { store.send(.reviewRecovery) }
    @objc func openSettings() { store.send(.settingsRequested) }
    @objc func openAbout() { store.send(.aboutRequested) }
    @objc private func checkForUpdates() { store.send(.command(.checkForUpdates)) }
    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isTesting, !Self.isPreview else { return .terminateNow }
        // The reducer replies after the serialized restore completes. Never block
        // main waiting for a worker: display and power setters themselves need main.
        store.send(.terminationRequested(reply: true))
        return .terminateLater
    }

    private func presentSettings() {
        if settingsWindow == nil {
            let root = SettingsWindow(store: store.scope(state: \.settings, action: \.settings))
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
    }

    @objc private func settingsWindowWillClose(_ notification: Notification) { store.send(.settingsClosed) }

    @objc private func settingsWindowDidBecomeKey(_ notification: Notification) { store.send(.settingsBecameKey) }

    private func presentAbout() {
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
        store.send(.reopenRequested)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Update Channels

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        store.settings.config.allowedUpdateChannels
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        // Recheck consent if the user changed it while the feed was downloading.
        guard let channel = updateItem.channel, !channel.isEmpty else { return }
        guard store.settings.config.allowedUpdateChannels.contains(channel) else {
            throw NSError(domain: "GameMode.UpdateChannels", code: 1, userInfo: [NSLocalizedDescriptionKey: "This update requires Receive beta updates to be enabled in General settings."])
        }
    }

}

extension AppDelegate: SPUUpdaterDelegate {}
