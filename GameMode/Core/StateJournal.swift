//
//  StateJournal.swift
//  GameMode
//
//  Created by Nikita Moshyn on 13/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import CryptoKit
import Darwin
import Foundation

// MARK: - State Model

typealias GesturePreferenceValues = [String: [String: Int?]]

struct RecoveryDisplayMode: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var refreshRate: Double
    var ioFlags: UInt32
    var modeID: Int32
}

struct DisplayRecoveryRecord: Codable, Equatable, Sendable {
    var displayUUID: String
    var displayName: String
    var mode: RecoveryDisplayMode
}

struct GameModeState: Codable, Equatable {
    var isActive: Bool
    var activatedAt: Date?
    var appliedChanges: AppliedChanges

    static let inactive = GameModeState(isActive: false, activatedAt: nil, appliedChanges: .empty)
}

struct AppliedChanges: Codable, Equatable, Sendable {
    var functionKeysChanged: Bool
    var previousFunctionKeysEnabled: Bool?
    var functionKeysWerePersisted: Bool
    /// A separately authorized cleanup, never a replacement for a session's original mode.
    var legacyFunctionKeyCleanupPending: Bool = false
    var functionKeyContext: FunctionKeyRecoveryContext? = nil
    var functionKeyOverrideRemoval: FunctionKeyOverrideRemoval? = nil
    var disabledShortcutIDs: [Int]
    var previousShortcutStates: [Int: Bool]?
    var shortcutsWerePersisted: Bool
    var mouseSpeedChanged: Bool
    var previousMouseSpeed: Double?
    var gesturesChanged: Bool
    var previousGestureValues: GesturePreferenceValues?
    var lowPowerModeChanged: Bool
    var previousLowPowerModeEnabled: Bool?
    var previousLowPowerModeSettings: [String: Int]?
    var displayRestores: [DisplayRecoveryRecord]

    var hasPendingChanges: Bool {
        functionKeysChanged || legacyFunctionKeyCleanupPending || functionKeyOverrideRemoval != nil || (shortcutsWerePersisted && (!disabledShortcutIDs.isEmpty || previousShortcutStates?.isEmpty == false)) || mouseSpeedChanged || gesturesChanged || lowPowerModeChanged || !displayRestores.isEmpty
    }

