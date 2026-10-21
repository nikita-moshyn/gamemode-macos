//
//  CrashRecoveryProtection.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation
import ServiceManagement

struct CrashRecoveryProtection {
    var prepare: () throws -> Void
    var checkpoint: (StateJournal) throws -> Void = { journal in
        try RecoveryKit.export(to: RecoveryKit.automaticURL, journal: journal)
    }

    static let live = Self {
        let service = SMAppService.agent(plistName: RecoveryAgentFiles.serviceName + ".plist")
        try registerIfNeeded(status: { service.status }, register: { try service.register() })
        try handshake(files: .live)
    }

    /// Test injection must be explicit; hosted tests never register a live service.
    static let testing = Self(prepare: {}, checkpoint: { _ in })

    static func registerIfNeeded(status: () -> SMAppService.Status, register: () throws -> Void) throws {
        // On a first install macOS can report notFound before the valid bundled
        // agent has a background-task record. Registration creates that record.
        if status() == .notRegistered || status() == .notFound {
            do { try register() }
            catch {
                guard status() == .enabled || status() == .requiresApproval else {
                    throw RecoveryController.Failure.message("macOS could not register the recovery helper: \(error.localizedDescription). Retry Recovery with the current GameMode app.")
                }
            }
        }
        switch status() {
        case .enabled: return
        case .requiresApproval:
            throw RecoveryController.Failure.message("Crash recovery needs permission to run in the background. Open Login Items & Extensions, allow GameMode, then choose Retry Recovery. Temporary changes are paused until protection is ready.")
        default:
            throw RecoveryController.Failure.message("macOS could not find the registered recovery helper. Reopen the current GameMode app and choose Retry Recovery.")
        }
    }

    static func handshake(files: RecoveryAgentFiles, timeout: TimeInterval = 5) throws {
        let boot = RecoveryIdentity.bootSession
        guard !boot.isEmpty else { throw RecoveryController.Failure.message("Crash recovery could not identify this boot session") }
        let challenge = RecoveryAgentFiles.Challenge(nonce: UUID(), bootSession: boot)
        try files.write(challenge, to: files.challengeURL)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if files.isReady(for: challenge) { return }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw RecoveryController.Failure.message("The independent recovery helper did not confirm readiness. No new gaming changes were applied. Retry Recovery or check Login Items & Extensions.")
    }
}
