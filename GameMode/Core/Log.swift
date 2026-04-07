//
//  Log.swift
//  GameMode
//
//  Created by Nikita Moshyn on 23/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import os
import Foundation

/// Shared logging facade for GameMode.
///
/// Uses Apple's unified logging (`os.Logger`) under the hood.
/// Respects the user's log level setting from `ConfigStore`,
/// unless this is a DEBUG build (which logs everything).
enum Log {

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.nikita.GameMode"

    private static func logger(category: String) -> os.Logger {
        os.Logger(subsystem: subsystem, category: category)
    }

    // MARK: - Public API

    static func debug(_ message: String, category: String = "general") {
        log(.debug, message, category: category)
    }

    static func info(_ message: String, category: String = "general") {
        log(.info, message, category: category)
    }

    static func warning(_ message: String, category: String = "general") {
        log(.warning, message, category: category)
    }

    static func error(_ message: String, category: String = "general") {
        log(.error, message, category: category)
    }

    /// Logs using an explicit config snapshot instead of `ConfigStore.shared`.
    /// This avoids re-entering the singleton while it is still initializing.
    static func bootstrap(_ level: LogLevel, _ message: String, category: String = "general", config: GameModeConfig) {
        guard shouldLog(level, config: config) else { return }
        emit(level, message, category: category)
    }

    // MARK: - Level Filtering

    private static func log(_ level: LogLevel, _ message: String, category: String) {
        guard shouldLog(level) else { return }
        emit(level, message, category: category)
    }

    private static func emit(_ level: LogLevel, _ message: String, category: String) {
        switch level {
        case .debug:
            logger(category: category).debug("\(message, privacy: .public)")
        case .info:
            logger(category: category).info("\(message, privacy: .public)")
        case .warning:
            logger(category: category).warning("\(message, privacy: .public)")
        case .error:
            logger(category: category).error("\(message, privacy: .public)")
        }
    }

    private static func shouldLog(_ level: LogLevel) -> Bool {
        #if DEBUG
        return true
        #else
        return shouldLog(level, config: ConfigStore.shared.config)
        #endif
    }

    private static func shouldLog(_ level: LogLevel, config: GameModeConfig) -> Bool {
        #if DEBUG
        return true
        #else
        guard config.loggingEnabled else { return false }
        return level >= config.logLevel
        #endif
    }
}
