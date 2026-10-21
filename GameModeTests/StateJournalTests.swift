//
//  StateJournalTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 11/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import XCTest
@testable import GameMode

final class StateJournalTests: XCTestCase {
    private var tempDir: URL!
    private var journal: StateJournal!
    private enum InjectedFailure: Error { case interrupted }

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GameModeJournalTests-\(UUID().uuidString)")
        journal = StateJournal(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        journal = nil
        tempDir = nil
        super.tearDown()
    }

    private func activeState(mouseSpeed: Double = 0.3) -> GameModeState {
        GameModeState(isActive: true, activatedAt: Date(timeIntervalSince1970: 1_000), appliedChanges: AppliedChanges(functionKeysChanged: true, previousFunctionKeysEnabled: false, disabledShortcutIDs: [64], previousShortcutStates: [64: true], mouseSpeedChanged: true, previousMouseSpeed: mouseSpeed, gesturesChanged: true, previousGestureValues: ["gesture": ["domain": 2]], lowPowerModeChanged: true, previousLowPowerModeEnabled: true, previousLowPowerModeSettings: ["AC Power": 0, "Battery Power": 1], displayRestores: [displayRecord()]))
    }

    private func displayRecord() -> DisplayRecoveryRecord {
        DisplayRecoveryRecord(displayUUID: "display-uuid", displayName: "Test Display", mode: RecoveryDisplayMode(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60, ioFlags: 0, modeID: 12))
    }

