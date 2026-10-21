//
//  RecoveryBackupTests.swift
//  GameMode
//
//  Created by OpenAI Codex on 20/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation
import Testing
@testable import GameMode

struct RecoveryBackupTests {
    private final class Machine {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lazy var journal = StateJournal(directory: directory)
        var speed = 0.4
        var mouseFails = false
        var checkpoints = 0
        var ownedEffectsStopped = 0
        var displaysStopped = 0
        var keyboardChanges: [AppliedChanges] = []
        var powerRestores: [[String: Int]] = []
        var displayRestores: [[DisplayRecoveryRecord]] = []
        var captured = AppliedChanges.empty
        deinit { try? FileManager.default.removeItem(at: directory) }

        var operations: RecoveryController.Operations {
            .init(stopDisplays: { self.displaysStopped += 1; return [] }, restoreDisplays: { self.displayRestores.append($0); return [] },
                  restoreKeyboard: { self.keyboardChanges.append($0); return [] }, restorePower: { self.powerRestores.append($0); return [] },
                  readMouse: { self.speed }, applyMouse: { value in
                      if self.mouseFails { return false }
                      self.speed = value
                      return true
                  }, stopOwnedEffects: { self.ownedEffectsStopped += 1 }, captureRecoverySettings: { self.captured })
        }
        func engine(helperFails: Bool = false) -> RecoveryController {
            RecoveryController(journal: journal, operations: operations, beforeMutation: {
                self.checkpoints += 1
                #expect(try self.journal.load().appliedChanges.hasPendingChanges)
                if helperFails { throw RecoveryController.Failure.message("Helper unavailable") }
            })
        }
    }

    private func originals() -> AppliedChanges {
        let gesture = GestureEntry.defaults[0]
        return AppliedChanges(functionKeysChanged: true, previousFunctionKeysEnabled: false, disabledShortcutIDs: [],
                              mouseSpeedChanged: true, previousMouseSpeed: 0.3, gesturesChanged: true,
                              previousGestureValues: [gesture.id: [gesture.domains[0]: 2]], lowPowerModeChanged: true,
                              previousLowPowerModeSettings: ["b": 1, "c": 0], displayRestores: [.init(displayUUID: "display", displayName: "Monitor", mode: .init(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, ioFlags: 0, modeID: 1))])
    }

    @Test func shortcutOnlySessionDoesNotRequireFilesOrHelperAndStopsOwnedEffects() throws {
        let machine = Machine()
        let engine = machine.engine(helperFails: true)
        var changes = AppliedChanges.empty
        changes.disabledShortcutIDs = [64]
        changes.previousShortcutStates = [64: true]
        var applied = false
        try engine.activate(.init(isActive: true, activatedAt: Date(), appliedChanges: changes)) { applied = true }
        #expect(applied && engine.hasOpenSession)
        #expect(machine.checkpoints == 0)
        #expect(machine.journal.inspect() == .missing)
        try engine.restore()
        #expect(machine.ownedEffectsStopped > 0 && machine.displaysStopped == 1)
        #expect(!engine.hasOpenSession && machine.journal.inspect() == .missing)
    }

    @Test func firstMouseChangeRequiresProtectionButAnUnchangedSpeedDoesNot() throws {
        let machine = Machine()
        let engine = machine.engine(helperFails: true)
        try engine.activate(.init(isActive: true, activatedAt: Date(), appliedChanges: .empty)) {}
        try engine.applyMouseProfile(speed: 0.4)
        #expect(machine.checkpoints == 0 && machine.journal.inspect() == .missing)
        #expect(throws: (any Error).self) { try engine.applyMouseProfile(speed: 1.2) }
        #expect(machine.speed == 0.4 && machine.checkpoints == 1)
        #expect(try machine.journal.load().appliedChanges.previousMouseSpeed == 0.4)
    }

    @Test func firstDisplayModeChangeCommitsOriginalBeforeCheckingHelper() throws {
        let machine = Machine()
        let engine = machine.engine(helperFails: true)
        try engine.activate(.init(isActive: true, activatedAt: Date(), appliedChanges: .empty)) {}
        let record = originals().displayRestores[0]
        #expect(throws: (any Error).self) { try engine.recordDisplayChange(record) }
        #expect(try machine.journal.load().appliedChanges.displayRestores == [record])
        #expect(machine.checkpoints == 1)
    }

