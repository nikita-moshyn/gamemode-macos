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
        var legacySaveSucceeds = true
        var reads = 0
        var writes: [Bool] = []
        var preferenceWrites: [Bool] = []

        var access: SettingsManager.FunctionKeyAccess {
            .init(read: { self.reads += 1; return self.activeMode }, apply: { enabled in
                self.writes.append(enabled)
                if self.applySucceeds && !self.ignoresWrites { self.activeMode = enabled }
                return self.applySucceeds
            }, restoreLegacyPreference: { enabled in
                self.preferenceWrites.append(enabled)
                if self.legacySaveSucceeds { self.savedPreference = enabled }
                return self.legacySaveSucceeds
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
        .init(functionKeysChanged: snapshot.functionKeysChanged, previousFunctionKeysEnabled: snapshot.previousFunctionKeysEnabled,
              disabledShortcutIDs: [], mouseSpeedChanged: false, previousMouseSpeed: nil)
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
            XCTAssertTrue(keyboard.preferenceWrites.isEmpty)
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
        XCTAssertTrue(keyboard.preferenceWrites.isEmpty)
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
        XCTAssertTrue(keyboard.preferenceWrites.isEmpty)
    }

    func testUnreadableModeStopsCaptureWithoutInventingAnOriginal() {
        let keyboard = Keyboard()
        keyboard.activeMode = nil
        keyboard.savedPreference = false
        let manager = SettingsManager(functionKeys: keyboard.access)
        XCTAssertThrowsError(try capture(manager))
        XCTAssertTrue(keyboard.writes.isEmpty)
        XCTAssertTrue(keyboard.preferenceWrites.isEmpty)
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
        XCTAssertTrue(keyboard.preferenceWrites.isEmpty)
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
        XCTAssertTrue(keyboard.preferenceWrites.isEmpty)
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
        XCTAssertTrue(keyboard.preferenceWrites.isEmpty)
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

    func testBetaJournalRestoresItsSavedPreferenceAndLiveMode() throws {
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

        keyboard.legacySaveSucceeds = false
        XCTAssertThrowsError(try recovery.restore())
        XCTAssertTrue(try journal.load().appliedChanges.functionKeysWerePersisted)
        XCTAssertEqual(try journal.load().appliedChanges.previousFunctionKeysEnabled, false)
        XCTAssertEqual(keyboard.activeMode, false)
        keyboard.legacySaveSucceeds = true
        try recovery.restore()
        XCTAssertEqual(journal.inspect(), .clean)
        XCTAssertEqual(keyboard.savedPreference, false)
        XCTAssertEqual(keyboard.preferenceWrites, [false, false])
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
}