    private func snapshotFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("snapshot-") }
    }

    private func restoreAll(_ store: StateJournal) throws {
        try store.update { $0.appliedChanges = .empty }
    }

    private func corrupt(_ url: URL) throws { try Data("damaged".utf8).write(to: url) }

    private func assertInvalid(_ store: StateJournal, file: StaticString = #filePath, line: UInt = #line) {
        guard case .invalid = store.inspect() else { return XCTFail("Expected invalid recovery state", file: file, line: line) }
        XCTAssertThrowsError(try store.load(), file: file, line: line)
        XCTAssertTrue(store.hasDirtyState, file: file, line: line)
    }

    func test_missingJournalIsInactive() throws {
        XCTAssertEqual(journal.inspect(), .missing)
        XCTAssertEqual(try journal.load(), .inactive)
        XCTAssertFalse(journal.hasDirtyState)
    }

    func test_beginDurablyStoresTwoIdenticalCopies() throws {
        let state = activeState()
        try journal.begin(state)
        XCTAssertEqual(journal.inspect(), .pending(state))
        XCTAssertEqual(try journal.load(), state)
        XCTAssertTrue(journal.hasDirtyState)
        let files = try snapshotFiles()
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try Data(contentsOf: files[0]), try Data(contentsOf: files[1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.manifestURL.path))
    }

    func test_beginCannotReplacePendingOriginals() throws {
        try journal.begin(activeState())
        XCTAssertThrowsError(try journal.begin(activeState(mouseSpeed: 1.5)))
        XCTAssertEqual(try journal.load().appliedChanges.previousMouseSpeed, 0.3)
    }

    func test_beginRejectsInactiveSession() {
        XCTAssertThrowsError(try journal.begin(.inactive))
        XCTAssertEqual(journal.inspect(), .missing)
    }

    func test_corruptPrimaryUsesSameRevisionMirror() throws {
        let state = activeState()
        try journal.begin(state)
        let primary = try XCTUnwrap(snapshotFiles().first { $0.lastPathComponent.contains("primary") })
        try corrupt(primary)
        XCTAssertEqual(try journal.load(), state)
    }

    func test_bothCopiesCorruptBlockLoadAndActivation() throws {
        try journal.begin(activeState())
        for file in try snapshotFiles() { try corrupt(file) }
        assertInvalid(journal)
        XCTAssertThrowsError(try journal.begin(activeState()))
        XCTAssertEqual(try snapshotFiles().count, 2)
    }

    func test_missingManifestDoesNotPromoteSnapshots() throws {
        try journal.begin(activeState())
        try FileManager.default.removeItem(at: journal.manifestURL)
        assertInvalid(journal)
    }

    func test_corruptManifestDoesNotPromoteSnapshots() throws {
        try journal.begin(activeState())
        try corrupt(journal.manifestURL)
        assertInvalid(journal)
    }

    func test_unsupportedManifestVersionIsInvalid() throws {
        try journal.begin(activeState())
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal.manifestURL)) as? [String: Any])
        manifest["version"] = 100
        try JSONSerialization.data(withJSONObject: manifest).write(to: journal.manifestURL)
        assertInvalid(journal)
    }

    func test_completionLeavesCleanTombstoneAndRetainsSnapshot() throws {
        try journal.begin(activeState())
        try restoreAll(journal)
        let before = Set(try snapshotFiles())
        try journal.complete()
        XCTAssertEqual(journal.inspect(), .clean)
        XCTAssertEqual(try journal.load(), .inactive)
        XCTAssertFalse(journal.hasDirtyState)
        XCTAssertEqual(Set(try snapshotFiles()), before)
        for file in before { try corrupt(file) }
        XCTAssertEqual(journal.inspect(), .clean, "Completed originals must never be automatically restored")
    }

    func test_completedSnapshotRetainsOriginalEvidenceAfterControllerClears() throws {
        try journal.begin(activeState())
        try journal.update {
            $0.appliedChanges.functionKeysChanged = false
            $0.appliedChanges.previousFunctionKeysEnabled = nil
            $0.appliedChanges.mouseSpeedChanged = false
            $0.appliedChanges.previousMouseSpeed = nil
        }
        try restoreAll(journal)
        try journal.complete()
        let bytes = try Data(contentsOf: XCTUnwrap(snapshotFiles().first))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let evidenceData = try JSONSerialization.data(withJSONObject: XCTUnwrap(envelope["originalEvidence"]))
        let evidence = try JSONDecoder().decode(AppliedChanges.self, from: evidenceData)
        XCTAssertEqual(evidence.previousFunctionKeysEnabled, false)
        XCTAssertEqual(evidence.previousMouseSpeed, 0.3)
        XCTAssertEqual(evidence.previousLowPowerModeSettings, ["AC Power": 0, "Battery Power": 1])
        XCTAssertEqual(evidence.displayRestores, [displayRecord()])
        XCTAssertTrue(evidence.hasPendingChanges, "Evidence keeps the historical capture flags")
        XCTAssertEqual(journal.inspect(), .clean, "Historical flags must not authorize recovery")
        XCTAssertEqual(try journal.load(), .inactive)
    }

    func test_historicalMouseEvidenceTracksLatestSafeCycle() throws {
        try journal.begin(activeState())
        try journal.update {
            $0.appliedChanges.mouseSpeedChanged = false
            $0.appliedChanges.previousMouseSpeed = nil
        }
        try journal.update {
            $0.appliedChanges.mouseSpeedChanged = true
            $0.appliedChanges.previousMouseSpeed = 0.9
        }
        try restoreAll(journal)
        try journal.complete()
        let bytes = try Data(contentsOf: XCTUnwrap(snapshotFiles().first))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let evidenceData = try JSONSerialization.data(withJSONObject: XCTUnwrap(envelope["originalEvidence"]))
        let evidence = try JSONDecoder().decode(AppliedChanges.self, from: evidenceData)
        XCTAssertEqual(evidence.previousMouseSpeed, 0.9)
        XCTAssertEqual(evidence.previousFunctionKeysEnabled, false)
        XCTAssertEqual(journal.inspect(), .clean)
    }

    func test_oldCompletedSnapshotsNeverOverrideNewSession() throws {
        try journal.begin(activeState())
        try restoreAll(journal)
        try journal.complete()
        let next = activeState(mouseSpeed: 0.8)
        try journal.begin(next)
        XCTAssertEqual(try journal.load(), next)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal.manifestURL)) as? [String: Any])
        let reference = try XCTUnwrap(manifest["active"] as? [String: Any])
        let session = try XCTUnwrap(reference["sessionID"] as? String)
        for file in try snapshotFiles() where file.lastPathComponent.contains(session) { try corrupt(file) }
        assertInvalid(journal)
    }

    func test_resetRejectsPendingOrInvalidRecovery() throws {
        try journal.begin(activeState())
        XCTAssertThrowsError(try journal.reset())
        try corrupt(journal.manifestURL)
        XCTAssertThrowsError(try journal.reset())
        assertInvalid(journal)
    }

    func test_resetCleanStateKeepsAuthorityAndRemovesSnapshots() throws {
        try journal.begin(activeState())
        try restoreAll(journal)
        try journal.complete()
        try journal.reset()
        XCTAssertEqual(journal.inspect(), .clean)
        XCTAssertTrue(try snapshotFiles().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.manifestURL.path))
    }

    func test_explicitArchiveResetPreservesDamagedEvidence() throws {
        try journal.begin(activeState())
        try corrupt(journal.manifestURL)
        let before = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        var evidence: [String: Data] = [:]
        for file in before { evidence[file.lastPathComponent] = try Data(contentsOf: file) }
        try journal.archiveAndReset()
        XCTAssertEqual(journal.inspect(), .clean)
        let archives = try FileManager.default.contentsOfDirectory(at: tempDir.appendingPathComponent("archives"), includingPropertiesForKeys: nil)
        let archive = try XCTUnwrap(archives.first)
        for (name, data) in evidence {
            XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent(name)), data)
        }
    }

    func test_archiveReadFailureDoesNotDiscardAuthority() throws {
        try journal.begin(activeState())
        let failing = StateJournal(directory: tempDir, writer: { data, url in
            if url.path.contains("/archives/") { throw InjectedFailure.interrupted }
            try StateJournal.writeDurably(data, to: url)
        })
        XCTAssertThrowsError(try failing.archiveAndReset())
        XCTAssertEqual(try journal.load(), activeState())
    }

    func test_acceptingLegacySettingsRetiresImportableFileButPreservesArchivedBytes() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let original = try JSONEncoder().encode(activeState())
        try original.write(to: journal.fileURL)
        try journal.archiveAndReset()
        XCTAssertEqual(journal.inspect(), .clean)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.fileURL.path))
        let archives = try FileManager.default.contentsOfDirectory(at: tempDir.appendingPathComponent("archives"), includingPropertiesForKeys: nil)
        let archive = try XCTUnwrap(archives.first)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("state.json")), original)
        try FileManager.default.removeItem(at: journal.manifestURL)
        XCTAssertEqual(journal.inspect(), .missing, "An accepted legacy session must never become pending again")
        XCTAssertEqual(try journal.load(), .inactive)
    }

    func test_archiveCommitInterruptionCannotReactivateRetiredLegacyOriginals() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let original = try JSONEncoder().encode(activeState())
        try original.write(to: journal.fileURL)
        let interrupted = StateJournal(directory: tempDir, commitObserver: {
            if $0 == .cleanManifestCommitted { throw InjectedFailure.interrupted }
        })
        XCTAssertThrowsError(try interrupted.archiveAndReset())
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.fileURL.path))
        XCTAssertEqual(journal.inspect(), .clean)
        try FileManager.default.removeItem(at: journal.manifestURL)
        XCTAssertEqual(journal.inspect(), .missing)
        let archives = try FileManager.default.contentsOfDirectory(at: tempDir.appendingPathComponent("archives"), includingPropertiesForKeys: nil)
        let archive = try XCTUnwrap(archives.first)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("state.json")), original)
    }

    func test_failedLegacyArchiveOrManifestWritePreservesOriginalFile() throws {
        for failArchive in [false, true] {
            let directory = tempDir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = try JSONEncoder().encode(activeState())
            let legacyURL = directory.appendingPathComponent("state.json")
            try original.write(to: legacyURL)
            let failing = StateJournal(directory: directory, writer: { data, url in
                if failArchive ? url.path.contains("/archives/") : url.lastPathComponent == "manifest.json" {
                    throw InjectedFailure.interrupted
                }
                try StateJournal.writeDurably(data, to: url)
            })
            XCTAssertThrowsError(try failing.archiveAndReset())
            XCTAssertEqual(try Data(contentsOf: legacyURL), original)
            XCTAssertEqual(failing.inspect(), .pending(activeState()))
        }
    }

    func test_completionRejectsUnrestoredSettings() throws {
        try journal.begin(activeState())
        XCTAssertThrowsError(try journal.complete())
        XCTAssertEqual(try journal.load(), activeState())
    }

    func test_updateRequiresPendingSession() {
        XCTAssertThrowsError(try journal.update { $0.isActive = true })
    }

    func test_updateCannotReplaceUnrestoredMouseBaseline() throws {
        try journal.begin(activeState())
        XCTAssertThrowsError(try journal.update { $0.appliedChanges.previousMouseSpeed = 1.8 })
        XCTAssertEqual(try journal.load().appliedChanges.previousMouseSpeed, 0.3)
    }

    func test_mouseCanCaptureFreshBaselineAfterCommittedRestore() throws {
        try journal.begin(activeState())
        try journal.update {
            $0.appliedChanges.mouseSpeedChanged = false
            $0.appliedChanges.previousMouseSpeed = nil
        }
        try journal.update {
            $0.appliedChanges.mouseSpeedChanged = true
            $0.appliedChanges.previousMouseSpeed = 0.9
        }
        XCTAssertEqual(try journal.load().appliedChanges.previousMouseSpeed, 0.9)
        XCTAssertEqual(try journal.load().appliedChanges.previousFunctionKeysEnabled, false)
    }

    func test_updateProtectsKeyboardGesturePowerAndDisplayOriginals() throws {
        try journal.begin(activeState())
        XCTAssertThrowsError(try journal.update { $0.appliedChanges.previousFunctionKeysEnabled = true })
        XCTAssertThrowsError(try journal.update { $0.appliedChanges.previousGestureValues = [:] })
        XCTAssertThrowsError(try journal.update { $0.appliedChanges.previousLowPowerModeSettings = ["AC Power": 1] })
        XCTAssertThrowsError(try journal.update { $0.appliedChanges.previousShortcutStates = [64: false] })
        XCTAssertThrowsError(try journal.update { $0.appliedChanges.displayRestores[0].mode.refreshRate = 120 })
        XCTAssertEqual(try journal.load(), activeState())
    }

    func test_updateCannotClearSessionWithoutTombstone() throws {
        try journal.begin(activeState())
        XCTAssertThrowsError(try journal.update { $0.isActive = false })
        XCTAssertTrue(try journal.load().isActive)
    }

    func test_beginInterruptionAtEveryCommitBoundaryHasSafeAuthority() throws {
        for stage in [StateJournal.CommitStage.initialManifestCommitted, .primarySnapshotCommitted, .mirrorSnapshotCommitted, .pendingManifestCommitted] {
            let directory = tempDir.appendingPathComponent(UUID().uuidString)
            let interrupted = StateJournal(directory: directory, commitObserver: { if $0 == stage { throw InjectedFailure.interrupted } })
            XCTAssertThrowsError(try interrupted.begin(activeState()))
            let reopened = StateJournal(directory: directory)
            if stage == .pendingManifestCommitted {
                XCTAssertEqual(try reopened.load(), activeState())
            } else {
                XCTAssertEqual(reopened.inspect(), .clean)
                XCTAssertEqual(try reopened.load(), .inactive)
            }
        }
    }

    func test_updateInterruptionNeverFallsBackToWrongRevision() throws {
        for stage in [StateJournal.CommitStage.primarySnapshotCommitted, .mirrorSnapshotCommitted, .pendingManifestCommitted] {
            let directory = tempDir.appendingPathComponent(UUID().uuidString)
            let original = StateJournal(directory: directory)
            try original.begin(activeState())
            let interrupted = StateJournal(directory: directory, commitObserver: { if $0 == stage { throw InjectedFailure.interrupted } })
            XCTAssertThrowsError(try interrupted.update {
                $0.appliedChanges.mouseSpeedChanged = false
                $0.appliedChanges.previousMouseSpeed = nil
            })
            let reopened = try StateJournal(directory: directory).load()
            XCTAssertEqual(reopened.appliedChanges.mouseSpeedChanged, stage != .pendingManifestCommitted)
            XCTAssertEqual(reopened.appliedChanges.previousMouseSpeed, stage == .pendingManifestCommitted ? nil : 0.3)
        }
    }

    func test_failureWritingCompletionManifestLeavesPendingSession() throws {
        try journal.begin(activeState())
        try restoreAll(journal)
        let pending = try journal.load()
        let failing = StateJournal(directory: tempDir, writer: { data, url in
            if url.lastPathComponent == "manifest.json" { throw InjectedFailure.interrupted }
            try StateJournal.writeDurably(data, to: url)
        })
        XCTAssertThrowsError(try failing.complete())
        XCTAssertEqual(try journal.load(), pending)
    }

    func test_interruptionAfterCompletionCommitCannotResurrectSession() throws {
        try journal.begin(activeState())
        try restoreAll(journal)
        let interrupted = StateJournal(directory: tempDir, commitObserver: { if $0 == .cleanManifestCommitted { throw InjectedFailure.interrupted } })
        XCTAssertThrowsError(try interrupted.complete())
        XCTAssertEqual(StateJournal(directory: tempDir).inspect(), .clean)
        XCTAssertEqual(try snapshotFiles().count, 2)
    }

    func test_snapshotWriterFailureLeavesCleanAuthority() throws {
        let failing = StateJournal(directory: tempDir, writer: { data, url in
            if url.lastPathComponent.contains("mirror") { throw InjectedFailure.interrupted }
            try StateJournal.writeDurably(data, to: url)
        })
        XCTAssertThrowsError(try failing.begin(activeState()))
        XCTAssertEqual(journal.inspect(), .clean)
        XCTAssertEqual(try journal.load(), .inactive)
    }

    func test_legacyMigrationRetainsEvidenceAndPendingOriginals() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(activeState())
        try bytes.write(to: journal.fileURL)
        XCTAssertEqual(journal.inspect(), .pending(activeState()))
        XCTAssertEqual(try journal.load(), activeState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.fileURL.path))
        let archives = try FileManager.default.contentsOfDirectory(at: tempDir.appendingPathComponent("archives"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archives.first)), bytes)
        XCTAssertEqual(try snapshotFiles().count, 2)
    }

    func test_interruptedLegacyMigrationRemainsRecoverable() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(activeState())
        try bytes.write(to: journal.fileURL)
        let interrupted = StateJournal(directory: tempDir, commitObserver: { if $0 == .primarySnapshotCommitted { throw InjectedFailure.interrupted } })
        XCTAssertThrowsError(try interrupted.load())
        XCTAssertEqual(try Data(contentsOf: journal.fileURL), bytes)
        XCTAssertEqual(journal.inspect(), .pending(activeState()))
        XCTAssertEqual(try journal.load(), activeState())
    }

    func test_completedLegacySessionCannotReappearWhenManifestIsLost() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(activeState()).write(to: journal.fileURL)
        _ = try journal.load()
        try restoreAll(journal)
        try journal.complete()
        try FileManager.default.removeItem(at: journal.manifestURL)
        assertInvalid(journal)
    }

    func test_corruptLegacyJournalIsPreserved() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try corrupt(journal.fileURL)
        assertInvalid(journal)
        XCTAssertEqual(try String(contentsOf: journal.fileURL, encoding: .utf8), "damaged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.manifestURL.path))
    }

    func test_unreadableStoreIsNotMissing() throws {
        try Data("not a directory".utf8).write(to: tempDir)
        assertInvalid(journal)
    }
}

