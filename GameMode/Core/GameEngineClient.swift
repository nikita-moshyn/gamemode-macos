//
//  GameEngineClient.swift
//  GameMode
//
//  Created by Nikita Moshyn on 13/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import Foundation

struct GameEngineClient: Sendable {
    enum Operation: Equatable, Sendable {
        case startup, recover, accept, reset, mouse(Bool), inputGuard, display, terminate
        case restoreNormalSettings, removeFunctionKeyOverride(FunctionKeyPreferences), exportRecoveryKit(URL), inspectRecovery, restoreBackup(RecoveryBackup, Set<RecoveryBackup.Setting>)
        var isRecovery: Bool {
            switch self { case .startup, .recover, .accept, .reset, .restoreNormalSettings, .removeFunctionKeyOverride, .restoreBackup: return true; default: return false }
        }
        var isReadOnly: Bool {
            switch self { case .inspectRecovery, .exportRecoveryKit: return true; default: return false }
        }
    }
    struct Request: Equatable, Sendable {
        let id: UInt64
        let operation: Operation
    }
    struct Snapshot: Equatable, Sendable {
        var mouseIsApplied = false
        var mouseBaseline: Double?
        var recoveryBackup: RecoveryBackup?
    }
    enum Response: Equatable, Sendable { case completed(Snapshot), failed(String, Snapshot) }
    struct Context {
        var config: GameModeConfig
        var session: GameSession.State
        var request: Request?
        var needsDisplay: Bool

        func allows(_ request: Request) -> Bool {
            guard self.request == request else { return false }
            switch request.operation {
            case .startup, .recover, .accept, .reset, .restoreNormalSettings, .removeFunctionKeyOverride, .restoreBackup: return session.phase == .recovering
            case .exportRecoveryKit, .inspectRecovery:
                switch session.phase { case .ready, .needsRecovery: return true; default: return false }
            case .terminate: return session.phase == .terminating
            case .mouse: return session.recoveryReady && session.appliedMode
            case .inputGuard: return session.recoveryReady && session.appliedMode && session.desiredMode
            case .display:
                #if FEATURE_DISPLAYS
                return session.recoveryReady && session.appliedMode && session.desiredMode
                #else
                return false
                #endif
            }
        }
    }
    var execute: @Sendable (Request, @escaping @MainActor @Sendable (Response) -> Void) async -> Void
    var snapshot: @Sendable () -> Snapshot
}

extension GameEngineClient: TestDependencyKey {
    static let testValue = Self(execute: unimplemented("GameEngineClient.execute"), snapshot: { Snapshot() })
}
extension DependencyValues {
    var gameEngine: GameEngineClient {
        get { self[GameEngineClient.self] }
        set { self[GameEngineClient.self] = newValue }
    }
}

