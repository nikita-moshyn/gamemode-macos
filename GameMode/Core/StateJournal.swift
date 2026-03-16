//
//  StateJournal.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

// MARK: - State Model

struct GameModeState: Codable {
    var isActive: Bool
    var activatedAt: Date?
    var appliedChanges: AppliedChanges

    static let inactive = GameModeState(
        isActive: false,
        activatedAt: nil,
        appliedChanges: .empty
    )
}

struct AppliedChanges: Codable {
    var functionKeysChanged: Bool
    var disabledShortcutIDs: [Int]
    var mouseSpeedChanged: Bool
    var previousMouseSpeed: Double?
    var gesturesChanged: Bool
    var previousGestureValues: [String: Int]?

    static let empty = AppliedChanges(
        functionKeysChanged: false,
        disabledShortcutIDs: [],
        mouseSpeedChanged: false,
        previousMouseSpeed: nil,
        gesturesChanged: false,
        previousGestureValues: nil
    )

    // Migration-safe decoder: older journals won't have gesture fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        functionKeysChanged = try container.decode(Bool.self, forKey: .functionKeysChanged)
        disabledShortcutIDs = try container.decode([Int].self, forKey: .disabledShortcutIDs)
        mouseSpeedChanged = try container.decode(Bool.self, forKey: .mouseSpeedChanged)
        previousMouseSpeed = try container.decodeIfPresent(Double.self, forKey: .previousMouseSpeed)
        gesturesChanged = try container.decodeIfPresent(Bool.self, forKey: .gesturesChanged) ?? false
        previousGestureValues = try container.decodeIfPresent([String: Int].self, forKey: .previousGestureValues)
    }

    init(functionKeysChanged: Bool, disabledShortcutIDs: [Int], mouseSpeedChanged: Bool,
         previousMouseSpeed: Double?, gesturesChanged: Bool = false,
         previousGestureValues: [String: Int]? = nil) {
        self.functionKeysChanged = functionKeysChanged
        self.disabledShortcutIDs = disabledShortcutIDs
        self.mouseSpeedChanged = mouseSpeedChanged
        self.previousMouseSpeed = previousMouseSpeed
        self.gesturesChanged = gesturesChanged
        self.previousGestureValues = previousGestureValues
    }
}

// MARK: - Journal (file-based state persistence for crash recovery)

/// Writes gaming mode state to disk so settings can be restored after
/// a crash, force-reboot, or unexpected termination.
///
/// The journal is written **synchronously before any settings change**
/// and cleared **after all settings are restored**. If the process dies
/// between those two points, the next launch reads the journal and
/// restores everything.
///
/// File: `~/Library/Application Support/GameMode/state.json`
class StateJournal {

    private static let directory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("GameMode")
    }()

    private static let fileURL: URL = {
        directory.appendingPathComponent("state.json")
    }()

    /// Write state atomically. MUST complete before settings are modified.
    static func write(_ state: GameModeState) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
            print("[StateJournal] Written: isActive=\(state.isActive)")
        } catch {
            print("[StateJournal] Write failed: \(error)")
        }
    }

    /// Load state. Returns inactive if file is missing or corrupt.
    static func load() -> GameModeState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(GameModeState.self, from: data)
        else {
            return .inactive
        }
        return state
    }

    /// Clear journal after successful restore.
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        print("[StateJournal] Cleared")
    }

    /// Check if there's a dirty state (gaming mode was active when app died).
    static var hasDirtyState: Bool {
        load().isActive
    }
}
