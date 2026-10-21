//
//  RecoverySystemTests.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation
import Testing
@testable import GameMode

struct RecoverySystemTests {
    private final class Machine {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lazy var journal = StateJournal(directory: directory)
        var speed = 1.5
        var mouseFails = false
        var overrideRemovalFails = false
        var restoredDisplays = false
        var restoredKeyboard = false
        var restoredPower = false
        var repairCaptures = 0
        var checkpoints = 0
        var removedPreferences: FunctionKeyPreferences?

        deinit { try? FileManager.default.removeItem(at: directory) }

        var operations: RecoveryController.Operations {
            .init(stopDisplays: { [] }, restoreDisplays: { _ in
                self.restoredDisplays = true
                return []
            }, restoreKeyboard: { changes in
                if changes.functionKeyOverrideRemoval != nil && self.overrideRemovalFails { return ["Override removal failed"] }
                self.restoredKeyboard = true
                return []
            }, restorePower: { _ in
                self.restoredPower = true
                return []
            }, readMouse: { self.speed }, applyMouse: { value in
                if self.mouseFails { return false }
                self.speed = value
                return true
            }, normalFunctionKeyRecovery: {
                // Additional repairs cannot start while another feature remains pending.
                #expect(self.journal.inspect() == .clean)
                #expect(self.speed == 0.3)
                self.repairCaptures += 1
                var changes = AppliedChanges.empty
                changes.functionKeysChanged = true
                changes.previousFunctionKeysEnabled = false
                return changes
            }, functionKeyOverrideRemoval: { expected in
                #expect(self.journal.inspect() == .clean)
                self.removedPreferences = expected
                var changes = AppliedChanges.empty
                changes.functionKeyOverrideRemoval = .init(expected: expected)
                return changes
            })
        }

        func engine() -> RecoveryController {
            RecoveryController(journal: journal, operations: operations, beforeMutation: {
                self.checkpoints += 1
                let pending = try self.journal.load().appliedChanges
                #expect(pending.hasPendingChanges)
            })
        }

        func beginWholeSession() throws {
            var changes = AppliedChanges.empty
            changes.functionKeysChanged = true
            changes.previousFunctionKeysEnabled = false
            changes.mouseSpeedChanged = true
            changes.previousMouseSpeed = 0.3
            changes.lowPowerModeChanged = true
            changes.previousLowPowerModeSettings = ["AC Power": 0, "Battery Power": 1]
            changes.displayRestores = [.init(displayUUID: "display", displayName: "Display", mode: .init(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, ioFlags: 0, modeID: 1))]
            try journal.begin(.init(isActive: true, activatedAt: Date(), appliedChanges: changes))
        }
    }

    @Test func normalRestorationCoversTheWholeSessionBeforeOptionalRepairs() throws {
        let machine = Machine()
        try machine.beginWholeSession()
        try machine.engine().recover(.normalSettings)
        #expect(machine.restoredDisplays && machine.restoredKeyboard && machine.restoredPower)
        #expect(machine.speed == 0.3)
        #expect(machine.repairCaptures == 1)
        #expect(machine.checkpoints == 1)
        #expect(machine.journal.inspect() == .clean)
    }

    @Test func failedFeatureKeepsItsOriginalAndBlocksAdditionalRepairs() throws {
        let machine = Machine()
        try machine.beginWholeSession()
        machine.mouseFails = true
        let engine = machine.engine()
        #expect(throws: (any Error).self) { try engine.recover(.normalSettings) }
        #expect(machine.repairCaptures == 0)
        let pending = try machine.journal.load().appliedChanges
        #expect(pending.mouseSpeedChanged && pending.previousMouseSpeed == 0.3)
        #expect(!pending.functionKeysChanged && !pending.lowPowerModeChanged && pending.displayRestores.isEmpty)
        machine.mouseFails = false
        try engine.recover(.normalSettings)
        #expect(machine.repairCaptures == 1)
        #expect(machine.journal.inspect() == .clean)
    }

    @Test func overrideRemovalResumesThroughTheSameEngineAfterInterruption() throws {
        let machine = Machine()
        try machine.beginWholeSession()
        let expected = FunctionKeyPreferences(global: false, host: true)
        machine.overrideRemovalFails = true
        #expect(throws: (any Error).self) { try machine.engine().recover(.removeFunctionKeyOverride(expected)) }
        #expect(machine.removedPreferences == expected)
        #expect(machine.speed == 0.3)
        #expect(machine.checkpoints == 1)
        #expect(try machine.journal.load().appliedChanges.functionKeyOverrideRemoval?.expected == expected)
        machine.overrideRemovalFails = false
        try machine.engine().recover()
        #expect(machine.repairCaptures == 0)
        #expect(machine.journal.inspect() == .clean)
    }

    @MainActor @Test func systemAdapterCheckpointsDisplayRecoveryAcrossAppHelperAndStandaloneInstances() throws {
        let machine = Machine()
        let displays = RefreshRateLock()
        let engine = RecoveryController.system(journal: machine.journal, displays: displays)
        try engine.activate(.init(isActive: true, activatedAt: Date(), appliedChanges: .empty)) {}
        let first = DisplayRecoveryRecord(displayUUID: "first", displayName: "First", mode: .init(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, ioFlags: 0, modeID: 1))
        var second = first
        second.displayUUID = "second"
        let checkpoint = try #require(displays.willChangeDisplay)
        try checkpoint(first)
        try checkpoint(second)
        #expect(try machine.journal.load().appliedChanges.displayRestores == [first, second])
        let completed = try #require(displays.didRestoreDisplay)
        try completed(first.displayUUID)
        #expect(try machine.journal.load().appliedChanges.displayRestores == [second])

        // A fresh helper or exported app must finish the same durable record
        // without depending on GameEngine's initialization or display setters.
        let standaloneDisplays = RefreshRateLock()
        let standalone = RecoveryController.system(journal: machine.journal, displays: standaloneDisplays)
        let standaloneCompleted = try #require(standaloneDisplays.didRestoreDisplay)
        try standaloneCompleted(second.displayUUID)
        try standalone.recover()
        #expect(machine.journal.inspect() == .clean)
        withExtendedLifetime(engine) {}
    }

    @MainActor @Test func failedSystemDisplayCheckpointRetainsOriginalUntilRetryCommits() throws {
        let machine = Machine()
        var rejectWrites = false
        let journal = StateJournal(directory: machine.directory, writer: { data, url in
            if rejectWrites { throw CocoaError(.fileWriteUnknown) }
            try StateJournal.writeDurably(data, to: url)
        })
        let displays = RefreshRateLock()
        let engine = RecoveryController.system(journal: journal, displays: displays)
        let original = DisplayRecoveryRecord(displayUUID: "original", displayName: "Display", mode: .init(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, ioFlags: 0, modeID: 1))
        var changes = AppliedChanges.empty
        changes.displayRestores = [original]
        try journal.begin(.init(isActive: true, activatedAt: Date(), appliedChanges: changes))
        let checkpoint = try #require(displays.didRestoreDisplay)
        rejectWrites = true
        #expect(throws: (any Error).self) { try checkpoint(original.displayUUID) }
        #expect(try journal.load().appliedChanges.displayRestores == [original])
        rejectWrites = false
        try checkpoint(original.displayUUID)
        try engine.recover()
        #expect(journal.inspect() == .clean)
    }
}
