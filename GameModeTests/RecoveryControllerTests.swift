//
//  RecoveryControllerTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 11/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import CoreGraphics
import XCTest
@testable import GameMode

final class RecoveryControllerTests: XCTestCase {
    private var directory: URL!
    private var journal: StateJournal!
    private var machine: FakeMachine!
    private var controller: RecoveryController!

    private final class FakeMachine {
        var speed = 0.3
        var keyboardFailures: [String] = []
        var displayFailures: [String] = []
        var powerFailures: [String] = []
        var keyboardCalls = 0
        var mouseCalls = 0
        var powerCalls = 0
        var ignoresMouseWrites = false
        var restoredPower: [String: Int]?

        var operations: RecoveryController.Operations {
            .init(stopDisplays: { [] }, restoreDisplays: { _ in self.displayFailures },
                  restoreKeyboard: { _ in self.keyboardCalls += 1; return self.keyboardFailures },
                  restorePower: { self.powerCalls += 1; self.restoredPower = $0; return self.powerFailures },
                  readMouse: { self.speed }, applyMouse: { speed in
                      self.mouseCalls += 1
                      if !self.ignoresMouseWrites { self.speed = speed }
                      return true
                  })
        }
    }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        journal = StateJournal(directory: directory)
        machine = FakeMachine()
        controller = RecoveryController(journal: journal, operations: machine.operations)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func state(_ changes: AppliedChanges = .empty) -> GameModeState {
        GameModeState(isActive: true, activatedAt: Date(), appliedChanges: changes)
    }

    private func inputSnapshot(gestureValue: Int? = 4) -> SettingsManager.KeyboardSnapshot {
        var gesture = GestureEntry.defaults[0]
        gesture.disableInGamingMode = true
        return SettingsManager.KeyboardSnapshot(functionKeysChanged: true, previousFunctionKeysEnabled: false,
                                                previousShortcutStates: [64: true], shortcutIDsToDisable: [64],
                                                previousGestureValues: [gesture.id: [gesture.domains[0]: gestureValue]],
                                                gesturesToDisable: [gesture])
    }

    private var inputPolicy: InputGuardPolicy {
        InputGuardPolicy(functionKeysEnabled: true, shortcutIDs: [64], gestures: inputSnapshot().gesturesToDisable)
    }

    func test_inputGuardRequiresAnActiveSession() {
        var captures = 0
        var applications = 0
        XCTAssertThrowsError(try controller.updateInputGuard(inputPolicy, capture: { _ in
            captures += 1
            return self.inputSnapshot()
        }, apply: { _ in applications += 1 }))
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(applications, 0)
        XCTAssertEqual(journal.inspect(), .missing)
    }

    func test_inputGuardOffHasNoEffectsAndSelectedInputsCommitBeforeApplication() throws {
        try controller.activate(state()) {}
        try controller.updateInputGuard(.disabled, capture: { _ in
            XCTFail("Disabled Input Guard must not capture settings")
            return self.inputSnapshot()
        }, apply: { _ in XCTFail("Disabled Input Guard must not apply settings") })
        XCTAssertEqual(machine.keyboardCalls, 0)

        let snapshot = inputSnapshot()
        var applications = 0
        try controller.updateInputGuard(inputPolicy, capture: { policy in
            XCTAssertEqual(policy, self.inputPolicy)
            return snapshot
        }, apply: { _ in
            let saved = try self.journal.load().appliedChanges
            XCTAssertEqual(saved.previousFunctionKeysEnabled, false)
            XCTAssertEqual(saved.previousShortcutStates, [64: true])
            XCTAssertEqual(saved.previousGestureValues, snapshot.previousGestureValues)
            XCTAssertFalse(saved.shortcutsWerePersisted)
            applications += 1
        })
        XCTAssertEqual(applications, 1)
    }