/// Owns native resources and executes journaled commands. Policy, operation IDs,
/// pending work, and the recovery gate belong to GameModeFeature.
final class GameEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nikita.GameMode.settings", qos: .userInitiated)
    private let settingsManager: SettingsManager
    private let refreshRateLock: RefreshRateLock
    private let snapshot = LockIsolated(GameEngineClient.Snapshot())
    private let journal: StateJournal
    private let protection: CrashRecoveryProtection
    private let recovery: RecoveryController

    init(journal: StateJournal = .shared, refreshRateLock: RefreshRateLock = RefreshRateLock(), settingsManager: SettingsManager = SettingsManager(), protection: CrashRecoveryProtection = .live) {
        self.journal = journal
        self.refreshRateLock = refreshRateLock
        self.settingsManager = settingsManager
        self.protection = protection
        recovery = .system(journal: journal, settings: settingsManager, displays: refreshRateLock, interactive: true, automaticDisplayRecovery: true) {
            try protection.prepare()
            try protection.checkpoint(journal)
        }
    }

    func clients(context: @escaping @MainActor @Sendable () -> GameEngineClient.Context) -> (GameEngineClient, GameSessionClient) {
        let read: @Sendable () -> GameEngineClient.Context = { DispatchQueue.main.sync { context() } }
        let client = GameEngineClient(execute: { [self] request, report in
            await withCheckedContinuation { continuation in
                queue.async {
                    let current = read()
                    // Effects can enqueue after termination has superseded them.
                    guard current.request == request else { continuation.resume(); return }
                    let response: GameEngineClient.Response
                    do {
                        if current.allows(request) { try self.perform(request.operation, context: current) }
                        response = .completed(self.captureSnapshot())
                    } catch {
                        Log.error(error.localizedDescription, category: "Recovery")
                        response = .failed(error.localizedDescription, self.captureSnapshot())
                    }
                    // Publish recovery failures before the next command can run.
                    DispatchQueue.main.sync { report(response) }
                    continuation.resume()
                }
            }
        }, snapshot: { [snapshot] in snapshot.value })
        let session = GameSessionClient.serialized(on: queue, shouldExecute: { read().session.allows($0) }, apply: { [self] transition in
            defer { _ = captureSnapshot() }
            if transition.isEnabled { try activate(context: read(), read: read) }
            else {
                try recovery.recover(repairLegacyOverride: read().config.system.repairLegacyFunctionKeyOverride)
            }
        })
        return (client, session)
    }

    private func captureSnapshot() -> GameEngineClient.Snapshot {
        guard let state = try? journal.load() else { return snapshot.value }
        let changes = state.appliedChanges
        let value = GameEngineClient.Snapshot(mouseIsApplied: changes.mouseSpeedChanged, mouseBaseline: changes.previousMouseSpeed, recoveryBackup: snapshot.value.recoveryBackup)
        snapshot.setValue(value)
        return value
    }

    private func perform(_ operation: GameEngineClient.Operation, context: GameEngineClient.Context) throws {
        defer {
            if operation.isRecovery { refreshRateLock.resumeAutomaticRecovery() }
        }
        switch operation {
        case .startup:
            try recovery.prepareForLaunch(restoreAutomatically: true, repairLegacyOverride: context.config.system.repairLegacyFunctionKeyOverride)
            // A missing helper blocks only changes that could survive a crash.
            // Process-owned shortcut blocking can still be used safely.
            do { try protection.prepare(); try protection.checkpoint(journal) }
            catch { Log.warning(error.localizedDescription, category: "Recovery") }
        case .recover, .terminate:
            try recovery.recover(repairLegacyOverride: context.config.system.repairLegacyFunctionKeyOverride)
            if operation == .recover {
                do { try protection.prepare() } catch { Log.warning(error.localizedDescription, category: "Recovery") }
            }
        case .reset: try recovery.reset()
        case .restoreNormalSettings:
            try recovery.recover(repairLegacyOverride: context.config.system.repairLegacyFunctionKeyOverride)
        case .removeFunctionKeyOverride(let expected):
            try recovery.recover(.removeFunctionKeyOverride(expected))
        case .exportRecoveryKit(let destination):
            try recovery.exportKit(to: destination)
        case .inspectRecovery:
            let backup = try recovery.backup()
            snapshot.withValue { $0.recoveryBackup = backup }
        case let .restoreBackup(backup, settings):
            try recovery.restoreBackup(backup, settings: settings)
        case .accept:
            refreshRateLock.pauseAutomaticRecovery()
            try recovery.acceptCurrentSettings()
            refreshRateLock.abandonCurrentSession()
            settingsManager.stopOwnedEffects()
        case .mouse(let apply):
            if apply { try recovery.applyMouseProfile(speed: context.config.mouse.gamingSpeed) }
            else { try recovery.restoreMouseProfile() }
        case .inputGuard:
            try recovery.updateInputGuard(context.config.inputGuardPolicy, capture: { [self] policy in
                try settingsManager.captureKeyboardSettings(functionKeyBehavior: policy.functionKeyBehavior, shortcutIDs: policy.shortcutIDs, gestures: policy.gestures)
            }, apply: { [self] in try settingsManager.applyKeyboardSettings($0) })
        case .display: try applyDisplays(context: context)
        }
    }

    private func activate(context: GameEngineClient.Context, read: () -> GameEngineClient.Context) throws {
        let config = context.config
        try recovery.repairLegacyFunctionKeyOverrideIfNeeded(enabled: config.system.repairLegacyFunctionKeyOverride)
        let policy = config.inputGuardPolicy
        let snapshot = try settingsManager.captureKeyboardSettings(functionKeyBehavior: policy.functionKeyBehavior, shortcutIDs: policy.shortcutIDs, gestures: policy.gestures)
        #if FEATURE_DISPLAYS
        let shouldDisablePower = config.display.autoDisableLowPowerMode && PowerManager.isLowPowerModeEnabled
            && PowerManager.isBatteryAboveThreshold(config.display.lowPowerModeBatteryThreshold)
        let power = shouldDisablePower ? PowerManager.captureLowPowerModeSettings() : nil
        #else
        let power: [String: Int]? = nil
        #endif
        var state = GameModeState(isActive: true, activatedAt: Date(), appliedChanges: AppliedChanges(
            functionKeysChanged: snapshot.functionKeysChanged,
            previousFunctionKeysEnabled: snapshot.previousFunctionKeysEnabled,
            disabledShortcutIDs: snapshot.shortcutIDsToDisable,
            previousShortcutStates: snapshot.previousShortcutStates,
            mouseSpeedChanged: false, previousMouseSpeed: nil,
            gesturesChanged: !snapshot.gesturesToDisable.isEmpty,
            previousGestureValues: snapshot.previousGestureValues,
            lowPowerModeChanged: power != nil, previousLowPowerModeEnabled: nil,
            previousLowPowerModeSettings: power
        ))
        state.appliedChanges.functionKeyContext = snapshot.functionKeyContext
        try recovery.activate(state) {
            try settingsManager.applyKeyboardSettings(snapshot)
            #if FEATURE_DISPLAYS
            if power != nil && !PowerManager.setLowPowerMode(enabled: false) {
                throw RecoveryController.Failure.message("Low Power Mode could not be changed. Retry recovery to restore the saved settings.")
            }
            #endif
            if config.mouse.isEnabled && config.mouse.isMouseBoostEnabled { try recovery.applyMouseProfile(speed: config.mouse.gamingSpeed) }
            #if FEATURE_DISPLAYS
            let latest = read()
            if latest.session.desiredMode { try applyDisplays(context: latest) }
            #endif
        }
    }

    private func applyDisplays(context: GameEngineClient.Context) throws {
        #if FEATURE_DISPLAYS
        let failures: [String]
        if context.config.display.isRefreshRateLockEnabled && context.needsDisplay {
            failures = refreshRateLock.start(config: context.config.display).failedDisplays
        } else {
            failures = refreshRateLock.stop().failedDisplays
        }
        if !failures.isEmpty { throw RecoveryController.Failure.message(failures.joined(separator: "\n")) }
        #endif
    }
}
