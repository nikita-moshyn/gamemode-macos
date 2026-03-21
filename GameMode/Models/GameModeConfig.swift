//
//  GameModeConfig.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

// MARK: - Top-Level Config

struct GameModeConfig: Codable {
    var monitoredApps: [MonitoredApp]
    var shortcuts: [ShortcutEntry]
    var functionKeysInGamingMode: Bool
    var mouse: MouseConfig
    var system: SystemConfig
    var gestures: [GestureEntry]
    var hotkeys: [AppHotkey]

    static var defaults: GameModeConfig {
        GameModeConfig(
            monitoredApps: MonitoredApp.presets,
            shortcuts: ShortcutEntry.defaults,
            functionKeysInGamingMode: true,
            mouse: MouseConfig(),
            system: SystemConfig(),
            gestures: GestureEntry.defaults,
            hotkeys: AppHotkey.defaults
        )
    }

    // Migration-safe decoder: older configs won't have gestures/hotkeys fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monitoredApps = try container.decode([MonitoredApp].self, forKey: .monitoredApps)
        shortcuts = try container.decode([ShortcutEntry].self, forKey: .shortcuts)
        functionKeysInGamingMode = try container.decode(Bool.self, forKey: .functionKeysInGamingMode)
        mouse = try container.decode(MouseConfig.self, forKey: .mouse)
        system = try container.decode(SystemConfig.self, forKey: .system)
        gestures = try container.decodeIfPresent([GestureEntry].self, forKey: .gestures) ?? GestureEntry.defaults
        hotkeys = try container.decodeIfPresent([AppHotkey].self, forKey: .hotkeys) ?? AppHotkey.defaults
    }

    init(monitoredApps: [MonitoredApp], shortcuts: [ShortcutEntry], functionKeysInGamingMode: Bool,
         mouse: MouseConfig, system: SystemConfig,
         gestures: [GestureEntry] = GestureEntry.defaults,
         hotkeys: [AppHotkey] = AppHotkey.defaults) {
        self.monitoredApps = monitoredApps
        self.shortcuts = shortcuts
        self.functionKeysInGamingMode = functionKeysInGamingMode
        self.mouse = mouse
        self.system = system
        self.gestures = gestures
        self.hotkeys = hotkeys
    }
}

// MARK: - Mouse

struct MouseConfig: Codable {
    /// Master switch — when false, mouse is never touched and menu toggle is hidden.
    var isEnabled: Bool = true
    var gamingSpeed: Double = 0.5
    /// Whether gaming mode should auto-enable mouse boost on activation.
    var isMouseBoostEnabled: Bool = false

    init(isEnabled: Bool = true, gamingSpeed: Double = 0.5, isMouseBoostEnabled: Bool = false) {
        self.isEnabled = isEnabled
        self.gamingSpeed = gamingSpeed
        self.isMouseBoostEnabled = isMouseBoostEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        gamingSpeed = try container.decodeIfPresent(Double.self, forKey: .gamingSpeed) ?? 0.5
        isMouseBoostEnabled = try container.decodeIfPresent(Bool.self, forKey: .isMouseBoostEnabled) ?? false
    }
}

// MARK: - System Safety

struct SystemConfig: Codable {
    /// Deactivate gaming mode before macOS shuts down or restarts.
    var restoreOnShutdown: Bool = true
    /// Auto-restore settings on launch if the app was killed while gaming mode was active.
    var restoreOnLaunch: Bool = true
}