    static let empty = AppliedChanges(functionKeysChanged: false, disabledShortcutIDs: [], mouseSpeedChanged: false, previousMouseSpeed: nil)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        functionKeysChanged = try container.decode(Bool.self, forKey: .functionKeysChanged)
        previousFunctionKeysEnabled = try container.decodeIfPresent(Bool.self, forKey: .previousFunctionKeysEnabled)
        functionKeysWerePersisted = try container.decodeIfPresent(Bool.self, forKey: .functionKeysWerePersisted) ?? true
        legacyFunctionKeyCleanupPending = try container.decodeIfPresent(Bool.self, forKey: .legacyFunctionKeyCleanupPending) ?? false
        functionKeyContext = try container.decodeIfPresent(FunctionKeyRecoveryContext.self, forKey: .functionKeyContext)
        functionKeyOverrideRemoval = try container.decodeIfPresent(FunctionKeyOverrideRemoval.self, forKey: .functionKeyOverrideRemoval)
        disabledShortcutIDs = try container.decode([Int].self, forKey: .disabledShortcutIDs)
        previousShortcutStates = try container.decodeIfPresent([Int: Bool].self, forKey: .previousShortcutStates)
        shortcutsWerePersisted = try container.decodeIfPresent(Bool.self, forKey: .shortcutsWerePersisted) ?? true
        mouseSpeedChanged = try container.decode(Bool.self, forKey: .mouseSpeedChanged)
        previousMouseSpeed = try container.decodeIfPresent(Double.self, forKey: .previousMouseSpeed)
        gesturesChanged = try container.decodeIfPresent(Bool.self, forKey: .gesturesChanged) ?? false
        if try !container.contains(.previousGestureValues) || container.decodeNil(forKey: .previousGestureValues) {
            previousGestureValues = nil
        } else if let values = try? container.decode(GesturePreferenceValues.self, forKey: .previousGestureValues) {
            previousGestureValues = values
        } else {
            let legacy = try container.decode([String: Int].self, forKey: .previousGestureValues)
            previousGestureValues = legacy.mapValues { ["legacy": Optional($0)] }
        }
        lowPowerModeChanged = try container.decodeIfPresent(Bool.self, forKey: .lowPowerModeChanged) ?? false
        previousLowPowerModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .previousLowPowerModeEnabled)
        previousLowPowerModeSettings = try container.decodeIfPresent([String: Int].self, forKey: .previousLowPowerModeSettings)
        displayRestores = try container.decodeIfPresent([DisplayRecoveryRecord].self, forKey: .displayRestores) ?? []
    }

    init(functionKeysChanged: Bool, previousFunctionKeysEnabled: Bool? = nil, disabledShortcutIDs: [Int], previousShortcutStates: [Int: Bool]? = nil, mouseSpeedChanged: Bool, previousMouseSpeed: Double?, gesturesChanged: Bool = false, previousGestureValues: GesturePreferenceValues? = nil, lowPowerModeChanged: Bool = false, previousLowPowerModeEnabled: Bool? = nil, shortcutsWerePersisted: Bool = false, previousLowPowerModeSettings: [String: Int]? = nil, displayRestores: [DisplayRecoveryRecord] = [], functionKeysWerePersisted: Bool = false) {
        self.functionKeysChanged = functionKeysChanged
        self.previousFunctionKeysEnabled = previousFunctionKeysEnabled
        self.functionKeysWerePersisted = functionKeysWerePersisted
        self.disabledShortcutIDs = disabledShortcutIDs
        self.previousShortcutStates = previousShortcutStates
        self.shortcutsWerePersisted = shortcutsWerePersisted
        self.mouseSpeedChanged = mouseSpeedChanged
        self.previousMouseSpeed = previousMouseSpeed
        self.gesturesChanged = gesturesChanged
        self.previousGestureValues = previousGestureValues
        self.lowPowerModeChanged = lowPowerModeChanged
        self.previousLowPowerModeEnabled = previousLowPowerModeEnabled
        self.previousLowPowerModeSettings = previousLowPowerModeSettings
        self.displayRestores = displayRestores
    }
}

enum JournalLoadResult: Equatable {
    case missing
    case clean
    case pending(GameModeState)
    case invalid(String)
}

enum JournalError: LocalizedError {
    case invalid(String)
    case pendingRecovery
    case noPendingSession
    case changedBaseline
    case io(String, Int32)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Recovery data could not be read: \(reason)"
        case .pendingRecovery: return "Previous settings still need to be restored."
        case .noPendingSession: return "There is no active recovery session."
        case .changedBaseline: return "An unrestored original setting cannot be replaced."
        case .io(let operation, let code): return "Recovery storage \(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// The manifest is the sole authority. A clean tombstone prevents old snapshots
/// from becoming active again. Both snapshot copies commit before that authority
/// can reference them, and every commit is flushed before a caller changes settings.
final class StateJournal {
    enum CommitStage: CaseIterable {
        case initialManifestCommitted
        case primarySnapshotCommitted
        case mirrorSnapshotCommitted
        case pendingManifestCommitted
        case cleanManifestCommitted
    }

    typealias DurableWriter = (Data, URL) throws -> Void
    typealias CommitObserver = (CommitStage) throws -> Void

    private struct SnapshotReference: Codable, Equatable {
        var sessionID: UUID
        var revision: Int
        var checksum: String
    }

    private struct Manifest: Codable {
        var version = 1
        var phase: String
        var active: SnapshotReference?
        var lastCompleted: SnapshotReference?
    }

    private struct Snapshot: Codable {
        var version = 1
        var sessionID: UUID
        var revision: Int
        var state: GameModeState
        /// Diagnostic evidence only. The manifest's pending state alone authorizes recovery.
        var originalEvidence: AppliedChanges?
    }

    static let shared = StateJournal()
    let directory: URL
    /// Legacy location; retained for migration and diagnostics.
    var fileURL: URL { directory.appendingPathComponent("state.json") }
    var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private let writer: DurableWriter
    private let observer: CommitObserver
    private let lock = NSRecursiveLock()

