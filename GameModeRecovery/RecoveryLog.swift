//
//  RecoveryLog.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import os

/// The standalone helper has no UI or package dependencies.
enum Log {
    static func debug(_ message: String, category: String = "Recovery") { Logger(subsystem: "com.moshyn.nikita.GameMode.Recovery", category: category).debug("\(message, privacy: .public)") }
    static func info(_ message: String, category: String = "Recovery") { Logger(subsystem: "com.moshyn.nikita.GameMode.Recovery", category: category).info("\(message, privacy: .public)") }
    static func warning(_ message: String, category: String = "Recovery") { Logger(subsystem: "com.moshyn.nikita.GameMode.Recovery", category: category).warning("\(message, privacy: .public)") }
    static func error(_ message: String, category: String = "Recovery") { Logger(subsystem: "com.moshyn.nikita.GameMode.Recovery", category: category).error("\(message, privacy: .public)") }
}