    func test_inputGuardOffKeepsGameModeAndOtherFeatureOriginals() throws {
        var otherChanges = AppliedChanges.empty
        otherChanges.mouseSpeedChanged = true
        otherChanges.previousMouseSpeed = 0.3
        otherChanges.lowPowerModeChanged = true
        otherChanges.previousLowPowerModeSettings = ["b": 1, "c": 0]
        otherChanges.displayRestores = [DisplayRecoveryRecord(displayUUID: "display", displayName: "Display",
                                                            mode: RecoveryDisplayMode(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, ioFlags: 0, modeID: 1))]
        try controller.activate(state(otherChanges)) {}
        try controller.updateInputGuard(inputPolicy, capture: { _ in self.inputSnapshot() }, apply: { _ in })
        try controller.updateInputGuard(.disabled, capture: { _ in
            XCTFail("Turning Input Guard off must not capture another baseline")
            return self.inputSnapshot()
        }, apply: { _ in XCTFail("Turning Input Guard off must not apply settings") })
        XCTAssertEqual(try journal.load().appliedChanges, otherChanges)
        XCTAssertTrue(try journal.load().isActive)
        XCTAssertTrue(controller.hasOpenSession)
        XCTAssertEqual(machine.keyboardCalls, 1)
        XCTAssertEqual(machine.mouseCalls, 0)
        XCTAssertEqual(machine.powerCalls, 0)
    }

    func test_inputGuardFailedRestorePreservesOriginalsAndPreventsRecapture() throws {
        try controller.activate(state()) {}
        try controller.updateInputGuard(inputPolicy, capture: { _ in self.inputSnapshot() }, apply: { _ in })
        let before = try journal.load()
        machine.keyboardFailures = ["Gesture could not be restored"]
        XCTAssertThrowsError(try controller.updateInputGuard(inputPolicy, capture: { _ in
            XCTFail("Failed restoration must not replace originals")
            return self.inputSnapshot(gestureValue: 0)
        }, apply: { _ in XCTFail("Failed restoration must prevent application") }))
        XCTAssertEqual(try journal.load(), before)
    }

    func test_inputGuardCapturesFreshOriginalsAfterCommittedOffIncludingAbsentPreferences() throws {
        try controller.activate(state()) {}
        try controller.updateInputGuard(inputPolicy, capture: { _ in self.inputSnapshot() }, apply: { _ in })
        try controller.restoreInputGuard()
        let newBaseline = inputSnapshot(gestureValue: nil)
        try controller.updateInputGuard(inputPolicy, capture: { _ in newBaseline }, apply: { _ in })
        XCTAssertEqual(try journal.load().appliedChanges.previousGestureValues, newBaseline.previousGestureValues)
        XCTAssertEqual(machine.keyboardCalls, 1)
        try controller.restore()
        XCTAssertEqual(journal.inspect(), .clean)
        XCTAssertEqual(machine.keyboardCalls, 2)
    }

    func test_inputGuardCommitInterruptionsPreventApplicationAndRemainRecoverable() throws {
        for stage in [StateJournal.CommitStage.primarySnapshotCommitted, .mirrorSnapshotCommitted, .pendingManifestCommitted] {
            var interrupt = false
            let store = StateJournal(directory: directory.appendingPathComponent(UUID().uuidString), commitObserver: {
                if interrupt && $0 == stage { throw JournalError.io("interrupted input checkpoint", 5) }
            })
            let subject = RecoveryController(journal: store, operations: machine.operations)
            try subject.activate(state()) {}
            interrupt = true
            XCTAssertThrowsError(try subject.updateInputGuard(inputPolicy, capture: { _ in self.inputSnapshot() }, apply: { _ in
                XCTFail("A failed checkpoint must prevent input changes")
            }))
            interrupt = false
            let pending = try store.load().appliedChanges
            if stage == .pendingManifestCommitted {
                XCTAssertEqual(pending.previousGestureValues, inputSnapshot().previousGestureValues)
                XCTAssertEqual(pending.previousFunctionKeysEnabled, false)
            } else {
                XCTAssertEqual(pending, .empty)
            }
            try RecoveryController(journal: store, operations: machine.operations).restore()
            XCTAssertEqual(store.inspect(), .clean)
        }
    }

    func test_inputGuardFailedRestoreCommitPreventsFreshCapture() throws {
        var interrupt = false
        let store = StateJournal(directory: directory, commitObserver: {
            if interrupt && $0 == .primarySnapshotCommitted { throw JournalError.io("interrupted restore checkpoint", 5) }
        })
        let subject = RecoveryController(journal: store, operations: machine.operations)
        try subject.activate(state()) {}
        try subject.updateInputGuard(inputPolicy, capture: { _ in self.inputSnapshot() }, apply: { _ in })
        let before = try store.load()
        interrupt = true
        XCTAssertThrowsError(try subject.updateInputGuard(inputPolicy, capture: { _ in
            XCTFail("Restoration must commit before capturing new originals")
            return self.inputSnapshot(gestureValue: 0)
        }, apply: { _ in XCTFail("Uncommitted restoration must prevent application") }))
        XCTAssertEqual(try store.load(), before)
        interrupt = false
        try subject.restore()
        XCTAssertEqual(store.inspect(), .clean)
    }

