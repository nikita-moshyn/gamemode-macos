//
//  RecoveryController.swift
//  GameMode
//
//  Created by Nikita Moshyn on 13/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

/// The app, crash helper, and exported tool share this recovery engine and journal.
/// Callers serialize access and hold the app's process lock. Injected operations
/// let tests exercise recovery without changing the computer's preferences.
final class RecoveryController {
    struct Operations {
        var stopDisplays: () -> [String]
        var restoreDisplays: ([DisplayRecoveryRecord]) -> [String]
        var restoreKeyboard: (AppliedChanges) -> [String]
        var restorePower: ([String: Int]) -> [String]
        var readMouse: () -> Double?
        var applyMouse: (Double) -> Bool
        var stopOwnedEffects: () -> Void = {}
        var needsLegacyFunctionKeyRepair: () throws -> Bool = { false }
        var normalFunctionKeyRecovery: () throws -> AppliedChanges = { .empty }
        var functionKeyOverrideRemoval: (FunctionKeyPreferences) throws -> AppliedChanges = { _ in .empty }
        var captureRecoverySettings: () -> AppliedChanges = { .empty }
        var prepareImportedSettings: (AppliedChanges) throws -> AppliedChanges = { $0 }
    }

    enum Intent {
        case interruptedSession
        case normalSettings
        case removeFunctionKeyOverride(FunctionKeyPreferences)
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let message): return message }
        }
    }

    let journal: StateJournal
    let operations: Operations
    private let beforeMutation: () throws -> Void
    private(set) var hasOpenSession = false
    private var completionNeedsRetry = false
    private var hasJournaledSession = false
    private var activatedAt: Date?

    init(journal: StateJournal, operations: Operations, beforeMutation: @escaping () throws -> Void = {}) {
        self.journal = journal
        self.operations = operations
        self.beforeMutation = beforeMutation
    }

    func prepareForLaunch(restoreAutomatically: Bool, repairLegacyOverride: Bool = false) throws {
        if restoreAutomatically {
            try recover(repairLegacyOverride: repairLegacyOverride)
            return
        }
        switch journal.inspect() {
        case .missing, .clean: break
        case .pending:
            throw Failure.message("A previous session needs recovery. Automatic recovery is off; choose Retry Recovery.")
        case .invalid(let message): throw Failure.message(message)
        }
        try repairLegacyFunctionKeyOverrideIfNeeded(enabled: repairLegacyOverride)
    }

    /// Every recovery entry point finishes the whole pending session before any
    /// optional repair. Repairs use the same durable checkpoint and restore path.
    func recover(_ intent: Intent = .interruptedSession, repairLegacyOverride: Bool = false) throws {
        try restore()
        switch intent {
        case .interruptedSession, .normalSettings:
            try repairLegacyFunctionKeyOverrideIfNeeded(enabled: repairLegacyOverride)
            if case .normalSettings = intent { try performRepair(operations.normalFunctionKeyRecovery()) }
        case .removeFunctionKeyOverride(let expected):
            try performRepair(operations.functionKeyOverrideRemoval(expected))
        }
    }

    private func performRepair(_ changes: AppliedChanges) throws {
        guard changes.hasPendingChanges else { return }
        try activate(.init(isActive: true, activatedAt: Date(), appliedChanges: changes)) {}
        try restore()
    }

    func repairLegacyFunctionKeyOverrideIfNeeded(enabled: Bool) throws {
        try repairLegacyFunctionKeyOverrideIfNeeded(enabled: enabled, needsRepair: operations.needsLegacyFunctionKeyRepair)
    }

    func activate(_ state: GameModeState, apply: () throws -> Void) throws {
        guard !hasOpenSession && !completionNeedsRetry else { throw Failure.message("A Game Mode session is already pending.") }
        switch journal.inspect() {
        case .pending: throw JournalError.pendingRecovery
        case .invalid(let reason): throw JournalError.invalid(reason)
        case .missing, .clean: break
        }
        if state.appliedChanges.hasPendingChanges {
            try journal.begin(state)
            hasJournaledSession = true
        }
        hasOpenSession = true
        activatedAt = state.activatedAt
        // The checkpoint and independent helper are ready before the first setter.
        if hasJournaledSession { try beforeMutation() }
        try apply()
    }

    private func ensureJournaledSession(changes: AppliedChanges = .empty) throws {
        guard hasOpenSession else { throw Failure.message("Enable Game Mode before changing settings.") }
        guard !hasJournaledSession else { return }
        try journal.begin(.init(isActive: true, activatedAt: activatedAt, appliedChanges: changes))
        hasJournaledSession = true
    }

    func recordDisplayChange(_ record: DisplayRecoveryRecord) throws {
        try ensureJournaledSession()
        let state = try journal.load()
        if let existing = state.appliedChanges.displayRestores.first(where: { $0.displayUUID == record.displayUUID }) {
            guard existing == record else { throw JournalError.changedBaseline }
        } else {
            try journal.update { $0.appliedChanges.displayRestores.append(record) }
        }
        try beforeMutation()
    }

    /// Run only outside a gaming session, after its original settings are restored.
    /// The durable intent survives a crash between deleting the override and applying HID mode.
    func repairLegacyFunctionKeyOverrideIfNeeded(enabled: Bool, needsRepair: () throws -> Bool) throws {
        guard enabled else { return }
        guard !hasOpenSession && !completionNeedsRetry else { throw Failure.message("Finish recovery before repairing function keys.") }
        switch journal.inspect() {
        case .missing, .clean: break
        case .pending: throw Failure.message("Finish recovery before repairing function keys.")
        case .invalid(let message): throw Failure.message(message)
        }
        guard try needsRepair() else { return }
        var changes = AppliedChanges.empty
        changes.legacyFunctionKeyCleanupPending = true
        try activate(.init(isActive: true, activatedAt: Date(), appliedChanges: changes)) {}
        try restore()
    }

    /// Change only Input Guard within an open Game Mode session. Reuse the
    /// existing setters, and never recapture an original until its restore commits.
    func updateInputGuard(_ policy: InputGuardPolicy, capture: (InputGuardPolicy) throws -> SettingsManager.KeyboardSnapshot, apply: (SettingsManager.KeyboardSnapshot) throws -> Void) throws {
        guard hasOpenSession else { throw Failure.message("Enable Game Mode before applying Input Guard.") }
        try restoreInputGuard()
        guard !policy.isEmpty else { return }
        let snapshot = try capture(policy)
        let requiresRecovery = snapshot.functionKeysChanged || !snapshot.gesturesToDisable.isEmpty
        var changes = hasJournaledSession ? try journal.load().appliedChanges : .empty
        changes.functionKeysChanged = snapshot.functionKeysChanged
        changes.previousFunctionKeysEnabled = snapshot.previousFunctionKeysEnabled
        changes.functionKeysWerePersisted = false
        changes.functionKeyContext = snapshot.functionKeyContext
        changes.disabledShortcutIDs = snapshot.shortcutIDsToDisable
        changes.previousShortcutStates = snapshot.previousShortcutStates
        changes.shortcutsWerePersisted = false
        changes.gesturesChanged = !snapshot.gesturesToDisable.isEmpty
        changes.previousGestureValues = snapshot.previousGestureValues
        if hasJournaledSession { try journal.update { $0.appliedChanges = changes } }
        else if requiresRecovery { try ensureJournaledSession(changes: changes) }
        if requiresRecovery { try beforeMutation() }
        try apply(snapshot)
    }

    func restoreInputGuard() throws {
        let errors = try restoreInputGuardSettings()
        guard errors.isEmpty else { throw Failure.message(errors.joined(separator: "\n")) }
    }

    /// Setting-level failures can be accumulated during full recovery. Storage
    /// failures must still stop the sequence before any further system changes.
    private func restoreInputGuardSettings() throws -> [String] {
        operations.stopOwnedEffects()
        let state = try journal.load()
        guard state.isActive else {
            if hasOpenSession && hasJournaledSession { throw Failure.message("The recovery snapshot is missing.") }
            return []
        }
        let changes = state.appliedChanges
        guard changes.functionKeysChanged || changes.legacyFunctionKeyCleanupPending || changes.functionKeyOverrideRemoval != nil || changes.gesturesChanged || !changes.disabledShortcutIDs.isEmpty || changes.previousShortcutStates != nil else { return [] }
        let errors = operations.restoreKeyboard(changes)
        guard errors.isEmpty else { return errors }
        try journal.update {
            $0.appliedChanges.functionKeysChanged = false
            $0.appliedChanges.previousFunctionKeysEnabled = nil
            $0.appliedChanges.functionKeysWerePersisted = false
            $0.appliedChanges.legacyFunctionKeyCleanupPending = false
            $0.appliedChanges.functionKeyContext = nil
            $0.appliedChanges.functionKeyOverrideRemoval = nil
            $0.appliedChanges.gesturesChanged = false
            $0.appliedChanges.previousGestureValues = nil
            $0.appliedChanges.disabledShortcutIDs = []
            $0.appliedChanges.previousShortcutStates = nil
        }
        return []
    }

    func applyMouseProfile(speed: Double) throws {
        guard hasOpenSession else { throw Failure.message("Enable Game Mode before applying the Mouse Preset.") }
        guard speed.isFinite else { throw Failure.message("The configured tracking speed is invalid.") }
        let state = try journal.load()
        if hasJournaledSession && !state.isActive { throw Failure.message("The recovery snapshot is missing. Mouse settings were not changed.") }
        if !state.appliedChanges.mouseSpeedChanged {
            guard let baseline = operations.readMouse(), baseline.isFinite else {
                throw Failure.message("The current tracking speed could not be read. Mouse settings were not changed.")
            }
            guard abs(baseline - speed) >= 0.001 else { return }
            try ensureJournaledSession()
            try journal.update {
                $0.appliedChanges.mouseSpeedChanged = true
                $0.appliedChanges.previousMouseSpeed = baseline
            }
        }
        try beforeMutation()
        guard operations.applyMouse(speed), mouseMatches(speed) else {
            throw Failure.message("The Mouse Preset could not be confirmed. Its original speed is saved for recovery.")
        }
    }

    func restoreMouseProfile() throws {
        let state = try journal.load()
        guard state.isActive else {
            if hasOpenSession && hasJournaledSession { throw Failure.message("The recovery snapshot is missing.") }
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
        operations.stopOwnedEffects()
        var state = try journal.load()
        guard state.isActive else {
            if completionNeedsRetry, journal.inspect() == .clean {
                // The manifest may have been replaced before its final flush
                // failed. Recommit the clean authority without replaying setters.
                try completeSession()
                return
            }
            if hasOpenSession && hasJournaledSession { throw Failure.message("The recovery snapshot is missing. Review your system settings before continuing.") }
            if completionNeedsRetry { throw Failure.message("The recovery completion record is missing. Review your system settings before continuing.") }
            // Display activity overlays also belong to this process and need
            // stopping on normal deactivation, even when no mode was changed.
            let failures = operations.stopDisplays()
            guard failures.isEmpty else { throw Failure.message(failures.joined(separator: "\n")) }
            hasOpenSession = false
            activatedAt = nil
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
        hasJournaledSession = false
        activatedAt = nil
    }

    func reset() throws {
        try restore()
        try journal.reset()
    }

    /// A reviewed file is an explicit restore request. If local recovery data is
    /// damaged, preserve it before accepting the selected file as a new intent.
    /// Restoring saved values does not require a working background service.
    func restoreBackup(_ backup: RecoveryBackup, settings: Set<RecoveryBackup.Setting>) throws {
        try backup.validate()
        guard !settings.isEmpty, settings.isSubset(of: backup.settings) else { throw Failure.message("Choose at least one saved setting to restore.") }
        let changes: AppliedChanges
        if case .invalid = journal.inspect() {
            // Validate/capture before archiving damaged evidence. An unreadable
            // setting must not consume the user's remaining recovery record.
            changes = try operations.prepareImportedSettings(backup.selecting(settings))
            try journal.archiveAndReset()
            hasOpenSession = false
            hasJournaledSession = false
            completionNeedsRetry = false
        } else {
            try restore()
            changes = try operations.prepareImportedSettings(backup.selecting(settings))
        }
        guard changes.hasPendingChanges else { return }
        try journal.begin(.init(isActive: true, activatedAt: Date(), appliedChanges: changes))
        hasOpenSession = true
        hasJournaledSession = true
        try restore()
    }

    func acceptCurrentSettings() throws {
        try journal.archiveAndReset()
        completionNeedsRetry = false
        hasOpenSession = false
        hasJournaledSession = false
        activatedAt = nil
    }

    private func mouseMatches(_ expected: Double) -> Bool {
        guard let actual = operations.readMouse(), actual.isFinite else { return false }
        return abs(actual - expected) < 0.001
    }
}
