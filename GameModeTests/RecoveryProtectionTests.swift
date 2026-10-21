//
//  RecoveryProtectionTests.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ServiceManagement
import XCTest
@testable import GameMode

final class RecoveryProtectionTests: XCTestCase {
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testRecoveryPrefersNewSavedChoicesAndLeavesManagedOrExternallyChangedModesAlone() {
        let baseline = FunctionKeyPreferences(global: false, host: nil)
        let context = FunctionKeyRecoveryContext(preferences: baseline, appliedMode: true, bootSession: "before")
        XCTAssertEqual(context.restorationTarget(original: false, current: true, preferences: baseline, bootSession: "before"), false)
        XCTAssertEqual(context.restorationTarget(original: false, current: true, preferences: .init(global: true, host: nil), bootSession: "before"), true)
        XCTAssertEqual(context.restorationTarget(original: false, current: false, preferences: .init(global: true, host: nil), bootSession: "before"), true)
        XCTAssertEqual(context.restorationTarget(original: false, current: true, preferences: .init(global: false, host: true), bootSession: "before"), true)
        XCTAssertNil(context.restorationTarget(original: false, current: true, preferences: .init(global: false, host: nil, isManaged: true), bootSession: "before"))
        XCTAssertNil(context.restorationTarget(original: false, current: false, preferences: baseline, bootSession: "before"))
        XCTAssertNil(context.restorationTarget(original: false, current: true, preferences: .init(global: nil, host: nil), bootSession: "before"))
    }

    func testRestartReconcilesNormalPreferenceInsteadOfReplayingOldLiveMode() {
        let preferences = FunctionKeyPreferences(global: false, host: nil)
        let context = FunctionKeyRecoveryContext(preferences: preferences, appliedMode: false, bootSession: "old-boot")
        XCTAssertEqual(context.restorationTarget(original: true, current: false, preferences: preferences, bootSession: "old-boot"), true)
        XCTAssertNil(context.restorationTarget(original: true, current: false, preferences: preferences, bootSession: "new-boot"))
    }

    func testMediaProfileAppliesTemporarilyAndRestoresItsOriginalWithoutPreferenceWrites() throws {
        var live = true
        var writes: [Bool] = []
        let preferences = FunctionKeyPreferences(global: true, host: nil)
        let manager = SettingsManager(functionKeys: .init(read: { live }, apply: { live = $0; writes.append($0); return true },
                                                        bootSession: { "boot" }, readPreferences: { preferences }))
        let snapshot = try manager.captureKeyboardSettings(functionKeyBehavior: .media, shortcutIDs: [], gestures: [])
        var changes = AppliedChanges.empty
        changes.functionKeysChanged = snapshot.functionKeysChanged
        changes.previousFunctionKeysEnabled = snapshot.previousFunctionKeysEnabled
        changes.functionKeyContext = snapshot.functionKeyContext
        try manager.applyKeyboardSettings(snapshot)
        XCTAssertFalse(live)
        XCTAssertTrue(manager.restoreKeyboardSettings(from: changes).isEmpty)
        XCTAssertTrue(live)
        XCTAssertEqual(writes, [false, true])
    }

    func testNewPreferenceBetweenCheckpointAndApplyPreventsTemporaryMutation() throws {
        var preferences = FunctionKeyPreferences(global: false, host: nil)
        var writes = 0
        let manager = SettingsManager(functionKeys: .init(read: { false }, apply: { _ in writes += 1; return true },
                                                        readPreferences: { preferences }))
        let snapshot = try manager.captureKeyboardSettings(functionKeyBehavior: .standard, shortcutIDs: [], gestures: [])
        preferences.global = true
        XCTAssertThrowsError(try manager.applyKeyboardSettings(snapshot))
        XCTAssertEqual(writes, 0)
    }

    func testHelperReadinessFailureLeavesCheckpointButNeverCallsSetter() throws {
        let journal = StateJournal(directory: directory)
        var setterCalled = false
        var changes = AppliedChanges.empty
        changes.functionKeysChanged = true
        changes.previousFunctionKeysEnabled = false
        let recovery = RecoveryController(journal: journal, operations: .init(stopDisplays: { [] }, restoreDisplays: { _ in [] }, restoreKeyboard: { _ in [] }, restorePower: { _ in [] }, readMouse: { nil }, applyMouse: { _ in false }), beforeMutation: {
            XCTAssertEqual(try journal.load().appliedChanges, changes)
            throw RecoveryController.Failure.message("Helper unavailable")
        })
        XCTAssertThrowsError(try recovery.activate(.init(isActive: true, activatedAt: nil, appliedChanges: changes)) { setterCalled = true })
        XCTAssertFalse(setterCalled)
        XCTAssertEqual(try journal.load().appliedChanges, changes)
    }

    func testStaleReadinessCannotAuthorizeAnotherChallengeOrBoot() throws {
        let files = RecoveryAgentFiles(support: directory)
        let first = RecoveryAgentFiles.Challenge(nonce: UUID(), bootSession: RecoveryIdentity.bootSession)
        try files.write(first, to: files.challengeURL)
        try files.acknowledge()
        XCTAssertTrue(files.isReady(for: first))
        XCTAssertFalse(files.isReady(for: .init(nonce: UUID(), bootSession: first.bootSession)))
        XCTAssertFalse(files.isReady(for: .init(nonce: first.nonce, bootSession: "another-boot")))
        XCTAssertThrowsError(try CrashRecoveryProtection.handshake(files: files, timeout: 0.01))
    }