    func test_failedCheckpointPerformsNoSystemMutation() {
        let failing = StateJournal(directory: directory, writer: { _, _ in throw JournalError.io("test write", 5) })
        let subject = RecoveryController(journal: failing, operations: machine.operations)
        var mutations = 0
        XCTAssertThrowsError(try subject.activate(state()) { mutations += 1 })
        XCTAssertEqual(mutations, 0)
    }

    func test_originalsAreReadableBeforeFirstMutationAndSurviveInterruptedApply() throws {
        let changes = AppliedChanges(functionKeysChanged: true, previousFunctionKeysEnabled: false,
                                     disabledShortcutIDs: [], mouseSpeedChanged: false, previousMouseSpeed: nil)
        XCTAssertThrowsError(try controller.activate(state(changes)) {
            XCTAssertEqual(try journal.load().appliedChanges.previousFunctionKeysEnabled, false)
            throw RecoveryController.Failure.message("Simulated interruption after first setter")
        })
        let restarted = RecoveryController(journal: journal, operations: machine.operations)
        try restarted.restore()
        XCTAssertEqual(machine.keyboardCalls, 1)
        XCTAssertEqual(journal.inspect(), .clean)
    }

    func test_partialRestoreRetainsFailuresAndDoesNotRepeatVerifiedMouseRestore() throws {
        let changes = AppliedChanges(functionKeysChanged: true, previousFunctionKeysEnabled: false,
                                     disabledShortcutIDs: [], mouseSpeedChanged: true, previousMouseSpeed: 0.3)
        try controller.activate(state(changes)) { machine.speed = 1.2 }
        machine.keyboardFailures = ["Function keys unavailable"]
        XCTAssertThrowsError(try controller.restore())
        let pending = try journal.load().appliedChanges
        XCTAssertTrue(pending.functionKeysChanged)
        XCTAssertFalse(pending.mouseSpeedChanged)
        XCTAssertEqual(machine.speed, 0.3)
        let calls = machine.mouseCalls
        machine.keyboardFailures = []
        try controller.restore()
        XCTAssertEqual(machine.mouseCalls, calls)
        XCTAssertEqual(journal.inspect(), .clean)
        try controller.restore()
        XCTAssertEqual(machine.keyboardCalls, 2)
    }

    func test_pendingOriginalsBlockNewSessionAndReset() throws {
        let changes = AppliedChanges(functionKeysChanged: true, previousFunctionKeysEnabled: false,
                                     disabledShortcutIDs: [], mouseSpeedChanged: false, previousMouseSpeed: nil)
        try controller.activate(state(changes)) {}
        let restarted = RecoveryController(journal: journal, operations: machine.operations)
        var mutations = 0
        XCTAssertThrowsError(try restarted.activate(state()) { mutations += 1 })
        machine.keyboardFailures = ["Cannot restore"]
        XCTAssertThrowsError(try restarted.reset())
        XCTAssertEqual(mutations, 0)
        XCTAssertEqual(try journal.load().appliedChanges.previousFunctionKeysEnabled, false)
    }

    func test_mouseProfileCyclesCaptureFreshBaselineOnlyAfterVerifiedOff() throws {
        try controller.activate(state()) {}
        try controller.applyMouseProfile(speed: 0.8)
        try controller.applyMouseProfile(speed: 1.2)
        XCTAssertEqual(try journal.load().appliedChanges.previousMouseSpeed, 0.3)
        try controller.restoreMouseProfile()
        XCTAssertEqual(machine.speed, 0.3)
        machine.speed = 1.5 // User's other normal mouse configuration.
        try controller.applyMouseProfile(speed: 0.8)
        XCTAssertEqual(try journal.load().appliedChanges.previousMouseSpeed, 1.5)
        try controller.restore()
        XCTAssertEqual(machine.speed, 1.5)
    }

