//
//  ConfigStore.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2025 Nikita Moshyn. All rights reserved.
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
}
