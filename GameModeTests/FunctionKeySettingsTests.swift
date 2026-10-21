//
//  FunctionKeySettingsTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 13/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import XCTest
@testable import GameMode

final class FunctionKeySettingsTests: XCTestCase {
    private final class Keyboard {
        var activeMode: Bool? = false
        var savedPreference: Bool?
        var applySucceeds = true
        var ignoresWrites = false
        var reads = 0
        var writes: [Bool] = []
        var globalPreference: Bool? = false
        var isManaged = false
        var preferenceReadFails = false
        var preferenceReads = 0
        var removals = 0
        var removalSucceeds = true
        var beforeRemoval: () throws -> Void = {}
        var afterRemoval: () throws -> Void = {}

        var access: SettingsManager.FunctionKeyAccess {
            .init(read: { self.reads += 1; return self.activeMode }, apply: { enabled in
                self.writes.append(enabled)
                if self.applySucceeds && !self.ignoresWrites { self.activeMode = enabled }
                return self.applySucceeds
            }, readPreferences: {
                self.preferenceReads += 1
                if self.preferenceReadFails { throw RecoveryController.Failure.message("Simulated unreadable preferences") }
                return .init(global: self.globalPreference, host: self.savedPreference, isManaged: self.isManaged)
            }, removeLegacyPreference: {
                try self.beforeRemoval()
                guard self.globalPreference == false, self.savedPreference == true, !self.isManaged else { return }
                self.removals += 1
                if self.removalSucceeds { self.savedPreference = nil }
                try self.afterRemoval()
            })
        }
    }

    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func capture(_ manager: SettingsManager) throws -> SettingsManager.KeyboardSnapshot {
        try manager.captureKeyboardSettings(functionKeysEnabled: true, shortcutIDs: [], gestures: [])
    }

    private func changes(_ snapshot: SettingsManager.KeyboardSnapshot) -> AppliedChanges {
        var result = AppliedChanges(functionKeysChanged: snapshot.functionKeysChanged, previousFunctionKeysEnabled: snapshot.previousFunctionKeysEnabled,
                                    disabledShortcutIDs: [], mouseSpeedChanged: false, previousMouseSpeed: nil)
        result.functionKeyContext = snapshot.functionKeyContext
        return result
    }

    private func controller(_ manager: SettingsManager, journal: StateJournal) -> RecoveryController {
        .init(journal: journal, operations: .init(stopDisplays: { [] }, restoreDisplays: { _ in [] },
                                                restoreKeyboard: { manager.restoreKeyboardSettings(from: $0) },
                                                restorePower: { _ in [] }, readMouse: { nil }, applyMouse: { _ in false }))
    }

    func testStalePreferencesCannotSuppressActivationAndSavedPreferencesStayUntouched() throws {
        for savedPreference: Bool? in [nil, false, true] {
            let keyboard = Keyboard()
            keyboard.savedPreference = savedPreference
            let manager = SettingsManager(functionKeys: keyboard.access)
            let snapshot = try capture(manager)
            XCTAssertTrue(snapshot.functionKeysChanged)
            XCTAssertEqual(snapshot.previousFunctionKeysEnabled, false)

            try manager.applyKeyboardSettings(snapshot)
            XCTAssertEqual(keyboard.activeMode, true)
            XCTAssertTrue(manager.restoreKeyboardSettings(from: changes(snapshot)).isEmpty)
            XCTAssertEqual(keyboard.activeMode, false)
            XCTAssertEqual(keyboard.writes, [true, false])
            XCTAssertEqual(keyboard.savedPreference, savedPreference)
        }
    }

    func testAlreadyStandardKeysArePreservedEvenWhenSavedPreferenceSaysMedia() throws {
        let keyboard = Keyboard()
        keyboard.activeMode = true
        keyboard.savedPreference = false
        let manager = SettingsManager(functionKeys: keyboard.access)
        let snapshot = try capture(manager)
        XCTAssertFalse(snapshot.functionKeysChanged)
        XCTAssertEqual(snapshot.previousFunctionKeysEnabled, true)
        try manager.applyKeyboardSettings(snapshot)
        XCTAssertTrue(manager.restoreKeyboardSettings(from: changes(snapshot)).isEmpty)
        XCTAssertEqual(keyboard.activeMode, true)
        XCTAssertTrue(keyboard.writes.isEmpty)
    }

