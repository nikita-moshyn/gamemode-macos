//
//  GameModeConfig.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

// MARK: - Top-Level Config

struct GameModeConfig: Codable, Equatable, Sendable {
    var monitoredApps: [MonitoredApp]
    var shortcuts: [ShortcutEntry]
    var functionKeyBehavior: FunctionKeyBehavior
    /// Migration bridge for older callers and configurations.
    var functionKeysInGamingMode: Bool {
        get { functionKeyBehavior == .standard }
        set { functionKeyBehavior = newValue ? .standard : .unchanged }
    }
    var isInputGuardEnabled: Bool
    var mouse: MouseConfig
    var system: SystemConfig
    var gestures: [GestureEntry]
    var hotkeys: [AppHotkey]
    var display: DisplayConfig
    var loggingEnabled: Bool
    var logLevel: LogLevel
    var receivesBetaUpdates: Bool

    /// Sparkle always includes stable updates; prereleases require explicit consent.
    var allowedUpdateChannels: Set<String> {
        receivesBetaUpdates ? ["beta", "rc"] : []
    }

    /// The master switch gates effects without clearing the user's selections.
    var inputGuardPolicy: InputGuardPolicy {
        guard isInputGuardEnabled else { return .disabled }
        return InputGuardPolicy(functionKeyBehavior: functionKeyBehavior,
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

    enum CodingKeys: String, CodingKey { case monitoredApps, shortcuts, functionKeyBehavior, isInputGuardEnabled, mouse, system, gestures, hotkeys, display, loggingEnabled, logLevel, receivesBetaUpdates, functionKeysInGamingMode }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(monitoredApps, forKey: .monitoredApps)
        try container.encode(shortcuts, forKey: .shortcuts)
        try container.encode(functionKeyBehavior, forKey: .functionKeyBehavior)
        try container.encode(isInputGuardEnabled, forKey: .isInputGuardEnabled)
        try container.encode(mouse, forKey: .mouse)
        try container.encode(system, forKey: .system)
        try container.encode(gestures, forKey: .gestures)
        try container.encode(hotkeys, forKey: .hotkeys)
        try container.encode(display, forKey: .display)
        try container.encode(loggingEnabled, forKey: .loggingEnabled)
        try container.encode(logLevel, forKey: .logLevel)
        try container.encode(receivesBetaUpdates, forKey: .receivesBetaUpdates)
        try container.encode(functionKeysInGamingMode, forKey: .functionKeysInGamingMode)
    }

    // Migration-safe decoder: older configs won't have gestures/hotkeys fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monitoredApps = try container.decode([MonitoredApp].self, forKey: .monitoredApps)
        shortcuts = try container.decode([ShortcutEntry].self, forKey: .shortcuts)
        let legacyFunctionKeys = try container.decodeIfPresent(Bool.self, forKey: .functionKeysInGamingMode) ?? false
        functionKeyBehavior = try container.decodeIfPresent(FunctionKeyBehavior.self, forKey: .functionKeyBehavior)
            ?? (legacyFunctionKeys ? .standard : .unchanged)
        mouse = try container.decode(MouseConfig.self, forKey: .mouse)
        system = try container.decode(SystemConfig.self, forKey: .system)
        gestures = try container.decodeIfPresent([GestureEntry].self, forKey: .gestures) ?? GestureEntry.defaults
        // Existing installs retain their previously selected protection. Fresh
        // installs use the explicit opt-in default in the initializer below.
        isInputGuardEnabled = try container.decodeIfPresent(Bool.self, forKey: .isInputGuardEnabled)
            ?? (functionKeyBehavior != .unchanged || shortcuts.contains(where: \.disableInGamingMode) || gestures.contains(where: \.disableInGamingMode))
        hotkeys = try container.decodeIfPresent([AppHotkey].self, forKey: .hotkeys) ?? AppHotkey.defaults
        display = try container.decodeIfPresent(DisplayConfig.self, forKey: .display) ?? DisplayConfig()
        loggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .loggingEnabled) ?? true
        logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        receivesBetaUpdates = try container.decodeIfPresent(Bool.self, forKey: .receivesBetaUpdates) ?? false
    }

    init(monitoredApps: [MonitoredApp], shortcuts: [ShortcutEntry], functionKeysInGamingMode: Bool, mouse: MouseConfig, system: SystemConfig, gestures: [GestureEntry] = GestureEntry.defaults, hotkeys: [AppHotkey] = AppHotkey.defaults, display: DisplayConfig = DisplayConfig(), loggingEnabled: Bool = true, logLevel: LogLevel = .info, isInputGuardEnabled: Bool = false, receivesBetaUpdates: Bool = false) {
        self.monitoredApps = monitoredApps
        self.shortcuts = shortcuts
        self.functionKeyBehavior = functionKeysInGamingMode ? .standard : .unchanged
        self.isInputGuardEnabled = isInputGuardEnabled
        self.mouse = mouse
        self.system = system
        self.gestures = gestures
        self.hotkeys = hotkeys
        self.display = display
        self.loggingEnabled = loggingEnabled
        self.logLevel = logLevel
        self.receivesBetaUpdates = receivesBetaUpdates
    }
}

struct InputGuardPolicy: Equatable {
    var functionKeyBehavior: FunctionKeyBehavior
    var functionKeysEnabled: Bool { functionKeyBehavior == .standard }

    init(functionKeyBehavior: FunctionKeyBehavior, shortcutIDs: [Int], gestures: [GestureEntry]) {
        self.functionKeyBehavior = functionKeyBehavior
        self.shortcutIDs = shortcutIDs
        self.gestures = gestures
    }

    init(functionKeysEnabled: Bool, shortcutIDs: [Int], gestures: [GestureEntry]) {
        self.init(functionKeyBehavior: functionKeysEnabled ? .standard : .unchanged, shortcutIDs: shortcutIDs, gestures: gestures)
    }
    var shortcutIDs: [Int]
    var gestures: [GestureEntry]

    static let disabled = InputGuardPolicy(functionKeysEnabled: false, shortcutIDs: [], gestures: [])

    var isEmpty: Bool { functionKeyBehavior == .unchanged && shortcutIDs.isEmpty && gestures.isEmpty }
}

// MARK: - Mouse

struct MouseConfig: Codable, Equatable, Sendable {
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

struct SystemConfig: Codable, Equatable, Sendable {
    /// Retained for decoding older configurations; shutdown recovery is always on.
    var restoreOnShutdown: Bool = true
    /// Retained for decoding older configurations; launch recovery is always on.
    var restoreOnLaunch: Bool = true
    /// Explicit permission to prefer normal media keys over a conflicting per-Mac override.
    var repairLegacyFunctionKeyOverride: Bool = false

    init(restoreOnShutdown: Bool = true, restoreOnLaunch: Bool = true, repairLegacyFunctionKeyOverride: Bool = false) {
        self.restoreOnShutdown = restoreOnShutdown
        self.restoreOnLaunch = restoreOnLaunch
        self.repairLegacyFunctionKeyOverride = repairLegacyFunctionKeyOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        restoreOnShutdown = try container.decodeIfPresent(Bool.self, forKey: .restoreOnShutdown) ?? true
        restoreOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .restoreOnLaunch) ?? true
        repairLegacyFunctionKeyOverride = try container.decodeIfPresent(Bool.self, forKey: .repairLegacyFunctionKeyOverride) ?? false
    }
}
