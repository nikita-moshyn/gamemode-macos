//
//  GameModeConfig.swift
//  GameMode
//
//  Created by Nikita Moshyn on 11/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

// MARK: - Top-Level Config

struct GameModeConfig: Codable {
    var monitoredApps: [MonitoredApp]
    var shortcuts: [ShortcutEntry]
    var functionKeysInGamingMode: Bool
    var isInputGuardEnabled: Bool
    var mouse: MouseConfig
    var system: SystemConfig
    var gestures: [GestureEntry]
    var hotkeys: [AppHotkey]
    var display: DisplayConfig
    var loggingEnabled: Bool
    var logLevel: LogLevel

    /// The master switch gates effects without clearing the user's selections.
    var inputGuardPolicy: InputGuardPolicy {
        guard isInputGuardEnabled else { return .disabled }
        return InputGuardPolicy(functionKeysEnabled: functionKeysInGamingMode,
                                shortcutIDs: shortcuts.filter(\.disableInGamingMode).map(\.id),
                                gestures: gestures.filter(\.disableInGamingMode))
    }

    static var defaults: GameModeConfig {
        GameModeConfig(
            monitoredApps: MonitoredApp.presets,
            shortcuts: ShortcutEntry.defaults,
            functionKeysInGamingMode: false,
            mouse: MouseConfig(),
            system: SystemConfig(),
            gestures: GestureEntry.defaults,
            hotkeys: AppHotkey.defaults,
            display: DisplayConfig(),
            loggingEnabled: true,
            logLevel: .info
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
        // Existing installs retain their previously selected protection. Fresh
        // installs use the explicit opt-in default in the initializer below.
        isInputGuardEnabled = try container.decodeIfPresent(Bool.self, forKey: .isInputGuardEnabled)
            ?? (functionKeysInGamingMode || shortcuts.contains(where: \.disableInGamingMode) || gestures.contains(where: \.disableInGamingMode))
        hotkeys = try container.decodeIfPresent([AppHotkey].self, forKey: .hotkeys) ?? AppHotkey.defaults
        display = try container.decodeIfPresent(DisplayConfig.self, forKey: .display) ?? DisplayConfig()
        loggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .loggingEnabled) ?? true
        logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
    }

    init(monitoredApps: [MonitoredApp], shortcuts: [ShortcutEntry], functionKeysInGamingMode: Bool, mouse: MouseConfig, system: SystemConfig, gestures: [GestureEntry] = GestureEntry.defaults, hotkeys: [AppHotkey] = AppHotkey.defaults, display: DisplayConfig = DisplayConfig(), loggingEnabled: Bool = true, logLevel: LogLevel = .info, isInputGuardEnabled: Bool = false) {
        self.monitoredApps = monitoredApps
        self.shortcuts = shortcuts
        self.functionKeysInGamingMode = functionKeysInGamingMode
        self.isInputGuardEnabled = isInputGuardEnabled
        self.mouse = mouse
        self.system = system
        self.gestures = gestures
        self.hotkeys = hotkeys
        self.display = display
        self.loggingEnabled = loggingEnabled
        self.logLevel = logLevel
    }
}

struct InputGuardPolicy: Equatable {
    var functionKeysEnabled: Bool
    var shortcutIDs: [Int]
    var gestures: [GestureEntry]

    static let disabled = InputGuardPolicy(functionKeysEnabled: false, shortcutIDs: [], gestures: [])

    var isEmpty: Bool { !functionKeysEnabled && shortcutIDs.isEmpty && gestures.isEmpty }
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