    func test_mouseRestoreReadbackFailurePreservesOriginal() throws {
        try controller.activate(state()) {}
        try controller.applyMouseProfile(speed: 0.8)
        machine.ignoresMouseWrites = true
        XCTAssertThrowsError(try controller.restoreMouseProfile())
        XCTAssertTrue(try journal.load().appliedChanges.mouseSpeedChanged)
        XCTAssertEqual(try journal.load().appliedChanges.previousMouseSpeed, 0.3)
    }

    func test_mouseProfileCannotBeAppliedOutsideGameMode() {
        XCTAssertThrowsError(try controller.applyMouseProfile(speed: 0.8))
        XCTAssertEqual(machine.mouseCalls, 0)
        XCTAssertEqual(journal.inspect(), .missing)
    }

    func test_missingJournalDuringLiveSessionIsNotTreatedAsRestored() throws {
        try controller.activate(state()) {}
        try FileManager.default.removeItem(at: directory)
        XCTAssertThrowsError(try controller.restore())
        XCTAssertThrowsError(try controller.applyMouseProfile(speed: 0.8))
        XCTAssertEqual(machine.mouseCalls, 0)
    }

    func test_powerProfilesRestoredIndependently() throws {
        var changes = AppliedChanges.empty
        changes.lowPowerModeChanged = true
        changes.previousLowPowerModeSettings = ["b": 1, "c": 0, "u": 1]
        try controller.activate(state(changes)) {}
        try controller.restore()
        XCTAssertEqual(machine.restoredPower, ["b": 1, "c": 0, "u": 1])
        XCTAssertEqual(journal.inspect(), .clean)
    }

    func test_legacyPowerBooleanDoesNotInventPerSourceOriginals() throws {
        var changes = AppliedChanges.empty
        changes.lowPowerModeChanged = true
        changes.previousLowPowerModeEnabled = true
        try controller.activate(state(changes)) {}
        XCTAssertThrowsError(try controller.restore())
        XCTAssertTrue(try journal.load().appliedChanges.lowPowerModeChanged)
        XCTAssertEqual(machine.powerCalls, 0)
    }

    func test_missingDisplayStaysPendingUntilSuccessfulRetry() throws {
        var changes = AppliedChanges.empty
        changes.displayRestores = [DisplayRecoveryRecord(displayUUID: UUID().uuidString, displayName: "Display",
                                                         mode: RecoveryDisplayMode(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, ioFlags: 0, modeID: 1))]
        try controller.activate(state(changes)) {}
        machine.displayFailures = ["Display disconnected"]
        XCTAssertThrowsError(try controller.restore())
        XCTAssertEqual(try journal.load().appliedChanges.displayRestores, changes.displayRestores)
        machine.displayFailures = []
        try controller.restore()
        XCTAssertEqual(journal.inspect(), .clean)
    }

    func test_startupRecoveryDisabledBlocksActivationWithoutChangingSettings() throws {
        var changes = AppliedChanges.empty
        changes.mouseSpeedChanged = true
        changes.previousMouseSpeed = 0.3
        try journal.begin(state(changes))
        machine.speed = 0.8
        XCTAssertThrowsError(try controller.prepareForLaunch(restoreAutomatically: false))
        XCTAssertEqual(machine.mouseCalls, 0)
        var applied = false
        XCTAssertThrowsError(try controller.activate(state()) { applied = true })
        XCTAssertFalse(applied)
        try controller.restore()
        try controller.activate(state()) { applied = true }
        XCTAssertTrue(applied)
    }

    func test_automaticStartupRestoresBeforeNewActivation() throws {
        var changes = AppliedChanges.empty
        changes.mouseSpeedChanged = true
        changes.previousMouseSpeed = 0.3
        try journal.begin(state(changes))
        machine.speed = 0.8
        try controller.prepareForLaunch(restoreAutomatically: true)
        try controller.activate(state()) { XCTAssertEqual(machine.speed, 0.3) }
    }

    func test_cleanStartupDoesNotRunRestorers() throws {
        try controller.prepareForLaunch(restoreAutomatically: true)
        XCTAssertEqual(machine.mouseCalls, 0)
        XCTAssertEqual(machine.keyboardCalls, 0)
        XCTAssertEqual(machine.powerCalls, 0)
    }