    func testUnselectedFunctionKeysNeverReadOrWriteTheKeyboard() throws {
        let keyboard = Keyboard()
        keyboard.activeMode = nil
        let manager = SettingsManager(functionKeys: keyboard.access)
        let snapshot = try manager.captureKeyboardSettings(functionKeysEnabled: false, shortcutIDs: [], gestures: [])
        try manager.applyKeyboardSettings(snapshot)
        XCTAssertTrue(manager.restoreKeyboardSettings(from: changes(snapshot)).isEmpty)
        XCTAssertEqual(keyboard.reads, 0)
        XCTAssertTrue(keyboard.writes.isEmpty)
    }

    func testUnreadableModeStopsCaptureWithoutInventingAnOriginal() {
        let keyboard = Keyboard()
        keyboard.activeMode = nil
        keyboard.savedPreference = false
        let manager = SettingsManager(functionKeys: keyboard.access)
        XCTAssertThrowsError(try capture(manager))
        XCTAssertTrue(keyboard.writes.isEmpty)
        XCTAssertFalse(manager.verifyFunctionKeysEnabled(false, timeout: 0))
    }

    func testRejectedSetterCannotReportSuccessfulActivation() throws {
        let keyboard = Keyboard()
        keyboard.applySucceeds = false
        let manager = SettingsManager(functionKeys: keyboard.access)
        XCTAssertThrowsError(try manager.applyKeyboardSettings(capture(manager)))
        XCTAssertEqual(keyboard.writes, [true])
        XCTAssertEqual(keyboard.activeMode, false)
    }

