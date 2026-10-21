//
//  RecoveryBackup.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import CryptoKit
import Darwin
import Foundation

struct RecoveryBackup: Codable, Equatable, Sendable {
    enum Setting: String, Codable, CaseIterable, Sendable {
        case functionKeys, gestures, mouse, displays, power, shortcuts
        var title: String {
            switch self {
            case .functionKeys: return "Function Keys"
            case .gestures: return "Trackpad Gestures"
            case .mouse: return "Mouse Speed"
            case .displays: return "Displays"
            case .power: return "Low Power Mode"
            case .shortcuts: return "Keyboard Shortcuts"
            }
        }
    }
    struct Row: Identifiable, Equatable, Sendable {
        var id: Setting
        var value: String
    }
    var version = 1
    var createdAt = Date()
    var machine: String
    var user: UInt32
    var changes: AppliedChanges

    init(changes: AppliedChanges, machine: String? = RecoveryIdentity.machine, user: UInt32 = getuid()) throws {
        guard let machine else { throw JournalError.invalid("This Mac could not be identified. Try again.") }
        self.machine = machine
        self.user = user
        self.changes = changes
    }

    var rows: [Row] {
        var rows: [Row] = []
        if changes.functionKeysChanged, let value = changes.previousFunctionKeysEnabled {
            rows.append(.init(id: .functionKeys, value: value ? "Standard F1–F12" : "Brightness and volume"))
        }
        if changes.gesturesChanged, let values = changes.previousGestureValues {
            rows.append(.init(id: .gestures, value: values.count == 1 ? "1 saved gesture" : "\(values.count) saved gestures"))
        }
        if changes.mouseSpeedChanged, let speed = changes.previousMouseSpeed { rows.append(.init(id: .mouse, value: String(format: "%.2f", speed))) }
        #if FEATURE_DISPLAYS
        if !changes.displayRestores.isEmpty {
            let count = changes.displayRestores.count
            rows.append(.init(id: .displays, value: count == 1 ? "1 saved display" : "\(count) saved displays"))
        }
        if changes.lowPowerModeChanged, let values = changes.previousLowPowerModeSettings {
            let labels = [("b", "Battery"), ("c", "Charger"), ("u", "UPS")].compactMap { key, label in values[key].map { label + ": " + ($0 == 0 ? "Off" : "On") } }
            rows.append(.init(id: .power, value: labels.joined(separator: ", ")))
        }
        #endif
        if changes.shortcutsWerePersisted, let values = changes.previousShortcutStates, !values.isEmpty { rows.append(.init(id: .shortcuts, value: "\(values.count) saved shortcuts")) }
        return rows
    }

    var settings: Set<Setting> { Set(rows.map(\.id)) }

    func selecting(_ settings: Set<Setting>) -> AppliedChanges {
        var result = changes
        if !settings.contains(.functionKeys) { result.functionKeysChanged = false; result.previousFunctionKeysEnabled = nil; result.functionKeyContext = nil }
        if !settings.contains(.gestures) { result.gesturesChanged = false; result.previousGestureValues = nil }
        if !settings.contains(.mouse) { result.mouseSpeedChanged = false; result.previousMouseSpeed = nil }
        if !settings.contains(.displays) { result.displayRestores = [] }
        if !settings.contains(.power) { result.lowPowerModeChanged = false; result.previousLowPowerModeSettings = nil }
        if !settings.contains(.shortcuts) { result.shortcutsWerePersisted = false; result.previousShortcutStates = nil; result.disabledShortcutIDs = [] }
        return result
    }

    /// Files contain data only. Never accept arbitrary preference domains, paths,
    /// command names, or unbounded native values from an imported backup.
    func validate(machine: String? = RecoveryIdentity.machine, user: UInt32 = getuid()) throws {
        guard version == 1, self.machine == machine, self.user == user else {
            throw JournalError.invalid("Choose a recovery file saved by this user on this Mac.")
        }
        guard !changes.legacyFunctionKeyCleanupPending, changes.functionKeyOverrideRemoval == nil,
              !changes.functionKeysChanged || changes.previousFunctionKeysEnabled != nil,
              !changes.mouseSpeedChanged || changes.previousMouseSpeed.map({ $0.isFinite && (-1...20).contains($0) }) == true else {
            throw JournalError.invalid("This recovery file contains invalid settings.")
        }
        if changes.gesturesChanged {
            guard let gestures = changes.previousGestureValues, !gestures.isEmpty, gestures.count <= GestureEntry.defaults.count else { throw JournalError.invalid("Saved gestures are incomplete.") }
            for (key, domains) in gestures {
                guard let entry = GestureEntry.defaults.first(where: { $0.id == key }), !domains.isEmpty,
                      Set(domains.keys).isSubset(of: Set(entry.domains)), domains.values.allSatisfy({ $0.map { (0...10).contains($0) } ?? true }) else {
                    throw JournalError.invalid("This recovery file contains an unsupported gesture setting.")
                }
            }
        }
        if changes.lowPowerModeChanged {
            guard let values = changes.previousLowPowerModeSettings, !values.isEmpty, Set(values.keys).isSubset(of: ["b", "c", "u"]), values.values.allSatisfy({ $0 == 0 || $0 == 1 }) else { throw JournalError.invalid("Saved power settings are incomplete.") }
        }
        guard changes.displayRestores.count <= 32, Set(changes.displayRestores.map(\.displayUUID)).count == changes.displayRestores.count else { throw JournalError.invalid("Saved displays are invalid.") }
        for display in changes.displayRestores {
            let mode = display.mode
            guard !display.displayUUID.isEmpty, display.displayUUID.count <= 128, display.displayName.count <= 256,
                  [mode.width, mode.height, mode.pixelWidth, mode.pixelHeight].allSatisfy({ (1...32768).contains($0) }),
                  mode.refreshRate.isFinite, (0...1000).contains(mode.refreshRate) else { throw JournalError.invalid("A saved display mode is invalid.") }
        }
        if changes.shortcutsWerePersisted {
            guard let values = changes.previousShortcutStates, values.count <= 1024, values.keys.allSatisfy({ (0...65535).contains($0) }) else { throw JournalError.invalid("Saved shortcut settings are incomplete.") }
        }
    }

    private struct FileContents: Codable { var format = "GameMode Recovery"; var payload: Data; var checksum: String }

    func write(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(self)
        let file = FileContents(payload: payload, checksum: Self.checksum(payload))
        try encoder.encode(file).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read(from url: URL) throws -> RecoveryBackup {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let count = size.fileSize, count > 0, count <= 2_000_000 else { throw JournalError.invalid("Choose a GameMode recovery file.") }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw JournalError.invalid("This recovery file is too large.") }
        let decoder = JSONDecoder()
        let file = try decoder.decode(FileContents.self, from: data)
        guard file.format == "GameMode Recovery", file.checksum == checksum(file.payload) else { throw JournalError.invalid("This recovery file is damaged. Choose another copy.") }
        let backup = try decoder.decode(Self.self, from: file.payload)
        try backup.validate()
        return backup
    }

    private static func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
