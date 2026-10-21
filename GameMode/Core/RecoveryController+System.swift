//
//  RecoveryController+System.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

extension RecoveryController {
    /// One native adapter for the app, independent helper, and recovery kit.
    /// The helper never prompts for power authorization or retries displays
    /// outside the process lock; the interactive app opts into those behaviors.
    static func system(journal: StateJournal, settings: SettingsManager = SettingsManager(), displays: RefreshRateLock = RefreshRateLock(), interactive: Bool = false, automaticDisplayRecovery: Bool = false, beforeMutation: @escaping () throws -> Void = {}) -> RecoveryController {
        if !automaticDisplayRecovery { displays.pauseAutomaticRecovery() }
        let controller = RecoveryController(journal: journal, operations: .init(
            stopDisplays: { displays.stop().failedDisplays },
            restoreDisplays: { displays.restorePersistedDisplayModes($0) },
            restoreKeyboard: { settings.restoreKeyboardSettings(from: $0) },
            restorePower: { PowerManager.restoreLowPowerModeSettings($0, allowAuthorization: interactive) },
            readMouse: { settings.readCurrentMouseSpeed() },
            applyMouse: { settings.applyMouseSpeed($0) },
            stopOwnedEffects: { settings.stopOwnedEffects() },
            needsLegacyFunctionKeyRepair: { try settings.needsLegacyFunctionKeyRepair() },
            normalFunctionKeyRecovery: { try settings.normalFunctionKeyRecovery() },
            functionKeyOverrideRemoval: { try settings.overrideRemoval(expected: $0) },
            captureRecoverySettings: {
                #if FEATURE_DISPLAYS
                var changes = settings.captureRecoverySettings()
                changes.displayRestores = displays.captureRecoverySettings()
                if let power = PowerManager.captureLowPowerModeSettings(), !power.isEmpty {
                    changes.lowPowerModeChanged = true
                    changes.previousLowPowerModeSettings = power
                }
                return changes
                #else
                return settings.captureRecoverySettings()
                #endif
            },
            prepareImportedSettings: { try settings.prepareImportedSettings($0) }
        ), beforeMutation: beforeMutation)
        // Every entry point, including the helper and exported app, must commit
        // each verified display restore before removing its in-memory original.
        displays.willChangeDisplay = { [weak controller] record in
            guard let controller else { throw Failure.message("The recovery engine is unavailable.") }
            try controller.recordDisplayChange(record)
        }
        displays.didRestoreDisplay = { uuid in
            try journal.update { $0.appliedChanges.displayRestores.removeAll { $0.displayUUID == uuid } }
        }
        return controller
    }

    /// Standalone recovery uses the app's saved policy only for its live journal.
    static func savedLegacyRepairPolicy(for journal: StateJournal) -> Bool {
        guard journal.directory == StateJournal.shared.directory,
              let data = UserDefaults(suiteName: "com.moshyn.nikita.GameMode")?.data(forKey: "GameModeConfig_v2"),
              let config = try? JSONDecoder().decode(GameModeConfig.self, from: data) else { return false }
        return config.system.repairLegacyFunctionKeyOverride
    }

    func exportKit(to destination: URL) throws {
        try RecoveryKit.exportBackup(backup(), to: destination)
    }

    func backup() throws -> RecoveryBackup {
        var changes = operations.captureRecoverySettings()
        // While gaming, export the originals, never the temporary gaming values.
        let pending = try journal.load().appliedChanges
        if pending.functionKeysChanged {
            changes.functionKeysChanged = true
            changes.previousFunctionKeysEnabled = pending.previousFunctionKeysEnabled
            changes.functionKeyContext = pending.functionKeyContext
        }
        if pending.mouseSpeedChanged { changes.mouseSpeedChanged = true; changes.previousMouseSpeed = pending.previousMouseSpeed }
        if pending.gesturesChanged {
            changes.gesturesChanged = true
            changes.previousGestureValues = (changes.previousGestureValues ?? [:]).merging(pending.previousGestureValues ?? [:]) { _, original in original }
        }
        if pending.lowPowerModeChanged { changes.lowPowerModeChanged = true; changes.previousLowPowerModeSettings = pending.previousLowPowerModeSettings }
        for display in pending.displayRestores {
            changes.displayRestores.removeAll { $0.displayUUID == display.displayUUID }
            changes.displayRestores.append(display)
        }
        if pending.shortcutsWerePersisted {
            changes.shortcutsWerePersisted = true
            changes.previousShortcutStates = pending.previousShortcutStates
        }
        return try RecoveryBackup(changes: changes)
    }
}