    func testSuccessfulSetterWithUnchangedHardwareKeepsCheckpointForRecovery() throws {
        let keyboard = Keyboard()
        keyboard.savedPreference = true
        keyboard.ignoresWrites = true
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory)
        let recovery = controller(manager, journal: journal)
        let snapshot = try capture(manager)
        let original = changes(snapshot)
        XCTAssertThrowsError(try recovery.activate(.init(isActive: true, activatedAt: nil, appliedChanges: original)) {
            XCTAssertEqual(try journal.load().appliedChanges, original)
            try manager.applyKeyboardSettings(snapshot)
        })
        XCTAssertEqual(try journal.load().appliedChanges, original)
        XCTAssertTrue(recovery.hasOpenSession)
        keyboard.ignoresWrites = false
        try recovery.restore()
        XCTAssertEqual(journal.inspect(), .clean)
        XCTAssertEqual(keyboard.activeMode, false)
    }

    func testFailedRestoreKeepsOriginalForRetryAfterRestart() throws {
        let keyboard = Keyboard()
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory)
        let recovery = controller(manager, journal: journal)
        let snapshot = try capture(manager)
        try recovery.activate(.init(isActive: true, activatedAt: nil, appliedChanges: changes(snapshot))) {
            try manager.applyKeyboardSettings(snapshot)
        }
        keyboard.ignoresWrites = true
        XCTAssertThrowsError(try recovery.restore())
        XCTAssertEqual(try journal.load().appliedChanges.previousFunctionKeysEnabled, false)
        XCTAssertTrue(try journal.load().appliedChanges.functionKeysChanged)
        XCTAssertEqual(keyboard.activeMode, true)

        keyboard.ignoresWrites = false
        let restarted = controller(manager, journal: StateJournal(directory: directory))
        try restarted.prepareForLaunch(restoreAutomatically: true)
        XCTAssertEqual(journal.inspect(), .clean)
        XCTAssertEqual(keyboard.activeMode, false)
    }

    func testLiveCheckboxOffRestoresKeysAndLeavesGameModeActive() throws {
        let keyboard = Keyboard()
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory)
        let recovery = controller(manager, journal: journal)
        try recovery.activate(.init(isActive: true, activatedAt: nil, appliedChanges: .empty)) {}
        try recovery.updateInputGuard(.init(functionKeysEnabled: true, shortcutIDs: [], gestures: []), capture: { _ in
            try self.capture(manager)
        }, apply: { snapshot in
            XCTAssertEqual(try journal.load().appliedChanges.previousFunctionKeysEnabled, false)
            XCTAssertFalse(try journal.load().appliedChanges.functionKeysWerePersisted)
            try manager.applyKeyboardSettings(snapshot)
        })
        XCTAssertEqual(keyboard.activeMode, true)
        try recovery.updateInputGuard(.disabled, capture: { _ in XCTFail("Disabled policy cannot capture"); return try self.capture(manager) }, apply: { _ in XCTFail("Disabled policy cannot apply") })
        XCTAssertEqual(keyboard.activeMode, false)
        XCTAssertTrue(recovery.hasOpenSession)
        XCTAssertTrue(try journal.load().isActive)
        XCTAssertFalse(try journal.load().appliedChanges.functionKeysChanged)
    }

    func testUnreadableModeDuringLiveEditNeverAppliesOrRecordsAnOriginal() throws {
        let keyboard = Keyboard()
        keyboard.activeMode = nil
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory)
        let recovery = controller(manager, journal: journal)
        try recovery.activate(.init(isActive: true, activatedAt: nil, appliedChanges: .empty)) {}
        XCTAssertThrowsError(try recovery.updateInputGuard(.init(functionKeysEnabled: true, shortcutIDs: [], gestures: []), capture: { _ in
            try self.capture(manager)
        }, apply: { _ in XCTFail("Cannot apply without a readable baseline") }))
        XCTAssertEqual(try journal.load().appliedChanges, .empty)
        XCTAssertTrue(keyboard.writes.isEmpty)
    }

    func testBetaJournalHonorsNewerNormalPreferenceWithoutReinstatingHostOverride() throws {
        let legacy = Data(#"{"functionKeysChanged":true,"previousFunctionKeysEnabled":false,"disabledShortcutIDs":[],"mouseSpeedChanged":false}"#.utf8)
        let original = try JSONDecoder().decode(AppliedChanges.self, from: legacy)
        XCTAssertTrue(original.functionKeysWerePersisted)
        let keyboard = Keyboard()
        keyboard.activeMode = true
        keyboard.savedPreference = true
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory)
        try journal.begin(.init(isActive: true, activatedAt: nil, appliedChanges: original))
        let recovery = controller(manager, journal: journal)

        keyboard.applySucceeds = false
        XCTAssertThrowsError(try recovery.restore())
        XCTAssertTrue(try journal.load().appliedChanges.functionKeysWerePersisted)
        XCTAssertEqual(try journal.load().appliedChanges.previousFunctionKeysEnabled, false)
        XCTAssertEqual(keyboard.activeMode, true)
        keyboard.globalPreference = true
        keyboard.applySucceeds = true
        try recovery.restore()
        XCTAssertEqual(journal.inspect(), .clean)
        XCTAssertEqual(keyboard.activeMode, true)
        XCTAssertEqual(keyboard.savedPreference, true)
        XCTAssertEqual(keyboard.writes, [false])
    }

    func testPendingJournalCannotLoseItsPreferenceRestorationRequirement() throws {
        let journal = StateJournal(directory: directory)
        let original = AppliedChanges(functionKeysChanged: true, previousFunctionKeysEnabled: false,
                                      disabledShortcutIDs: [], mouseSpeedChanged: false, previousMouseSpeed: nil,
                                      functionKeysWerePersisted: true)
        try journal.begin(.init(isActive: true, activatedAt: nil, appliedChanges: original))
        XCTAssertThrowsError(try journal.update { $0.appliedChanges.functionKeysWerePersisted = false })
        XCTAssertEqual(try journal.load().appliedChanges, original)
    }

    private func repair(_ recovery: RecoveryController, manager: SettingsManager, enabled: Bool = true) throws {
        try recovery.repairLegacyFunctionKeyOverrideIfNeeded(enabled: enabled, needsRepair: manager.needsLegacyFunctionKeyRepair)
    }

    func testCleanupCheckpointsBeforeDeletingOnlyConflictingOverrideAndIsIdempotent() throws {
        let keyboard = Keyboard()
        keyboard.activeMode = true
        keyboard.savedPreference = true
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory)
        let recovery = controller(manager, journal: journal)
        keyboard.beforeRemoval = {
            XCTAssertTrue(try journal.load().appliedChanges.legacyFunctionKeyCleanupPending)
            XCTAssertFalse(try journal.load().appliedChanges.functionKeysChanged)
        }
        try repair(recovery, manager: manager)
        XCTAssertNil(keyboard.savedPreference)
        XCTAssertEqual(keyboard.globalPreference, false)
        XCTAssertEqual(keyboard.activeMode, false)
        XCTAssertEqual(keyboard.removals, 1)
        XCTAssertEqual(keyboard.writes, [false])
        XCTAssertEqual(journal.inspect(), .clean)
        let completed = try Data(contentsOf: journal.manifestURL)
        try repair(recovery, manager: manager)
        XCTAssertEqual(keyboard.removals, 1)
        XCTAssertEqual(keyboard.writes, [false])
        XCTAssertEqual(try Data(contentsOf: journal.manifestURL), completed)
    }

    func testCleanupNeverGuessesMissingPreferencesOrChangesIntentionalStandardKeys() throws {
        for global: Bool? in [nil, false, true] {
            for host: Bool? in [nil, false, true] where global != false || host != true {
                let keyboard = Keyboard()
                keyboard.globalPreference = global
                keyboard.savedPreference = host
                keyboard.activeMode = true
                let manager = SettingsManager(functionKeys: keyboard.access)
                let journal = StateJournal(directory: directory)
                try repair(controller(manager, journal: journal), manager: manager)
                XCTAssertEqual(keyboard.savedPreference, host)
                XCTAssertEqual(keyboard.activeMode, true)
                XCTAssertEqual(keyboard.removals, 0)
                XCTAssertTrue(keyboard.writes.isEmpty)
                XCTAssertEqual(journal.inspect(), .missing)
            }
        }
    }

    func testCleanupRequiresPermissionAndLeavesManagedPreferencesAlone() throws {
        let keyboard = Keyboard()
        keyboard.savedPreference = true
        let manager = SettingsManager(functionKeys: keyboard.access)
        let recovery = controller(manager, journal: StateJournal(directory: directory))
        try repair(recovery, manager: manager, enabled: false)
        XCTAssertEqual(keyboard.preferenceReads, 0)
        keyboard.isManaged = true
        try repair(recovery, manager: manager)
        XCTAssertEqual(keyboard.removals, 0)
        XCTAssertEqual(keyboard.reads, 0)
        XCTAssertTrue(keyboard.writes.isEmpty)
    }

    func testCleanupCannotTouchPreferencesWithPendingSessionOrInvalidJournal() throws {
        let keyboard = Keyboard()
        keyboard.savedPreference = true
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory)
        let recovery = controller(manager, journal: journal)
        var original = AppliedChanges.empty
        original.functionKeysChanged = true
        original.previousFunctionKeysEnabled = false
        try recovery.activate(.init(isActive: true, activatedAt: nil, appliedChanges: original)) {}
        XCTAssertThrowsError(try repair(recovery, manager: manager))
        XCTAssertEqual(try journal.load().appliedChanges, original)
        let restarted = controller(manager, journal: journal)
        XCTAssertThrowsError(try repair(restarted, manager: manager))
        try Data("invalid".utf8).write(to: journal.manifestURL)
        XCTAssertThrowsError(try repair(restarted, manager: manager))
        XCTAssertEqual(keyboard.preferenceReads, 0)
        XCTAssertEqual(keyboard.removals, 0)
        XCTAssertTrue(keyboard.writes.isEmpty)
    }

    func testUnreadablePreferencesOrKeyboardPreventCleanupBeforeCheckpoint() throws {
        let keyboard = Keyboard()
        keyboard.savedPreference = true
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory)
        let recovery = controller(manager, journal: journal)
        keyboard.preferenceReadFails = true
        XCTAssertThrowsError(try repair(recovery, manager: manager))
        keyboard.preferenceReadFails = false
        keyboard.activeMode = nil
        XCTAssertThrowsError(try repair(recovery, manager: manager))
        XCTAssertEqual(journal.inspect(), .missing)
        XCTAssertEqual(keyboard.savedPreference, true)
        XCTAssertEqual(keyboard.removals, 0)
        XCTAssertTrue(keyboard.writes.isEmpty)
    }

    func testFailedCleanupCheckpointMakesNoSystemChanges() throws {
        let keyboard = Keyboard()
        keyboard.savedPreference = true
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory, writer: { _, _ in throw JournalError.io("test checkpoint", 5) })
        XCTAssertThrowsError(try repair(controller(manager, journal: journal), manager: manager))
        XCTAssertEqual(keyboard.savedPreference, true)
        XCTAssertEqual(keyboard.removals, 0)
        XCTAssertTrue(keyboard.writes.isEmpty)
    }

    func testCrashAfterDeletingOverrideResumesLiveModeRepairOnNextLaunch() throws {
        let keyboard = Keyboard()
        keyboard.activeMode = true
        keyboard.savedPreference = true
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory)
        let recovery = controller(manager, journal: journal)
        keyboard.afterRemoval = { throw JournalError.io("simulated crash after deletion", 5) }
        XCTAssertThrowsError(try repair(recovery, manager: manager))
        XCTAssertNil(keyboard.savedPreference)
        XCTAssertEqual(keyboard.activeMode, true)
        XCTAssertTrue(try journal.load().appliedChanges.legacyFunctionKeyCleanupPending)
        XCTAssertThrowsError(try journal.complete())
        keyboard.afterRemoval = {}
        let restarted = controller(manager, journal: StateJournal(directory: directory))
        try restarted.prepareForLaunch(restoreAutomatically: true)
        XCTAssertEqual(keyboard.activeMode, false)
        XCTAssertEqual(keyboard.removals, 1)
        XCTAssertEqual(journal.inspect(), .clean)
    }

    func testFailedPreferenceDeletionOrHardwareWriteKeepsCleanupForRetry() throws {
        let keyboard = Keyboard()
        keyboard.activeMode = true
        keyboard.savedPreference = true
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory)
        let recovery = controller(manager, journal: journal)
        keyboard.removalSucceeds = false
        XCTAssertThrowsError(try repair(recovery, manager: manager))
        XCTAssertTrue(keyboard.writes.isEmpty)
        XCTAssertTrue(try journal.load().appliedChanges.legacyFunctionKeyCleanupPending)
        keyboard.removalSucceeds = true
        keyboard.applySucceeds = false
        XCTAssertThrowsError(try recovery.restore())
        XCTAssertNil(keyboard.savedPreference)
        XCTAssertTrue(try journal.load().appliedChanges.legacyFunctionKeyCleanupPending)
        keyboard.applySucceeds = true
        try recovery.restore()
        XCTAssertEqual(keyboard.activeMode, false)
        XCTAssertEqual(journal.inspect(), .clean)
    }

    func testChangedNormalPreferenceDuringCleanupOrBeforeRetryIsPreserved() throws {
        for changeBeforeDeletion in [true, false] {
            let keyboard = Keyboard()
            keyboard.activeMode = true
            keyboard.savedPreference = true
            let manager = SettingsManager(functionKeys: keyboard.access)
            let journal = StateJournal(directory: directory.appendingPathComponent(UUID().uuidString))
            let recovery = controller(manager, journal: journal)
            if changeBeforeDeletion {
                keyboard.beforeRemoval = { keyboard.globalPreference = true }
                try repair(recovery, manager: manager)
                XCTAssertEqual(keyboard.savedPreference, true)
                XCTAssertEqual(keyboard.removals, 0)
            } else {
                keyboard.afterRemoval = { throw JournalError.io("simulated crash", 5) }
                XCTAssertThrowsError(try repair(recovery, manager: manager))
                keyboard.globalPreference = true
                try controller(manager, journal: journal).prepareForLaunch(restoreAutomatically: true)
            }
            XCTAssertEqual(keyboard.activeMode, true)
            XCTAssertTrue(keyboard.writes.isEmpty)
            XCTAssertEqual(journal.inspect(), .clean)
        }
    }

    func testPendingCleanupYieldsToExplicitHostPreferenceManagementOrMissingNormalPreference() throws {
        for change in 0..<3 {
            let keyboard = Keyboard()
            keyboard.activeMode = true
            keyboard.savedPreference = true
            let manager = SettingsManager(functionKeys: keyboard.access)
            let journal = StateJournal(directory: directory.appendingPathComponent(UUID().uuidString))
            keyboard.afterRemoval = { throw JournalError.io("simulated crash", 5) }
            XCTAssertThrowsError(try repair(controller(manager, journal: journal), manager: manager))
            switch change {
            case 0: keyboard.savedPreference = false
            case 1: keyboard.isManaged = true
            default: keyboard.globalPreference = nil
            }
            try controller(manager, journal: journal).prepareForLaunch(restoreAutomatically: true)
            XCTAssertEqual(keyboard.activeMode, true)
            XCTAssertTrue(keyboard.writes.isEmpty)
            XCTAssertEqual(journal.inspect(), .clean)
        }
    }

    func testMalformedCleanupCannotReplaceAnUnrestoredOriginalFunctionKeyMode() {
        let keyboard = Keyboard()
        keyboard.activeMode = true
        keyboard.savedPreference = true
        let manager = SettingsManager(functionKeys: keyboard.access)
        var pending = AppliedChanges.empty
        pending.functionKeysChanged = true
        pending.previousFunctionKeysEnabled = true
        pending.legacyFunctionKeyCleanupPending = true
        XCTAssertFalse(manager.restoreKeyboardSettings(from: pending).isEmpty)
        XCTAssertEqual(keyboard.preferenceReads, 0)
        XCTAssertEqual(keyboard.removals, 0)
        XCTAssertTrue(keyboard.writes.isEmpty)
    }

    @MainActor
    func testEngineCleansAfterStartupRecoveryBeforeCapturingNextGamingBaseline() async throws {
        let keyboard = Keyboard()
        keyboard.activeMode = true
        keyboard.savedPreference = true
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory)
        var interrupted = AppliedChanges.empty
        interrupted.functionKeysChanged = true
        interrupted.previousFunctionKeysEnabled = true
        interrupted.functionKeysWerePersisted = true
        try journal.begin(.init(isActive: true, activatedAt: nil, appliedChanges: interrupted))
        let engine = GameEngine(journal: journal, settingsManager: manager, protection: .testing)
        var config = GameModeConfig.defaults
        config.system.repairLegacyFunctionKeyOverride = true
        config.isInputGuardEnabled = true
        config.functionKeysInGamingMode = true
        config.mouse.isEnabled = false
        config.display.autoDisableLowPowerMode = false
        let startup = GameEngineClient.Request(id: 1, operation: .startup)
        var context = GameEngineClient.Context(config: config, session: .init(), request: startup, needsDisplay: false)
        let (client, session) = engine.clients { context }
        var response: GameEngineClient.Response?
        await client.execute(startup) { response = $0 }
        guard case .completed = response else { return XCTFail("Startup cleanup failed: \(String(describing: response))") }
        XCTAssertEqual(keyboard.activeMode, false)
        XCTAssertNil(keyboard.savedPreference)
        XCTAssertEqual(journal.inspect(), .clean)

        let enable = GameSession.Transition(id: 1, isEnabled: true)
        context.session = .init(phase: .transitioning(enable), desiredMode: true)
        var transitionResponse: GameSessionClient.Response?
        await session.execute(enable) { transitionResponse = $0 }
        XCTAssertEqual(transitionResponse, .completed(.applied))
        XCTAssertEqual(try journal.load().appliedChanges.previousFunctionKeysEnabled, false)
        XCTAssertEqual(keyboard.activeMode, true)
        XCTAssertNil(keyboard.savedPreference, "A normal session must not recreate a persistent override")

        let disable = GameSession.Transition(id: 2, isEnabled: false)
        context.session = .init(phase: .transitioning(disable), desiredMode: false, appliedMode: true)
        await session.execute(disable) { transitionResponse = $0 }
        XCTAssertEqual(transitionResponse, .completed(.applied))
        XCTAssertEqual(keyboard.activeMode, false)
        XCTAssertNil(keyboard.savedPreference)
        XCTAssertEqual(journal.inspect(), .clean)
    }

    @MainActor
    func testEngineAlwaysRecoversBeforeLegacyCleanupEvenWithOldLaunchPreferenceDisabled() async throws {
        let keyboard = Keyboard()
        keyboard.savedPreference = true
        let manager = SettingsManager(functionKeys: keyboard.access)
        let journal = StateJournal(directory: directory)
        let pending = GameModeState(isActive: true, activatedAt: nil, appliedChanges: .empty)
        try journal.begin(pending)
        let engine = GameEngine(journal: journal, settingsManager: manager, protection: .testing)
        var config = GameModeConfig.defaults
        config.system.restoreOnLaunch = false
        config.system.repairLegacyFunctionKeyOverride = true
        let request = GameEngineClient.Request(id: 1, operation: .startup)
        let context = GameEngineClient.Context(config: config, session: .init(), request: request, needsDisplay: false)
        let (client, _) = engine.clients { context }
        var response: GameEngineClient.Response?
        await client.execute(request) { response = $0 }
        guard case .completed = response else { return XCTFail("Crash recovery must be automatic regardless of the old preference") }
        XCTAssertEqual(keyboard.removals, 1)
        XCTAssertNil(keyboard.savedPreference)
        XCTAssertEqual(journal.inspect(), .clean)
    }
}