final class AppliedChangesCodableTests: XCTestCase {
    func test_legacyDecoderDefaultsPersistedShortcutsAndNewFields() throws {
        let json = Data("{\"functionKeysChanged\":true,\"previousFunctionKeysEnabled\":false,\"disabledShortcutIDs\":[64],\"mouseSpeedChanged\":false}".utf8)
        let decoded = try JSONDecoder().decode(AppliedChanges.self, from: json)
        XCTAssertTrue(decoded.shortcutsWerePersisted)
        XCTAssertFalse(decoded.gesturesChanged)
        XCTAssertNil(decoded.previousLowPowerModeSettings)
        XCTAssertTrue(decoded.displayRestores.isEmpty)
    }

    func test_newSnapshotsUseProcessOwnedShortcuts() {
        XCTAssertFalse(AppliedChanges.empty.shortcutsWerePersisted)
    }

    func test_absentGesturePreferencesRoundTripAsExplicitNull() throws {
        var values: [String: Int?] = [:]
        values.updateValue(nil, forKey: "absent-domain")
        values["present-domain"] = 2
        let original = AppliedChanges(functionKeysChanged: false, disabledShortcutIDs: [], mouseSpeedChanged: false, previousMouseSpeed: nil, gesturesChanged: true, previousGestureValues: ["gesture": values])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppliedChanges.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.previousGestureValues?["gesture"]?.keys.contains("absent-domain") == true)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("null"))
    }

    func test_malformedGestureSnapshotDoesNotSilentlyBecomeNil() {
        let json = Data("{\"functionKeysChanged\":false,\"disabledShortcutIDs\":[],\"mouseSpeedChanged\":false,\"gesturesChanged\":true,\"previousGestureValues\":\"damaged\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppliedChanges.self, from: json))
    }

    func test_legacyFlatGestureSnapshotStillDecodes() throws {
        let json = Data("{\"functionKeysChanged\":false,\"disabledShortcutIDs\":[],\"mouseSpeedChanged\":false,\"gesturesChanged\":true,\"previousGestureValues\":{\"gesture\":2}}".utf8)
        let decoded = try JSONDecoder().decode(AppliedChanges.self, from: json)
        XCTAssertEqual(decoded.previousGestureValues?["gesture"]?["legacy"], 2)
    }

    func test_hasPendingChangesIncludesEverySubsystem() {
        XCTAssertFalse(AppliedChanges.empty.hasPendingChanges)
        var changes = AppliedChanges.empty
        changes.lowPowerModeChanged = true
        XCTAssertTrue(changes.hasPendingChanges)
        changes = .empty
        changes.disabledShortcutIDs = [64]
        XCTAssertFalse(changes.hasPendingChanges)
        changes.shortcutsWerePersisted = true
        XCTAssertTrue(changes.hasPendingChanges)
        changes = .empty
        changes.gesturesChanged = true
        XCTAssertTrue(changes.hasPendingChanges)
    }
}