    func test_failedCompletionFlushCanRetryWithoutReplayingRestoredSettings() throws {
        for recoveringAtStartup in [false, true] {
            var failCompletion = false
            var cleanWrites = 0
            let store = StateJournal(directory: directory.appendingPathComponent(UUID().uuidString), writer: { data, url in
                try StateJournal.writeDurably(data, to: url)
                if url.lastPathComponent == "manifest.json",
                   let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any], manifest["phase"] as? String == "clean" {
                    cleanWrites += 1
                    if failCompletion { throw JournalError.io("completion flush failed after replacement", 5) }
                }
            })
            let subject = RecoveryController(journal: store, operations: machine.operations)
            var changes = AppliedChanges.empty
            changes.mouseSpeedChanged = true
            changes.previousMouseSpeed = 0.3
            if recoveringAtStartup { try store.begin(state(changes)) }
            else { try subject.activate(state(changes)) {} }
            machine.speed = 0.8
            failCompletion = true
            XCTAssertThrowsError(try subject.prepareForLaunch(restoreAutomatically: true))
            XCTAssertEqual(store.inspect(), .clean, "The replacement happened even though its final flush failed")
            XCTAssertEqual(machine.speed, 0.3)
            let calls = machine.mouseCalls
            XCTAssertThrowsError(try subject.activate(state()) { XCTFail("Retry must succeed before activation") })
            XCTAssertThrowsError(try subject.restore(), "A second failed flush must remain retryable")
            XCTAssertEqual(machine.mouseCalls, calls)
            let writesBeforeRetry = cleanWrites
            failCompletion = false
            try subject.restore()
            XCTAssertEqual(cleanWrites, writesBeforeRetry + 1, "Retry must durably recommit the clean manifest")
            XCTAssertEqual(machine.mouseCalls, calls)
            XCTAssertFalse(subject.hasOpenSession)
            try subject.activate(state()) {}
            try subject.restore()
        }
    }

    func test_completionRetryNeverAcceptsMissingOrCorruptAuthority() throws {
        for corrupt in [false, true] {
            var failCompletion = false
            let store = StateJournal(directory: directory.appendingPathComponent(UUID().uuidString), commitObserver: {
                if failCompletion && $0 == .cleanManifestCommitted { throw JournalError.io("interrupted completion", 5) }
            })
            let subject = RecoveryController(journal: store, operations: machine.operations)
            try subject.activate(state()) {}
            failCompletion = true
            XCTAssertThrowsError(try subject.restore())
            failCompletion = false
            if corrupt { try Data("damaged".utf8).write(to: store.manifestURL) }
            else { try FileManager.default.removeItem(at: store.directory) }
            XCTAssertThrowsError(try subject.restore())
            XCTAssertTrue(subject.hasOpenSession)
            XCTAssertThrowsError(try subject.activate(state()) { XCTFail("Missing authority must block activation") })
        }
    }

    func test_shortcutTapFailureStopsApplicationAndPreservesRecoveryOriginals() throws {
        let blocker = SystemShortcutBlocker(readShortcuts: { _ in
            [.init(keyCode: 49, modifierMask: CGEventFlags.maskCommand.rawValue)]
        }, installTap: { _ in nil })
        let manager = SettingsManager(shortcutBlocker: blocker)
        let snapshot = SettingsManager.KeyboardSnapshot(functionKeysChanged: false, previousFunctionKeysEnabled: nil,
                                                        previousShortcutStates: [64: true], shortcutIDsToDisable: [64],
                                                        previousGestureValues: nil, gesturesToDisable: [])
        var changes = AppliedChanges.empty
        changes.disabledShortcutIDs = [64]
        changes.previousShortcutStates = [64: true]
        changes.mouseSpeedChanged = true
        changes.previousMouseSpeed = 0.3
        var appliedLaterSettings = false
        XCTAssertThrowsError(try controller.activate(state(changes)) {
            try manager.applyKeyboardSettings(snapshot)
            appliedLaterSettings = true
        }) { error in
            XCTAssertTrue(error is SystemShortcutBlocker.Failure)
            XCTAssertTrue(error.localizedDescription.contains("Accessibility"))
        }
        XCTAssertFalse(appliedLaterSettings)
        XCTAssertTrue(controller.hasOpenSession)
        XCTAssertEqual(try journal.load().appliedChanges, changes)
        try controller.restore()
        XCTAssertEqual(journal.inspect(), .clean)
    }

    func test_restorationKeepsSynchronousDisplayKeyboardPowerMouseOrder() throws {
        var calls: [String] = []
        var operations = machine.operations
        operations.stopDisplays = { calls.append("stopDisplays"); return [] }
        operations.restoreDisplays = { _ in calls.append("restoreDisplays"); return [] }
        operations.restoreKeyboard = { _ in calls.append("keyboard"); return [] }
        operations.restorePower = { _ in calls.append("power"); return [] }
        operations.applyMouse = { speed in calls.append("mouse"); self.machine.speed = speed; return true }
        let subject = RecoveryController(journal: journal, operations: operations)
        var changes = AppliedChanges.empty
        changes.functionKeysChanged = true
        changes.previousFunctionKeysEnabled = false
        changes.lowPowerModeChanged = true
        changes.previousLowPowerModeSettings = ["b": 1, "c": 0]
        changes.mouseSpeedChanged = true
        changes.previousMouseSpeed = 0.3
        changes.displayRestores = [DisplayRecoveryRecord(displayUUID: "test", displayName: "Display", mode: RecoveryDisplayMode(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, ioFlags: 0, modeID: 1))]
        try subject.activate(state(changes)) {}
        try subject.restore()
        XCTAssertEqual(calls, ["stopDisplays", "restoreDisplays", "keyboard", "power", "mouse"])
        XCTAssertEqual(journal.inspect(), .clean)
    }

    func test_displayStopCommitFailureCannotCompleteCleanEvenIfRetryReadsClearedRecord() throws {
        var operations = machine.operations
        operations.stopDisplays = { [unowned self] in
            try! journal.update { $0.appliedChanges.displayRestores = [] }
            return ["Final durability barrier failed"]
        }
        let subject = RecoveryController(journal: journal, operations: operations)
        try subject.activate(state()) {}
        XCTAssertThrowsError(try subject.restore())
        guard case .pending = journal.inspect() else { return XCTFail("Unknown durability outcome must remain pending") }
    }

    func test_interruptedShutdownRestorationResumesFromJournalOnNextLaunch() throws {
        var failWrites = false
        let interruptedJournal = StateJournal(directory: directory, writer: { data, url in
            if failWrites { throw CocoaError(.fileWriteUnknown) }
            try StateJournal.writeDurably(data, to: url)
        })
        var operations = machine.operations
        operations.restoreKeyboard = { _ in
            failWrites = true
            return []
        }
        let interruptedController = RecoveryController(journal: interruptedJournal, operations: operations)
        var changes = AppliedChanges.empty
        changes.functionKeysChanged = true
        changes.previousFunctionKeysEnabled = false
        changes.mouseSpeedChanged = true
        changes.previousMouseSpeed = 0.3
        try interruptedController.activate(state(changes)) { machine.speed = 0.8 }

        // Quit uses the same serial restoration path. Losing the process after a
        // setter but before its checkpoint must leave originals for the next launch.
        XCTAssertThrowsError(try interruptedController.restore())
        XCTAssertEqual(try journal.load().appliedChanges, changes)
        XCTAssertEqual(machine.mouseCalls, 0)
        let nextLaunch = RecoveryController(journal: StateJournal(directory: directory), operations: machine.operations)
        try nextLaunch.prepareForLaunch(restoreAutomatically: true)
        XCTAssertEqual(machine.speed, 0.3)
        XCTAssertEqual(journal.inspect(), .clean)
    }

    func test_acceptCurrentSettingsArchivesEvidenceWithoutApplyingSettings() throws {
        var changes = AppliedChanges.empty
        changes.mouseSpeedChanged = true
        changes.previousMouseSpeed = 0.3
        try controller.activate(state(changes)) { machine.speed = 0.8 }
        try controller.acceptCurrentSettings()
        XCTAssertEqual(machine.mouseCalls, 0)
        XCTAssertEqual(machine.speed, 0.8)
        XCTAssertEqual(journal.inspect(), .clean)
        XCTAssertFalse(controller.hasOpenSession)
    }
}

