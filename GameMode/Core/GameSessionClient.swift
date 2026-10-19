//
//  GameSessionClient.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import Foundation

struct GameSessionClient: Sendable {
    enum Outcome: Equatable, Sendable {
        case applied
        case skipped
    }

    enum Response: Equatable, Sendable {
        case completed(Outcome)
        case failed(String)
    }

    var execute: @Sendable (GameSession.Transition, @escaping @MainActor @Sendable (Response) -> Void) async -> Void

    init(transition: @escaping @Sendable (GameSession.Transition) async throws -> Outcome) {
        execute = { request, report in
            do { await report(.completed(try await transition(request))) }
            catch { await report(.failed(error.localizedDescription)) }
        }
    }

    private init(execute: @escaping @Sendable (GameSession.Transition, @escaping @MainActor @Sendable (Response) -> Void) async -> Void) {
        self.execute = execute
    }

    /// Shares the existing settings queue with live edits, recovery and shutdown.
    /// Rechecks permission to execute *on the worker*, because termination can
    /// arrive before an effect has even enqueued its operation.
    static func serialized(on queue: DispatchQueue, shouldExecute: @escaping @Sendable (GameSession.Transition) -> Bool, apply: @escaping @Sendable (GameSession.Transition) throws -> Void) -> Self {
        Self(execute: { transition, report in
            await withCheckedContinuation { continuation in
                queue.async {
                    let response: Response
                    do {
                        if shouldExecute(transition) {
                            try apply(transition)
                            response = .completed(.applied)
                        } else {
                            response = .completed(.skipped)
                        }
                    } catch {
                        response = .failed(error.localizedDescription)
                    }
                    // Commit the result to the store before another queued settings
                    // edit reads the session. Never synchronously wait on this queue
                    // from main: the existing setters also need the main thread.
                    DispatchQueue.main.sync { report(response) }
                    continuation.resume()
                }
            }
        })
    }
}

extension GameSessionClient: TestDependencyKey {
    static let testValue = Self(transition: unimplemented("GameSessionClient.transition"))
}

extension DependencyValues {
    var gameSession: GameSessionClient {
        get { self[GameSessionClient.self] }
        set { self[GameSessionClient.self] = newValue }
    }
}
