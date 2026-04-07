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
        guard shouldLog(.debug) else { return }
        logger(category: category).debug("\(message, privacy: .public)")
    }

    static func info(_ message: String, category: String = "general") {
        guard shouldLog(.info) else { return }
        logger(category: category).info("\(message, privacy: .public)")
    }

    static func warning(_ message: String, category: String = "general") {
        guard shouldLog(.warning) else { return }
        logger(category: category).warning("\(message, privacy: .public)")
    }

    static func error(_ message: String, category: String = "general") {
        guard shouldLog(.error) else { return }
        logger(category: category).error("\(message, privacy: .public)")
    }

    // MARK: - Level Filtering

    private static func shouldLog(_ level: LogLevel) -> Bool {
        #if DEBUG
        return true
        #else
        let config = ConfigStore.shared.config
        guard config.loggingEnabled else { return false }
        return level >= config.logLevel
        #endif
    }
}