    func testFirstLaunchRegistersMissingServiceAndRespectsRequiredApproval() throws {
        for initial: SMAppService.Status in [.notFound, .notRegistered] {
            var status = initial
            var registrations = 0
            try CrashRecoveryProtection.registerIfNeeded(status: { status }, register: { registrations += 1; status = .enabled })
            XCTAssertEqual(registrations, 1)
        }
        XCTAssertThrowsError(try CrashRecoveryProtection.registerIfNeeded(status: { .requiresApproval }, register: { XCTFail("Do not bypass approval") }))
        XCTAssertNoThrow(try CrashRecoveryProtection.registerIfNeeded(status: { .enabled }, register: { XCTFail("Already registered") }))
    }

    func testRecoveryContextCannotBeReplacedWhileOriginalIsPending() throws {
        let journal = StateJournal(directory: directory)
        var changes = AppliedChanges.empty
        changes.functionKeysChanged = true
        changes.previousFunctionKeysEnabled = false
        changes.functionKeyContext = .init(preferences: .init(global: false, host: nil), appliedMode: true, bootSession: "boot")
        try journal.begin(.init(isActive: true, activatedAt: nil, appliedChanges: changes))
        XCTAssertThrowsError(try journal.update { $0.appliedChanges.functionKeyContext?.preferences.global = true })
        XCTAssertEqual(try journal.load().appliedChanges, changes)
    }

    func testPreferenceChangedDuringRestoreWinsOnVerifiedRetry() throws {
        var preferences = FunctionKeyPreferences(global: false, host: nil)
        var live = true
        var writes: [Bool] = []
        let manager = SettingsManager(functionKeys: .init(read: { live }, apply: { value in
            live = value
            writes.append(value)
            preferences.global = true
            return true
        }, bootSession: { "boot" }, readPreferences: { preferences }))
        var changes = AppliedChanges.empty
        changes.functionKeysChanged = true
        changes.previousFunctionKeysEnabled = false
        changes.functionKeyContext = .init(preferences: preferences, appliedMode: true, bootSession: "boot")
        XCTAssertFalse(manager.restoreKeyboardSettings(from: changes).isEmpty)
        XCTAssertTrue(manager.restoreKeyboardSettings(from: changes).isEmpty)
        XCTAssertTrue(live)
        XCTAssertEqual(preferences.global, true)
        XCTAssertEqual(writes, [false, true])
    }

    func testOverrideRemovalResumesAfterDeletionWithoutDeletingAgain() throws {
        var preferences = FunctionKeyPreferences(global: false, host: true)
        var live = true
        var canApply = false
        var removals = 0
        let manager = SettingsManager(functionKeys: .init(read: { live }, apply: { value in
            if canApply { live = value }
            return canApply
        }, readPreferences: { preferences }, removeOverride: { expected in
            XCTAssertEqual(expected, preferences)
            preferences.host = nil
            removals += 1
        }))
        let changes = try manager.overrideRemoval(expected: preferences)
        let journal = StateJournal(directory: directory)
        try journal.begin(.init(isActive: true, activatedAt: nil, appliedChanges: changes))
        let recovery = RecoveryController(journal: journal, operations: .init(stopDisplays: { [] }, restoreDisplays: { _ in [] }, restoreKeyboard: { manager.restoreKeyboardSettings(from: $0) }, restorePower: { _ in [] }, readMouse: { nil }, applyMouse: { _ in false }))
        XCTAssertThrowsError(try recovery.restore())
        XCTAssertEqual(try journal.load().appliedChanges.functionKeyOverrideRemoval, changes.functionKeyOverrideRemoval)
        XCTAssertNil(preferences.host)
        canApply = true
        try recovery.restore()
        XCTAssertEqual(removals, 1)
        XCTAssertFalse(live)
        XCTAssertEqual(journal.inspect(), .clean)
    }

    func testConfirmedOverrideRemovalCannotDeleteANewerChoice() throws {
        var preferences = FunctionKeyPreferences(global: false, host: true)
        let manager = SettingsManager(functionKeys: .init(read: { true }, apply: { _ in XCTFail("New preference must stay intact"); return false },
                                                        readPreferences: { preferences }, removeOverride: { _ in XCTFail("Must not delete a newer override") }))
        let changes = try manager.overrideRemoval(expected: preferences)
        preferences.host = false
        XCTAssertTrue(manager.restoreKeyboardSettings(from: changes).isEmpty)
        XCTAssertEqual(preferences.host, false)
    }

    func testThreeBehaviorChoicesPersistAndOldBooleanMigrates() throws {
        var config = GameModeConfig.defaults
        for choice in FunctionKeyBehavior.allCases {
            config.functionKeyBehavior = choice
            XCTAssertEqual(try JSONDecoder().decode(GameModeConfig.self, from: JSONEncoder().encode(config)), config)
        }
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
        old.removeValue(forKey: "functionKeyBehavior")
        old["functionKeysInGamingMode"] = true
        XCTAssertEqual(try JSONDecoder().decode(GameModeConfig.self, from: JSONSerialization.data(withJSONObject: old)).functionKeyBehavior, .standard)
    }
}