final class PowerSettingsParsingTests: XCTestCase {
    func test_distinctPowerSources() {
        XCTAssertEqual(PowerManager.parseLowPowerModeSettings("Battery Power:\n lowpowermode 1\nAC Power:\n lowpowermode 0\nUPS Power:\n lowpowermode 1"), ["b": 1, "c": 0, "u": 1])
    }

    func test_incompleteMalformedOrDuplicateSourceCannotBecomeBaseline() {
        for text in ["", "Battery Power:\n lowpowermode 1\nAC Power:\n sleep 0", "AC Power:\n lowpowermode 2", "AC Power:\n lowpowermode 1\nAC Power:\n lowpowermode 0", "Unknown Power:\n lowpowermode 1"] {
            XCTAssertNil(PowerManager.parseLowPowerModeSettings(text), text)
        }
    }
}

final class AppMonitorRecoveryTests: XCTestCase {
    @MainActor
    func testDisplayCallbacksTrackQualifyingAppsWhileGameModeRemainsActive() {
        let suite = "GameMode.AppMonitorRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigStore(defaults: defaults, isPreview: true)
        store.config.monitoredApps = [
            MonitoredApp(id: UUID(), bundleID: "test.game.a", name: "A", isEnabled: true, source: .manual),
            MonitoredApp(id: UUID(), bundleID: "test.game.b", name: "B", isEnabled: true, source: .manual, lockRefreshRate: true),
            MonitoredApp(id: UUID(), bundleID: "test.game.c", name: "C", isEnabled: true, source: .manual, lockRefreshRate: true)
        ]
        var activations = 0
        var deactivations = 0
        var displayRequirements: [Bool] = []
        weak var observedMonitor: AppMonitor?
        let displayChanged: (MonitoredApp) -> Void = { _ in
            displayRequirements.append(observedMonitor?.anyActiveAppNeedsRefreshRateLock() == true)
        }
        let monitor = AppMonitor(configStore: store, onActivate: { activations += 1 }, onDeactivate: { deactivations += 1 }, onMonitoredAppLaunched: displayChanged, onMonitoredAppTerminated: displayChanged, runningBundleIDs: { [] })
        observedMonitor = monitor
        let events: [(String, Bool)] = [("a", true), ("b", true), ("c", true), ("b", false), ("c", false), ("a", false)]
        for (index, event) in events.enumerated() {
            if event.1 { monitor.appLaunched(bundleID: "test.game.\(event.0)") }
            else { monitor.appTerminated(bundleID: "test.game.\(event.0)") }
            let drained = expectation(description: "Display callback \(index)")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 1)
            XCTAssertEqual(activations, 1)
            XCTAssertEqual(deactivations, index == events.count - 1 ? 1 : 0)
        }
        XCTAssertEqual(displayRequirements, [false, true, true, true, false, false])
        XCTAssertEqual(monitor.activeGameCount, 0)
        XCTAssertTrue(monitor.activeAppBundleIDs.isEmpty)
    }

    @MainActor
    func testAcceptingCurrentSettingsSeedsRunningGamesWithoutActivating() {
        let suite = "GameMode.AppMonitorRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigStore(defaults: defaults, isPreview: true)
        store.config.monitoredApps = [
            MonitoredApp(id: UUID(), bundleID: "test.game.a", name: "A", isEnabled: true, source: .manual),
            MonitoredApp(id: UUID(), bundleID: "test.game.b", name: "B", isEnabled: true, source: .manual)
        ]
        var activations = 0
        var running = ["test.game.a", "test.unmonitored"]
        let monitor = AppMonitor(configStore: store, onActivate: { activations += 1 }, onDeactivate: {}, runningBundleIDs: { running })
        monitor.checkRunningApps(activateIfRunning: false)
        XCTAssertEqual(monitor.activeGameCount, 1)
        XCTAssertEqual(monitor.activeAppBundleIDs, ["test.game.a"])

        running = ["test.game.a", "test.game.b"]
        monitor.checkRunningApps(activateIfRunning: false)
        XCTAssertEqual(monitor.activeGameCount, 2)
        XCTAssertEqual(monitor.activeAppBundleIDs, ["test.game.a", "test.game.b"])
        let drained = expectation(description: "Main callbacks drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(activations, 0)
    }

    @MainActor
    func testSuccessfulInitialRecoveryCanActivateAlreadyRunningGame() {
        let suite = "GameMode.AppMonitorRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigStore(defaults: defaults, isPreview: true)
        store.config.monitoredApps = [MonitoredApp(id: UUID(), bundleID: "test.game", name: "Game", isEnabled: true, source: .manual)]
        let activated = expectation(description: "Initial recovery permits activation")
        let monitor = AppMonitor(configStore: store, onActivate: { activated.fulfill() }, onDeactivate: {}, runningBundleIDs: { ["test.game"] })
        monitor.checkRunningApps()
        wait(for: [activated], timeout: 1)
        XCTAssertEqual(monitor.activeGameCount, 1)
    }
}

