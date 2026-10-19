//
//  SettingsClient.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import ConcurrencyExtras
import Foundation

struct SettingsClient: Sendable {
    var load: @Sendable () -> AppSettings.State
    var save: @Sendable (GameModeConfig) throws -> Void
    var reset: @Sendable (GameModeConfig, Bool) throws -> Void
    var detectShortcuts: @Sendable () -> [ShortcutEntry]
    var saveSelectedSection: @Sendable (SettingsSection) -> Void

    static func preferences(_ defaults: UserDefaults, key: String = "GameModeConfig_v2", detectShortcuts: @escaping @Sendable () -> [ShortcutEntry]) -> Self {
        // LockIsolated's initializer takes a Sendable autoclosure, but evaluates
        // it synchronously. All subsequent client access uses its lock.
        nonisolated(unsafe) let initialDefaults = defaults
        let preferences = LockIsolated(initialDefaults)
        return Self(load: {
            preferences.withValue { defaults in
                let section = SettingsSection.resolve(defaults.string(forKey: "GameModeSettingsSection") ?? "general") ?? .general
                var state = AppSettings.State(selectedSection: section)
                guard defaults.object(forKey: key) != nil else { return state }
                state.hasSavedConfiguration = true
                if let data = defaults.data(forKey: key), let config = try? JSONDecoder().decode(GameModeConfig.self, from: data) {
                    state.config = config
                } else {
                    state.configurationLoadError = "Your saved configuration could not be read. It has been preserved. Reset Saved Configuration to use defaults after resolving any recovery state."
                }
                return state
            }
        }, save: { config in
            let data = try JSONEncoder().encode(config)
            preferences.withValue { $0.set(data, forKey: key) }
            Log.bootstrap(.debug, "Config saved", category: "Config", config: config)
        }, reset: { config, preserveUnreadable in
            // Encode first; failure must not remove or overwrite the saved data.
            let data = try JSONEncoder().encode(config)
            preferences.withValue { defaults in
                if preserveUnreadable, let original = defaults.object(forKey: key) {
                    defaults.set(original, forKey: "\(key)_unreadable_\(UUID().uuidString)")
                }
                defaults.set(data, forKey: key)
            }
            Log.bootstrap(.warning, "All saved data reset to defaults", category: "Config", config: config)
        }, detectShortcuts: detectShortcuts, saveSelectedSection: { section in
            preferences.withValue { $0.set(section.rawValue, forKey: "GameModeSettingsSection") }
        })
    }
}

extension SettingsClient: TestDependencyKey {
    static let testValue = Self(load: unimplemented("SettingsClient.load", placeholder: .init()), save: unimplemented("SettingsClient.save"), reset: unimplemented("SettingsClient.reset"), detectShortcuts: unimplemented("SettingsClient.detectShortcuts", placeholder: []), saveSelectedSection: unimplemented("SettingsClient.saveSelectedSection"))
}

extension DependencyValues {
    var settingsClient: SettingsClient {
        get { self[SettingsClient.self] }
        set { self[SettingsClient.self] = newValue }
    }
}
