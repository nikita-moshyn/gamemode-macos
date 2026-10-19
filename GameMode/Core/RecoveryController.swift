//
//  RecoveryController.swift
//  GameMode
//
//  Created by Nikita Moshyn on 13/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

/// Runs on the existing serial settings queue. Operations are injected so recovery
/// can be tested without reading or changing the computer's preferences.
final class RecoveryController {
    struct Operations {
        var stopDisplays: () -> [String]
        var restoreDisplays: ([DisplayRecoveryRecord]) -> [String]
        var restoreKeyboard: (AppliedChanges) -> [String]
        var restorePower: ([String: Int]) -> [String]
        var readMouse: () -> Double?
        var applyMouse: (Double) -> Bool
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let message): return message }
        }
    }

    let journal: StateJournal
    let operations: Operations
    private(set) var hasOpenSession = false
    private var completionNeedsRetry = false

    init(journal: StateJournal, operations: Operations) {
        self.journal = journal
        self.operations = operations
    }

    func prepareForLaunch(restoreAutomatically: Bool) throws {
        if restoreAutomatically {
            try restore()
            return
        }
        switch journal.inspect() {
        case .missing, .clean: return
        case .pending:
            throw Failure.message("A previous session needs recovery. Automatic recovery is off; choose Retry Recovery.")
        case .invalid(let message): throw Failure.message(message)
        }
    }

    func activate(_ state: GameModeState, apply: () throws -> Void) throws {
        guard !hasOpenSession && !completionNeedsRetry else { throw Failure.message("A Game Mode session is already pending.") }
        try journal.begin(state)
        hasOpenSession = true
        // The checkpoint is committed before the first setter is called.
        try apply()
    }

    /// Change only Input Guard within an open Game Mode session. Reuse the
    /// existing setters, and never recapture an original until its restore commits.
    func updateInputGuard(_ policy: InputGuardPolicy, capture: (InputGuardPolicy) throws -> SettingsManager.KeyboardSnapshot, apply: (SettingsManager.KeyboardSnapshot) throws -> Void) throws {
        guard hasOpenSession else { throw Failure.message("Enable Game Mode before applying Input Guard.") }
        try restoreInputGuard()
        guard !policy.isEmpty else { return }
        let snapshot = try capture(policy)
        try journal.update {
            $0.appliedChanges.functionKeysChanged = snapshot.functionKeysChanged
            $0.appliedChanges.previousFunctionKeysEnabled = snapshot.previousFunctionKeysEnabled
            $0.appliedChanges.functionKeysWerePersisted = false
            $0.appliedChanges.disabledShortcutIDs = snapshot.shortcutIDsToDisable
            $0.appliedChanges.previousShortcutStates = snapshot.previousShortcutStates
            $0.appliedChanges.shortcutsWerePersisted = false
            $0.appliedChanges.gesturesChanged = !snapshot.gesturesToDisable.isEmpty
            $0.appliedChanges.previousGestureValues = snapshot.previousGestureValues
        }
        try apply(snapshot)
    }

    func restoreInputGuard() throws {
        let errors = try restoreInputGuardSettings()
        guard errors.isEmpty else { throw Failure.message(errors.joined(separator: "\n")) }
    }

    /// Setting-level failures can be accumulated during full recovery. Storage
    /// failures must still stop the sequence before any further system changes.
    private func restoreInputGuardSettings() throws -> [String] {
        let state = try journal.load()
        guard state.isActive else {
            if hasOpenSession { throw Failure.message("The recovery snapshot is missing.") }
            return []
        }
        let changes = state.appliedChanges
        guard changes.functionKeysChanged || changes.gesturesChanged || !changes.disabledShortcutIDs.isEmpty || changes.previousShortcutStates != nil else { return [] }
        let errors = operations.restoreKeyboard(changes)
        guard errors.isEmpty else { return errors }
        try journal.update {
            $0.appliedChanges.functionKeysChanged = false
            $0.appliedChanges.previousFunctionKeysEnabled = nil
            $0.appliedChanges.functionKeysWerePersisted = false
            $0.appliedChanges.gesturesChanged = false
            $0.appliedChanges.previousGestureValues = nil
            $0.appliedChanges.disabledShortcutIDs = []
            $0.appliedChanges.previousShortcutStates = nil
        }
        return []
    }

    func applyMouseProfile(speed: Double) throws {
        guard hasOpenSession else { throw Failure.message("Enable Game Mode before applying the Mouse Preset.") }
        let state = try journal.load()
        guard state.isActive else { throw Failure.message("The recovery snapshot is missing. Mouse settings were not changed.") }
        guard speed.isFinite else { throw Failure.message("The configured tracking speed is invalid.") }
        if !state.appliedChanges.mouseSpeedChanged {
            guard let baseline = operations.readMouse(), baseline.isFinite else {
                throw Failure.message("The current tracking speed could not be read. Mouse settings were not changed.")
            }
            try journal.update {
                $0.appliedChanges.mouseSpeedChanged = true
                $0.appliedChanges.previousMouseSpeed = baseline
            }
        }
        guard operations.applyMouse(speed), mouseMatches(speed) else {
            throw Failure.message("The Mouse Preset could not be confirmed. Its original speed is saved for recovery.")
        }
    }

    func restoreMouseProfile() throws {
        let state = try journal.load()
        guard state.isActive else {
            if hasOpenSession { throw Failure.message("The recovery snapshot is missing.") }
            return
        }
        guard state.appliedChanges.mouseSpeedChanged else { return }
        guard let speed = state.appliedChanges.previousMouseSpeed, speed.isFinite else {
            throw Failure.message("The saved original mouse speed is missing.")
        }
        guard operations.applyMouse(speed), mouseMatches(speed) else {
            throw Failure.message("The original mouse speed could not be restored. Retry recovery.")
        }
        try journal.update {
            $0.appliedChanges.mouseSpeedChanged = false
            $0.appliedChanges.previousMouseSpeed = nil
        }
    }

    /// Partial restoration is checkpointed; failures never discard the originals.
    func restore() throws {
        var state = try journal.load()
        guard state.isActive else {
            if completionNeedsRetry, journal.inspect() == .clean {
                // The manifest may have been replaced before its final flush
                // failed. Recommit the clean authority without replaying setters.
                try completeSession()
                return
            }
            if hasOpenSession { throw Failure.message("The recovery snapshot is missing. Review your system settings before continuing.") }
            if completionNeedsRetry { throw Failure.message("The recovery completion record is missing. Review your system settings before continuing.") }
            return
        }
        let initialDisplayFailures = operations.stopDisplays()
        // A failed durable completion is an unknown outcome even if a subsequent
        // read sees the new manifest. Require a verified retry before finishing.
        var failures = initialDisplayFailures
        if !initialDisplayFailures.isEmpty {
            Log.warning(initialDisplayFailures.joined(separator: "; "), category: "Recovery")
        }
        // Runtime display restoration may have checkpointed individual successes.
        state = try journal.load()
        if !state.appliedChanges.displayRestores.isEmpty {
            let errors = operations.restoreDisplays(state.appliedChanges.displayRestores)
            failures += errors
            if errors.isEmpty {
                try journal.update { $0.appliedChanges.displayRestores = [] }
            }
        }

        let changes = state.appliedChanges
        failures += try restoreInputGuardSettings()
        if changes.lowPowerModeChanged {
            if let originals = changes.previousLowPowerModeSettings, !originals.isEmpty {
                let errors = operations.restorePower(originals)
                failures += errors
                if errors.isEmpty {
                    try journal.update {
                        $0.appliedChanges.lowPowerModeChanged = false
                        $0.appliedChanges.previousLowPowerModeSettings = nil
                        $0.appliedChanges.previousLowPowerModeEnabled = nil
                    }
                }
            } else {
                failures.append("This older recovery file has no separate battery and charger settings. Review Low Power Mode in System Settings, then accept your current settings.")
            }
        }
        do { try restoreMouseProfile() } catch { failures.append(error.localizedDescription) }
        guard failures.isEmpty else { throw Failure.message(failures.joined(separator: "\n")) }
        try completeSession()
    }

    private func completeSession() throws {
        completionNeedsRetry = true
        try journal.complete()
        completionNeedsRetry = false
        hasOpenSession = false
    }

    func reset() throws {
        try restore()
        try journal.reset()
    }

    func acceptCurrentSettings() throws {
        try journal.archiveAndReset()
        completionNeedsRetry = false
        hasOpenSession = false
    }

    private func mouseMatches(_ expected: Double) -> Bool {
        guard let actual = operations.readMouse(), actual.isFinite else { return false }
        return abs(actual - expected) < 0.001
    }
}
