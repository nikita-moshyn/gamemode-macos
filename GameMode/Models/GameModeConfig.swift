//
//  GameModeConfig.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2025 Nikita Moshyn. All rights reserved.
//

import Foundation

// MARK: - Top-Level Config

struct GameModeConfig: Codable {
    var monitoredApps: [MonitoredApp]
    var shortcuts: [ShortcutEntry]
    var functionKeysInGamingMode: Bool
    var mouse: MouseConfig
    var system: SystemConfig

    static var defaults: GameModeConfig {
        GameModeConfig(
            monitoredApps: MonitoredApp.presets,
            shortcuts: ShortcutEntry.defaults,
            functionKeysInGamingMode: true,
            mouse: MouseConfig(),
            system: SystemConfig()
        )
    }
}

// MARK: - Mouse

struct MouseConfig: Codable {
    /// Master switch — when false, mouse is never touched and menu toggle is hidden.
    var isEnabled: Bool = true
    var gamingSpeed: Double = 3.0
    var normalSpeed: Double = 0.5
    /// Speed read from system before gaming mode activation.
    var capturedSystemSpeed: Double?
    /// If true, reads live speed before each activation and restores that exact value.
    var autoCapture: Bool = true
    /// Whether the user wants gaming mouse speed (independent of game mode state).
    var isMouseBoostEnabled: Bool = false
}

// MARK: - System Safety

struct SystemConfig: Codable {
    /// Deactivate gaming mode before macOS shuts down or restarts.
    var restoreOnShutdown: Bool = true
    /// Auto-restore settings on launch if the app was killed while gaming mode was active.
    var restoreOnLaunch: Bool = true
}