final class SystemShortcutBlockerTests: XCTestCase {
    @MainActor
    func testWorkerStartUpdateAndStopSynchronouslyUseTheCallbackRunLoop() throws {
        var handler: SystemShortcutBlocker.EventHandler?
        var installations = 0
        var invalidations = 0
        var enabledStates: [Bool] = []
        let blocker = SystemShortcutBlocker(readShortcuts: { ids in
            XCTAssertTrue(Thread.isMainThread)
            return Set(ids.map { .init(keyCode: Int64($0), modifierMask: CGEventFlags.maskCommand.rawValue) })
        }, installTap: { callback in
            XCTAssertTrue(Thread.isMainThread)
            installations += 1
            handler = callback
            return .init(setEnabled: { enabled in
                XCTAssertTrue(Thread.isMainThread)
                enabledStates.append(enabled)
            }, invalidate: {
                XCTAssertTrue(Thread.isMainThread)
                invalidations += 1
            })
        })
        let firstKey = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        let secondKey = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true))
        firstKey.flags = .maskCommand
        secondKey.flags = .maskCommand
        let finished = expectation(description: "Synchronous worker operations finished")
        DispatchQueue(label: "GameMode.Tests.ShortcutSettings").async(execute: DispatchWorkItem {
            do {
                try blocker.startBlocking(shortcutIDs: [49])
                DispatchQueue.main.sync {
                    XCTAssertNotNil(handler)
                    XCTAssertNil(handler?(.keyDown, firstKey), "Matching key must be consumed")
                    XCTAssertNotNil(handler?(.keyDown, secondKey))
                }
                try blocker.startBlocking(shortcutIDs: [51])
                DispatchQueue.main.sync {
                    XCTAssertNotNil(handler?(.keyDown, firstKey), "Reconfiguration must complete before returning")
                    XCTAssertNil(handler?(.keyDown, secondKey))
                    XCTAssertNotNil(handler?(.tapDisabledByTimeout, firstKey))
                }
                blocker.stopBlocking()
                DispatchQueue.main.sync {
                    XCTAssertEqual(invalidations, 1, "Stop must finish before returning to the settings queue")
                    XCTAssertNotNil(handler?(.keyDown, secondKey))
                }
            } catch { XCTFail("Unexpected tap error: \(error)") }
            finished.fulfill()
        })
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(installations, 1, "Changing selections reuses the existing tap")
        XCTAssertEqual(enabledStates, [true, true, true, false])
    }

    @MainActor
    func testFailedTapInstallationCanBeRetriedWithoutLeavingStaleShortcutState() throws {
        var shouldFail = true
        var handler: SystemShortcutBlocker.EventHandler?
        var invalidations = 0
        let blocker = SystemShortcutBlocker(readShortcuts: { ids in
            Set(ids.map { .init(keyCode: Int64($0), modifierMask: 0) })
        }, installTap: { callback in
            guard !shouldFail else { return nil }
            handler = callback
            return .init(setEnabled: { _ in }, invalidate: { invalidations += 1 })
        })
        XCTAssertThrowsError(try blocker.startBlocking(shortcutIDs: [49]))
        shouldFail = false
        try blocker.startBlocking(shortcutIDs: [51])
        let firstKey = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        let secondKey = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true))
        firstKey.flags = []
        secondKey.flags = []
        XCTAssertNotNil(handler?(.keyDown, firstKey))
        XCTAssertNil(handler?(.keyDown, secondKey))
        try blocker.startBlocking(shortcutIDs: [])
        XCTAssertEqual(invalidations, 1)
        XCTAssertNotNil(handler?(.keyDown, secondKey))
    }
}
