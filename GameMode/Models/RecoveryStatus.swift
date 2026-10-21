//
//  RecoveryStatus.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

struct RecoveryStatus: Equatable, Sendable {
    enum Protection: String, Sendable {
        case ready = "On"
        case waiting = "Starting…"
        case approval = "Permission Needed"
        case disabled = "Setup Needed"
        case unavailable = "Unavailable"
    }
    var protection: Protection = .disabled
}
