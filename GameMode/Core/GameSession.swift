//
//  GameSession.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture

/// Owns mode transitions for the lifetime of the app, independently of its windows.
/// The journal remains the authority for changes that still need restoration.
@Reducer
struct GameSession {
    struct Transition: Equatable, Sendable {
        let id: UInt64
        let isEnabled: Bool
    }

    enum Source: Equatable, Sendable {
        case automatic
        case menu
        case hotkey
    }

    enum Phase: Equatable, Sendable {
        case recovering
        case ready
        case transitioning(Transition)
        case needsRecovery(String)
        case terminating
    }

    @ObservableState
    struct State: Equatable {
        var phase: Phase = .recovering
        var desiredMode = false
        var appliedMode = false
        var transitionSequence: UInt64 = 0
        var configurationIsValid = true
        /// The root feature serializes mouse, Input Guard, and display commands.
        var settingsAreChanging = false

        var recoveryReady: Bool {
            switch phase {
            case .ready, .transitioning: return true
            case .recovering, .needsRecovery, .terminating: return false
            }
        }

        var isBusy: Bool {
            switch phase {
            case .recovering, .transitioning, .terminating: return true
            case .ready, .needsRecovery: return settingsAreChanging
            }
        }

        var recoveryMessage: String? {
            guard case .needsRecovery(let message) = phase else { return nil }
            return message
        }

        func allows(_ transition: Transition) -> Bool {
            phase == .transitioning(transition)
        }
    }

    enum Action {
        case modeRequested(Bool, source: Source)
        case transitionFinished(Transition, GameSessionClient.Outcome)
        case transitionFailed(Transition, String)
        case configurationValidityChanged(Bool)
        case settingsActivityChanged(Bool)
        case recoveryStarted
        case recoverySucceeded
        case recoveryFailed(String)
        case terminationRequested
    }

    @Dependency(\.gameSession) var client

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .modeRequested(enabled, source):
                guard state.configurationIsValid, state.recoveryReady else { return .none }
                guard source == .automatic || !state.isBusy else { return .none }
                state.desiredMode = enabled
                return startNextTransition(&state)

            case let .transitionFinished(transition, outcome):
                // Recovery or termination may have superseded this operation.
                guard state.allows(transition) else { return .none }
                state.phase = .ready
                guard outcome == .applied else {
                    state.desiredMode = state.appliedMode
                    return .none
                }
                state.appliedMode = transition.isEnabled
                return startNextTransition(&state)

            case let .transitionFailed(transition, message):
                guard state.allows(transition) else { return .none }
                state.phase = .needsRecovery(message)
                state.desiredMode = state.appliedMode
                return .none

            case .configurationValidityChanged(let valid):
                state.configurationIsValid = valid
                return .none

            case .settingsActivityChanged(let changing):
                state.settingsAreChanging = changing
                return changing ? .none : startNextTransition(&state)

            case .recoveryStarted:
                guard state.phase != .terminating else { return .none }
                state.phase = .recovering
                state.desiredMode = false
                return .none

            case .recoverySucceeded:
                guard state.phase == .recovering else { return .none }
                state.phase = .ready
                state.appliedMode = false
                state.desiredMode = false
                return .none

            case .recoveryFailed(let message):
                guard state.phase != .terminating else { return .none }
                state.phase = .needsRecovery(message)
                state.desiredMode = state.appliedMode
                return .none

            case .terminationRequested:
                // Do not cancel in-flight mutations. Shutdown restoration is queued
                // behind them on the same executor and may need their checkpoints.
                state.phase = .terminating
                state.desiredMode = false
                return .none
            }
        }
    }

    private func startNextTransition(_ state: inout State) -> Effect<Action> {
        guard state.phase == .ready, !state.settingsAreChanging, state.configurationIsValid, state.desiredMode != state.appliedMode else { return .none }
        state.transitionSequence += 1
        let transition = Transition(id: state.transitionSequence, isEnabled: state.desiredMode)
        state.phase = .transitioning(transition)
        // A newer automatic request replaces the target, never an in-flight setter.
        // The next operation starts only after this one has returned its result.
        return .run { [client] send in
            await client.execute(transition) { response in
                switch response {
                case .completed(let outcome): send(.transitionFinished(transition, outcome))
                case .failed(let message): send(.transitionFailed(transition, message))
                }
            }
        }
    }
}