    init(directory: URL? = nil, writer: DurableWriter? = nil, commitObserver: @escaping CommitObserver = { _ in }) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GameMode")
        self.writer = writer ?? Self.writeDurably
        self.observer = commitObserver
    }

    func inspect() -> JournalLoadResult {
        lock.lock()
        defer { lock.unlock() }
        do {
            let names = try storeNames()
            if names.contains("manifest.json") {
                let manifest = try readManifest()
                if manifest.phase == "clean" { return .clean }
                guard let reference = manifest.active else { throw JournalError.invalid("Pending manifest has no snapshot.") }
                return .pending(try readSnapshot(reference))
            }
            if names.contains("state.json") {
                let state = try JSONDecoder().decode(GameModeState.self, from: Data(contentsOf: fileURL))
                return state.isActive ? .pending(state) : .clean
            }
            // Legacy evidence is retired before a session can complete. Until migration
            // commits, it remains authoritative even if snapshot creation was interrupted.
            if names.contains(where: { $0.hasPrefix("snapshot-") }) {
                throw JournalError.invalid("The recovery manifest is missing.")
            }
            if names.contains(where: { $0.hasPrefix(".commit-") }) {
                throw JournalError.invalid("Recovery storage initialization was interrupted.")
            }
            return .missing
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    /// Diagnostic originals are exported for inspection, never used as replay authority.
    func recoveryEvidence() throws -> AppliedChanges? {
        lock.lock()
        defer { lock.unlock() }
        if case .pending(let state) = inspect(), !FileManager.default.fileExists(atPath: manifestURL.path) { return state.appliedChanges }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let manifest = try readManifest()
        guard let reference = manifest.active ?? manifest.lastCompleted else { return nil }
        let envelope = try readSnapshotEnvelope(reference)
        return envelope.originalEvidence ?? envelope.state.appliedChanges
    }

    /// Loading a legacy journal first migrates it durably, without modifying its evidence.
    func load() throws -> GameModeState {
        lock.lock()
        defer { lock.unlock() }
        switch inspect() {
        case .missing: return .inactive
        case .clean:
            try migrateLegacyIfNeeded()
            return .inactive
        case .pending(let state):
            try migrateLegacyIfNeeded()
            return state
        case .invalid(let reason): throw JournalError.invalid(reason)
        }
    }

    func begin(_ state: GameModeState) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state.isActive else { throw JournalError.invalid("A new session must be active.") }
        switch inspect() {
        case .pending: throw JournalError.pendingRecovery
        case .invalid(let reason): throw JournalError.invalid(reason)
        case .missing, .clean: break
        }
        try migrateLegacyIfNeeded()
        try initializeIfNeeded()
        let manifest = try readManifest()
        try commit(state, sessionID: UUID(), revision: 1, lastCompleted: manifest.lastCompleted)
    }

    /// Existing pending baselines cannot change. Clear a successfully restored setting
    /// in one committed update before capturing a new baseline in a later update.
    func update(_ mutate: (inout GameModeState) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        let old = try load()
        guard old.isActive else { throw JournalError.noPendingSession }
        var state = old
        mutate(&state)
        guard state.isActive else { throw JournalError.invalid("Complete the session with a clean tombstone.") }
        try protectBaselines(old.appliedChanges, state.appliedChanges)
        let manifest = try readManifest()
        guard let reference = manifest.active, reference.revision < Int.max else { throw JournalError.invalid("Invalid session revision.") }
        let previousSnapshot = try readSnapshotEnvelope(reference)
        let evidence = mergedEvidence(previousSnapshot.originalEvidence ?? old.appliedChanges, state.appliedChanges)
        try commit(state, sessionID: reference.sessionID, revision: reference.revision + 1, lastCompleted: manifest.lastCompleted, originalEvidence: evidence)
    }

    /// Call only after every pending setting was restored and verified.
    func complete() throws {
        lock.lock()
        defer { lock.unlock() }
        let state = try load()
        guard !state.appliedChanges.hasPendingChanges else { throw JournalError.pendingRecovery }
        try initializeIfNeeded()
        let manifest = try readManifest()
        let clean = Manifest(phase: "clean", active: nil, lastCompleted: manifest.active ?? manifest.lastCompleted)
        try writeManifest(clean)
        try observer(.cleanManifestCommitted)
        collectUnreferencedSnapshots(keeping: clean)
    }

    func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        switch inspect() {
        case .pending: throw JournalError.pendingRecovery
        case .invalid(let reason): throw JournalError.invalid(reason)
        case .missing, .clean: break
        }
        try migrateLegacyIfNeeded()
        try initializeIfNeeded()
        let clean = Manifest(phase: "clean", active: nil, lastCompleted: nil)
        try writeManifest(clean)
        try observer(.cleanManifestCommitted)
        collectUnreferencedSnapshots(keeping: clean)
        // A committed manifest always takes precedence over retained legacy evidence.
    }