    @Test func fileRoundTripChecksIntegrityIdentityAndAllowedSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Settings.gamemoderecovery")
        let backup = try RecoveryBackup(changes: originals())
        try backup.write(to: url)
        #expect(try RecoveryBackup.read(from: url) == backup)
        #expect(throws: (any Error).self) { try backup.validate(machine: "different-Mac") }
        #expect(throws: (any Error).self) { try backup.validate(user: backup.user + 1) }
        var invalid = backup
        invalid.changes.previousGestureValues = [GestureEntry.defaults[0].id: ["com.unrelated.application": 1]]
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = backup
        invalid.changes.previousLowPowerModeSettings = ["unrecognized": 1]
        #expect(throws: (any Error).self) { try invalid.validate() }
        var encoded = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        encoded["checksum"] = "incorrect"
        try JSONSerialization.data(withJSONObject: encoded).write(to: url)
        #expect(throws: (any Error).self) { try RecoveryBackup.read(from: url) }
        try Data(repeating: 0, count: 2_000_001).write(to: url)
        #expect(throws: (any Error).self) { try RecoveryBackup.read(from: url) }
    }

    @Test func exportUsesOriginalValuesForEveryActiveFeature() throws {
        let machine = Machine()
        machine.captured = originals()
        machine.captured.previousMouseSpeed = 1.9
        machine.captured.previousFunctionKeysEnabled = true
        machine.captured.previousLowPowerModeSettings = ["b": 0, "c": 0]
        let pending = originals()
        try machine.journal.begin(.init(isActive: true, activatedAt: Date(), appliedChanges: pending))
        let backup = try machine.engine().backup()
        #expect(backup.changes == pending)
        #if FEATURE_DISPLAYS
        #expect(backup.settings == [.functionKeys, .mouse, .gestures, .displays, .power])
        #else
        #expect(backup.settings == [.functionKeys, .mouse, .gestures])
        #endif
    }

    @Test func fileRestoreAppliesOnlyReviewedSelectionsAndNeedsNoHelper() throws {
        let machine = Machine()
        let backup = try RecoveryBackup(changes: originals())
        let selected = backup.settings.intersection([.mouse, .power])
        try machine.engine(helperFails: true).restoreBackup(backup, settings: selected)
        let expectedPower = selected.contains(.power) ? [["b": 1, "c": 0]] : []
        #expect(machine.speed == 0.3 && machine.powerRestores == expectedPower)
        #expect(machine.keyboardChanges.isEmpty && machine.displayRestores.isEmpty && machine.checkpoints == 0)
        #expect(machine.journal.inspect() == .clean)
    }

    @Test func interruptedFileRestoreResumesThroughTheCrashEngine() throws {
        let machine = Machine()
        machine.mouseFails = true
        let backup = try RecoveryBackup(changes: originals())
        let selected = backup.settings.intersection([.mouse, .power])
        #expect(throws: (any Error).self) { try machine.engine().restoreBackup(backup, settings: selected) }
        let pending = try machine.journal.load().appliedChanges
        #expect(pending.mouseSpeedChanged && pending.previousMouseSpeed == 0.3 && !pending.lowPowerModeChanged)
        machine.mouseFails = false
        try machine.engine().recover()
        #expect(machine.speed == 0.3 && machine.powerRestores.count == (selected.contains(.power) ? 1 : 0))
        #expect(machine.journal.inspect() == .clean)
    }

    #if !FEATURE_DISPLAYS
    @Test func fileRecoveryCannotSelectDisabledDisplayOrPowerFeatures() throws {
        let machine = Machine()
        let backup = try RecoveryBackup(changes: originals())
        for setting: RecoveryBackup.Setting in [.displays, .power] {
            #expect(throws: (any Error).self) { try machine.engine().restoreBackup(backup, settings: [setting]) }
        }
        #expect(machine.journal.inspect() == .missing)
        #expect(machine.powerRestores.isEmpty && machine.displayRestores.isEmpty)
    }
    #endif

    @Test func reviewedFileCanRecoverDamagedLocalDataWithoutDiscardingEvidence() throws {
        let machine = Machine()
        try FileManager.default.createDirectory(at: machine.directory, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: machine.directory.appendingPathComponent("manifest.json"))
        let backup = try RecoveryBackup(changes: originals())
        try machine.engine().restoreBackup(backup, settings: [.mouse])
        #expect(machine.speed == 0.3 && machine.journal.inspect() == .clean)
        let evidence = try FileManager.default.contentsOfDirectory(at: machine.directory.appendingPathComponent("archives"), includingPropertiesForKeys: nil)
        #expect(evidence.count == 1)
        #expect(try Data(contentsOf: evidence[0].appendingPathComponent("manifest.json")) == Data("damaged".utf8))
    }

    @Test func newerKeyboardPreferencesWinOverAnOlderRecoveryFile() throws {
        var mode = true
        var preferences = FunctionKeyPreferences(global: false, host: nil)
        var writes = 0
        let manager = SettingsManager(functionKeys: .init(read: { mode }, apply: { mode = $0; writes += 1; return true }, readPreferences: { preferences }, removeLegacyPreference: {}))
        var saved = AppliedChanges.empty
        saved.functionKeysChanged = true
        saved.previousFunctionKeysEnabled = false
        saved.functionKeyContext = .init(preferences: preferences, appliedMode: true, bootSession: RecoveryIdentity.bootSession)
        preferences.global = true
        let prepared = try manager.prepareImportedSettings(saved)
        #expect(!prepared.functionKeysChanged)
        #expect(writes == 0 && mode)
        saved.functionKeyContext = nil
        let legacyPrepared = try manager.prepareImportedSettings(saved)
        #expect(!legacyPrepared.functionKeysChanged)
        #expect(writes == 0 && mode)
    }

    @Test func exportIncludesTheStandaloneAppAndPreservesItsExecutable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RecoveryKit.standaloneAppURL
        let sourceExecutable = try #require(Bundle(url: source)?.executableURL)
        let executable = try Data(contentsOf: sourceExecutable)
        let backup = try RecoveryBackup(changes: originals())
        let file = directory.appendingPathComponent("Settings.gamemoderecovery")
        try RecoveryKit.exportBackup(backup, to: file)
        let exported = directory.appendingPathComponent("GameMode Recovery.app")
        let exportedBundle = try #require(Bundle(url: exported))
        #expect(exportedBundle.bundleIdentifier == "com.moshyn.nikita.GameMode.RecoveryTool")
        #expect(try Data(contentsOf: #require(exportedBundle.executableURL)) == executable)
        #expect(try RecoveryBackup.read(from: file) == backup)
        // Exporting again is safe and leaves the signed template unchanged.
        try RecoveryKit.exportBackup(backup, to: file)
        #expect(try Data(contentsOf: sourceExecutable) == executable)
    }
}
