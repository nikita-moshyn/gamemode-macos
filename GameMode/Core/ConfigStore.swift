//
//  ConfigStore.swift
//  GameMode
//
//  Created by Nikita Moshyn on 11/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation
import Combine

/// Persists `GameModeConfig` to UserDefaults as JSON.
/// Observable for SwiftUI bindings.
class ConfigStore: ObservableObject {

    static let shared = ConfigStore()

    @Published var config: GameModeConfig {
        didSet { save() }
    }

    /// Runtime-only state (not persisted). Observable by SwiftUI views.
    @Published var isGamingMode: Bool = false

    /// Runtime-only state for the active session. Does not trigger config persistence.
    @Published var isMouseBoostApplied: Bool = false
    @Published var sessionMouseBaselineSpeed: Double?
    @Published var isTransitioning = false
    @Published var recoveryRequired = false
    @Published var recoveryMessage: String?
    @Published var configurationLoadError: String?
    @Published var requestedSettingsSection: String?

    let isPreview: Bool
    var preferences: UserDefaults { defaults }

    var canChangeMode: Bool {
        !isTransitioning && !recoveryRequired && configurationLoadError == nil
    }

    /// Live accessibility permission status. Polled while settings window is open.
    @Published var isAccessibilityGranted: Bool = false

    private var accessibilityTimer: Timer?

    private let key: String
    private let defaults: UserDefaults
    private let shortcutDetector: () -> [ShortcutEntry]

    // MARK: - Init

    convenience init() {
        self.init(defaults: .standard)
        isAccessibilityGranted = HotkeyManager.isAccessibilityGranted
    }

    init(defaults: UserDefaults, key: String = "GameModeConfig_v2", isPreview: Bool = false, shortcutDetector: (() -> [ShortcutEntry])? = nil) {
        self.defaults = defaults
        self.key = key
        self.isPreview = isPreview
        self.shortcutDetector = shortcutDetector ?? {
            guard !isPreview else { return [] }
            return AppDetector.detectAvailableShortcuts()
        }
        let initialLog: (level: LogLevel, message: String)
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(GameModeConfig.self, from: data) {
            self.config = decoded
            initialLog = (.debug, "Config loaded from UserDefaults")
        } else {
            let defaultConfig = GameModeConfig.defaults
            self.config = defaultConfig
            if defaults.object(forKey: key) != nil {
                configurationLoadError = "Your saved configuration could not be read. It has been preserved. Reset Saved Configuration to use defaults after resolving any recovery state."
                initialLog = (.error, "Saved configuration is unreadable; original data preserved")
            } else {
                initialLog = (.info, "Using default config (first launch)")
            }
        }
        Log.bootstrap(initialLog.level, initialLog.message, category: "Config", config: config)
    }

    // MARK: - Persistence

    func save() {
        guard configurationLoadError == nil else { return }
        guard let data = try? JSONEncoder().encode(config) else {
            Log.error("Config save failed: could not encode", category: "Config")
            return
        }
        defaults.set(data, forKey: key)
        Log.debug("Config saved", category: "Config")
    }

    func resetAllSavedData() {
        if let original = defaults.object(forKey: key), configurationLoadError != nil {
            defaults.set(original, forKey: "\(key)_unreadable_\(UUID().uuidString)")
        }
        defaults.removeObject(forKey: key)
        configurationLoadError = nil
        config = GameModeConfig.defaults
        isGamingMode = false
        isMouseBoostApplied = false
        sessionMouseBaselineSpeed = nil
        Log.warning("All saved data reset to defaults", category: "Config")
    }

    /// True if this is the first launch (no saved config found).
    var isFirstLaunch: Bool {
        defaults.object(forKey: key) == nil
    }

    // MARK: - App Management

    func addApp(_ app: MonitoredApp) {
        guard !config.monitoredApps.contains(where: { $0.bundleID == app.bundleID }) else {
            Log.debug("Duplicate app skipped: \(app.bundleID)", category: "Config")
            return
        }
        config.monitoredApps.append(app)
        Log.info("App added: \(app.name)", category: "Config")
    }

    func removeApp(id: UUID) {
        config.monitoredApps.removeAll { $0.id == id }
        Log.info("App removed: \(id)", category: "Config")
    }

    func toggleApp(id: UUID) {
        guard let index = config.monitoredApps.firstIndex(where: { $0.id == id }) else { return }
        config.monitoredApps[index].isEnabled.toggle()
    }

    func toggleAppRefreshRateLock(id: UUID) {
        guard let index = config.monitoredApps.firstIndex(where: { $0.id == id }) else { return }
        config.monitoredApps[index].lockRefreshRate.toggle()
    }

    func setManagedDisplay(id: String, name: String, isEnabled: Bool) {
        config.display.setDisplayEnabled(isEnabled, id: id, name: name)
        Log.info("Display preference updated: \(name) (\(id)) => \(isEnabled)", category: "Config")
    }

    // MARK: - Shortcut Management

    func refreshDetectedShortcuts() {
        guard configurationLoadError == nil else { return }
        mergeDetectedShortcuts(shortcutDetector())
    }

    /// Merge detected shortcuts with current config.
    /// Adds new ones (disabled by default), preserves existing toggle state.
    func mergeDetectedShortcuts(_ detected: [ShortcutEntry]) {
        var existingIDs = Set(config.shortcuts.map { $0.id })
        let newEntries = detected.filter { existingIDs.insert($0.id).inserted }
            .map { entry in
                ShortcutEntry(
                    id: entry.id,
                    name: entry.name,
                    category: entry.category,
                    disableInGamingMode: false  // new shortcuts default to off
                )
            }
        if !newEntries.isEmpty {
            config.shortcuts.append(contentsOf: newEntries)
        }
    }

    func toggleShortcut(id: Int) {
        guard let index = config.shortcuts.firstIndex(where: { $0.id == id }) else { return }
        config.shortcuts[index].disableInGamingMode.toggle()
    }

    // MARK: - Gesture Management

    func toggleGesture(id: String) {
        guard let index = config.gestures.firstIndex(where: { $0.id == id }) else { return }
        config.gestures[index].disableInGamingMode.toggle()
    }

    // MARK: - Hotkey Management

    func updateHotkey(id: String, keyCode: UInt16?, modifiers: UInt) {
        guard let index = config.hotkeys.firstIndex(where: { $0.id == id }) else { return }
        config.hotkeys[index].keyCode = keyCode
        config.hotkeys[index].modifiers = modifiers
    }

    func toggleHotkey(id: String) {
        guard let index = config.hotkeys.firstIndex(where: { $0.id == id }) else { return }
        config.hotkeys[index].isEnabled.toggle()
    }

    // MARK: - Accessibility Polling

    /// Start polling `AXIsProcessTrusted()` every 2 seconds.
    /// Call when the settings window opens.
    func startAccessibilityPolling() {
        stopAccessibilityPolling()
        isAccessibilityGranted = HotkeyManager.isAccessibilityGranted
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isAccessibilityGranted = HotkeyManager.isAccessibilityGranted
            }
        }
    }

    /// Stop polling. Call when the settings window closes.
    func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }
}