    /// Explicit user acceptance only. Preserve readable evidence before abandoning recovery.
    func archiveAndReset() throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectory()
        let names = try storeNames().filter { $0 == "state.json" || $0 == "manifest.json" || $0.hasPrefix("snapshot-") || $0.hasPrefix(".commit-") }
        if !names.isEmpty {
            let archives = directory.appendingPathComponent("archives", isDirectory: true)
            try Self.createDirectoryDurably(archives)
            let archive = archives.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try Self.createDirectoryDurably(archive)
            for name in names {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                try writer(data, archive.appendingPathComponent(name))
            }
        }
        let clean = Manifest(phase: "clean", active: nil, lastCompleted: nil)
        try writeManifest(clean)
        // The archived legacy file must not remain eligible for import if the
        // manifest is later lost. Its bytes are already durable in the archive.
        if names.contains("state.json") {
            try FileManager.default.removeItem(at: fileURL)
            try Self.syncDirectory(directory)
        }
        try observer(.cleanManifestCommitted)
        collectUnreferencedSnapshots(keeping: clean)
    }

    func write(_ state: GameModeState) throws { try begin(state) }
    func clear() throws { try complete() }

    var hasDirtyState: Bool {
        switch inspect() {
        case .pending, .invalid: return true
        case .clean, .missing: return false
        }
    }

    // MARK: - Transaction internals

    private func storeNames() throws -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
    }

    private func prepareDirectory() throws { try Self.createDirectoryDurably(directory) }

    private func initializeIfNeeded() throws {
        try prepareDirectory()
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            try writeManifest(Manifest(phase: "clean", active: nil, lastCompleted: nil))
            try observer(.initialManifestCommitted)
        }
    }

    private func migrateLegacyIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let bytes = try Data(contentsOf: fileURL)
        try prepareDirectory()
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            let state = try JSONDecoder().decode(GameModeState.self, from: bytes)
            if state.isActive {
                // Do not write an initial clean authority over a legacy pending session.
                try commit(state, sessionID: UUID(), revision: 1, lastCompleted: nil)
            } else {
                try writeManifest(Manifest(phase: "clean", active: nil, lastCompleted: nil))
                try observer(.cleanManifestCommitted)
            }
        }
        let archives = directory.appendingPathComponent("archives", isDirectory: true)
        try Self.createDirectoryDurably(archives)
        try writer(bytes, archives.appendingPathComponent("legacy-\(UUID().uuidString).json"))
        try FileManager.default.removeItem(at: fileURL)
        try Self.syncDirectory(directory)
    }

    private func commit(_ state: GameModeState, sessionID: UUID, revision: Int, lastCompleted: SnapshotReference?, originalEvidence: AppliedChanges? = nil) throws {
        let bytes = try encode(Snapshot(sessionID: sessionID, revision: revision, state: state, originalEvidence: originalEvidence ?? state.appliedChanges))
        let reference = SnapshotReference(sessionID: sessionID, revision: revision, checksum: Self.checksum(bytes))
        try writer(bytes, snapshotURL(reference, mirror: false))
        try observer(.primarySnapshotCommitted)
        try writer(bytes, snapshotURL(reference, mirror: true))
        try observer(.mirrorSnapshotCommitted)
        let manifest = Manifest(phase: "pending", active: reference, lastCompleted: lastCompleted)
        try writeManifest(manifest)
        try observer(.pendingManifestCommitted)
        collectUnreferencedSnapshots(keeping: manifest)
    }

    private func readManifest() throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1, manifest.phase == "clean" || manifest.phase == "pending", (manifest.phase == "pending") == (manifest.active != nil) else {
            throw JournalError.invalid("Unsupported or inconsistent recovery manifest.")
        }
        for reference in [manifest.active, manifest.lastCompleted].compactMap({ $0 }) {
            guard reference.revision > 0, reference.checksum.count == 64, reference.checksum.allSatisfy({ $0.isHexDigit }) else {
                throw JournalError.invalid("Invalid snapshot reference.")
            }
        }
        return manifest
    }

    private func readSnapshot(_ reference: SnapshotReference) throws -> GameModeState {
        try readSnapshotEnvelope(reference).state
    }

    private func readSnapshotEnvelope(_ reference: SnapshotReference) throws -> Snapshot {
        for mirror in [false, true] {
            guard let bytes = try? Data(contentsOf: snapshotURL(reference, mirror: mirror)), Self.checksum(bytes) == reference.checksum,
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: bytes), snapshot.version == 1,
                  snapshot.sessionID == reference.sessionID, snapshot.revision == reference.revision, snapshot.state.isActive else { continue }
            return snapshot
        }
        throw JournalError.invalid("Both copies of the current recovery snapshot are unavailable or damaged.")
    }

    private func snapshotURL(_ reference: SnapshotReference, mirror: Bool) -> URL {
        directory.appendingPathComponent("snapshot-\(reference.sessionID.uuidString)-\(reference.revision)-\(mirror ? "mirror" : "primary").json")
    }

    private func writeManifest(_ manifest: Manifest) throws { try writer(encode(manifest), manifestURL) }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func collectUnreferencedSnapshots(keeping manifest: Manifest) {
        let references = [manifest.active, manifest.lastCompleted].compactMap { $0 }
        let keep = Set(references.flatMap { [snapshotURL($0, mirror: false).lastPathComponent, snapshotURL($0, mirror: true).lastPathComponent] })
        guard let names = try? storeNames() else { return }
        for name in names where name.hasPrefix("snapshot-") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func protectBaselines(_ old: AppliedChanges, _ new: AppliedChanges) throws {
        guard !(old.functionKeysChanged && new.functionKeysChanged && (old.previousFunctionKeysEnabled != new.previousFunctionKeysEnabled || old.functionKeysWerePersisted != new.functionKeysWerePersisted || old.functionKeyContext != new.functionKeyContext)),
              !(old.mouseSpeedChanged && new.mouseSpeedChanged && old.previousMouseSpeed != new.previousMouseSpeed),
              !(old.gesturesChanged && new.gesturesChanged && old.previousGestureValues != new.previousGestureValues),
              !(old.lowPowerModeChanged && new.lowPowerModeChanged && (old.previousLowPowerModeEnabled != new.previousLowPowerModeEnabled || old.previousLowPowerModeSettings != new.previousLowPowerModeSettings)) else { throw JournalError.changedBaseline }
        if let removal = old.functionKeyOverrideRemoval, let pending = new.functionKeyOverrideRemoval, removal != pending { throw JournalError.changedBaseline }
        let oldShortcuts = Set(old.disabledShortcutIDs).union(old.shortcutsWerePersisted ? Array(old.previousShortcutStates?.keys ?? Dictionary<Int, Bool>().keys) : [])
        let newShortcuts = Set(new.disabledShortcutIDs).union(new.shortcutsWerePersisted ? Array(new.previousShortcutStates?.keys ?? Dictionary<Int, Bool>().keys) : [])
        for id in oldShortcuts.intersection(newShortcuts) {
            guard old.previousShortcutStates?[id] == new.previousShortcutStates?[id], old.shortcutsWerePersisted == new.shortcutsWerePersisted else { throw JournalError.changedBaseline }
        }
        guard Set(new.displayRestores.map(\.displayUUID)).count == new.displayRestores.count else { throw JournalError.invalid("Duplicate display recovery identity.") }
        for record in old.displayRestores {
            if let replacement = new.displayRestores.first(where: { $0.displayUUID == record.displayUUID }), replacement.mode != record.mode {
                throw JournalError.changedBaseline
            }
        }
    }

    /// Keep the latest captured original for each setting even after its pending flag
    /// is cleared. A later mouse cycle can replace its historical baseline safely.
    private func mergedEvidence(_ old: AppliedChanges, _ pending: AppliedChanges) -> AppliedChanges {
        var evidence = old
        if pending.functionKeysChanged {
            evidence.functionKeysChanged = true
            evidence.previousFunctionKeysEnabled = pending.previousFunctionKeysEnabled
            evidence.functionKeysWerePersisted = pending.functionKeysWerePersisted
            evidence.functionKeyContext = pending.functionKeyContext
        }
        if let removal = pending.functionKeyOverrideRemoval { evidence.functionKeyOverrideRemoval = removal }
        if pending.mouseSpeedChanged {
            evidence.mouseSpeedChanged = true
            evidence.previousMouseSpeed = pending.previousMouseSpeed
        }
        if pending.gesturesChanged {
            evidence.gesturesChanged = true
            if let values = pending.previousGestureValues {
                var saved = evidence.previousGestureValues ?? [:]
                for (gesture, domains) in values {
                    saved[gesture] = (saved[gesture] ?? [:]).merging(domains) { _, newest in newest }
                }
                evidence.previousGestureValues = saved
            }
        }
        if pending.lowPowerModeChanged {
            evidence.lowPowerModeChanged = true
            evidence.previousLowPowerModeEnabled = pending.previousLowPowerModeEnabled
            evidence.previousLowPowerModeSettings = pending.previousLowPowerModeSettings
        }
        evidence.disabledShortcutIDs = Array(Set(evidence.disabledShortcutIDs).union(pending.disabledShortcutIDs)).sorted()
        if let states = pending.previousShortcutStates {
            evidence.previousShortcutStates = (evidence.previousShortcutStates ?? [:]).merging(states) { _, newest in newest }
        }
        evidence.shortcutsWerePersisted = evidence.shortcutsWerePersisted || pending.shortcutsWerePersisted
        for record in pending.displayRestores {
            evidence.displayRestores.removeAll { $0.displayUUID == record.displayUUID }
            evidence.displayRestores.append(record)
        }
        return evidence
    }

    // MARK: - Durable filesystem operations

    private static func createDirectoryDurably(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        let parent = url.deletingLastPathComponent()
        if parent != url { try createDirectoryDurably(parent) }
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { if !FileManager.default.fileExists(atPath: url.path) { throw error } }
        try syncDirectory(parent)
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw JournalError.io("opening directory", errno) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw JournalError.io("syncing directory", errno) }
    }

    /// Injection point for tests; the production writer never silently downgrades a flush failure.
    static func writeDurably(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".commit-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw JournalError.io("creating temporary file", errno) }
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw JournalError.io("writing file", count == 0 ? EIO : errno) }
                written += count
            }
        }
        guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else { throw JournalError.io("flushing file", errno) }
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw JournalError.io("committing file", errno) }
        try syncDirectory(directory)
        // Flush the rename/directory synchronization through the storage device as well.
        guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else { throw JournalError.io("flushing commit", errno) }
    }

    // MARK: - Shared convenience

    static func inspect() -> JournalLoadResult { shared.inspect() }
    static func load() throws -> GameModeState { try shared.load() }
    static func begin(_ state: GameModeState) throws { try shared.begin(state) }
    static func write(_ state: GameModeState) throws { try shared.begin(state) }
    static func update(_ mutate: (inout GameModeState) -> Void) throws { try shared.update(mutate) }
    static func complete() throws { try shared.complete() }
    static func clear() throws { try shared.complete() }
    static func reset() throws { try shared.reset() }
    static func archiveAndReset() throws { try shared.archiveAndReset() }
    static var hasDirtyState: Bool { shared.hasDirtyState }
}
