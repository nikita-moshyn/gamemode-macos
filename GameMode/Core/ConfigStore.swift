//
//  ConfigStore.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
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

    /// Live accessibility permission status. Polled while settings window is open.
    @Published var isAccessibilityGranted: Bool = HotkeyManager.isAccessibilityGranted

    private var accessibilityTimer: Timer?

    private let key = "GameModeConfig_v2"
    private let defaults = UserDefaults.standard

    // MARK: - Init

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(GameModeConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = GameModeConfig.defaults
        }
    }

    // MARK: - Persistence

    func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }

    /// True if this is the first launch (no saved config found).
    var isFirstLaunch: Bool {
        defaults.data(forKey: key) == nil
    }

    // MARK: - App Management

    func addApp(_ app: MonitoredApp) {
        guard !config.monitoredApps.contains(where: { $0.bundleID == app.bundleID }) else {
            return
        }
        config.monitoredApps.append(app)
    }

    func removeApp(id: UUID) {
        config.monitoredApps.removeAll { $0.id == id }
    }

    func toggleApp(id: UUID) {
        guard let index = config.monitoredApps.firstIndex(where: { $0.id == id }) else { return }
        config.monitoredApps[index].isEnabled.toggle()
    }

    // MARK: - Shortcut Management

    /// Merge detected shortcuts with current config.
    /// Adds new ones (disabled by default), preserves existing toggle state.
    func mergeDetectedShortcuts(_ detected: [ShortcutEntry]) {
        let existingIDs = Set(config.shortcuts.map { $0.id })
        let newEntries = detected.filter { !existingIDs.contains($0.id) }
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
