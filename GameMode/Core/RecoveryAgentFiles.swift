//
//  RecoveryAgentFiles.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Darwin
import Foundation

/// Protocol files live outside the journal; neither a reset nor an export can
/// replace the process locks or turn an old acknowledgement into a new one.
struct RecoveryAgentFiles {
    static let protocolVersion = 1
    static let serviceName = "com.moshyn.nikita.GameMode.Recovery"
    var support: URL
    var directory: URL { support.appendingPathComponent("GameModeRecovery") }
    var challengeURL: URL { directory.appendingPathComponent("challenge.json") }
    var readyURL: URL { directory.appendingPathComponent("ready.json") }
    var resultURL: URL { directory.appendingPathComponent("result.json") }

    struct Challenge: Codable, Equatable {
        var nonce: UUID
        var bootSession: String
        var protocolVersion = RecoveryAgentFiles.protocolVersion
    }

    struct Ready: Codable {
        var challenge: Challenge
        var pid: Int32
        var date: Date
    }

    struct Result: Codable, Equatable {
        var date: Date
        var succeeded: Bool
        var message: String
    }

    static var live: Self { .init(support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) }

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func acknowledge() throws {
        guard let data = try? Data(contentsOf: challengeURL), let challenge = try? JSONDecoder().decode(Challenge.self, from: data),
              challenge.protocolVersion == Self.protocolVersion, challenge.bootSession == RecoveryIdentity.bootSession else { return }
        if let ready = try? JSONDecoder().decode(Ready.self, from: Data(contentsOf: readyURL)),
           ready.challenge == challenge, ready.pid == getpid(), abs(ready.date.timeIntervalSinceNow) < 2 { return }
        try write(Ready(challenge: challenge, pid: getpid(), date: Date()), to: readyURL)
    }

    func isReady(for challenge: Challenge) -> Bool {
        guard let ready = try? JSONDecoder().decode(Ready.self, from: Data(contentsOf: readyURL)) else { return false }
        return ready.challenge == challenge && ready.pid > 1 && kill(ready.pid, 0) == 0 && abs(ready.date.timeIntervalSinceNow) < 15
    }

    var isRunning: Bool {
        guard let ready = try? JSONDecoder().decode(Ready.self, from: Data(contentsOf: readyURL)),
              ready.challenge.protocolVersion == Self.protocolVersion, ready.challenge.bootSession == RecoveryIdentity.bootSession else { return false }
        return ready.pid > 1 && kill(ready.pid, 0) == 0 && abs(ready.date.timeIntervalSinceNow) < 5
    }

    var lastResult: Result? { try? JSONDecoder().decode(Result.self, from: Data(contentsOf: resultURL)) }
}
