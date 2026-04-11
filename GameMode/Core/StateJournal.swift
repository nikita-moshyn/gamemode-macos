//
//  StateJournal.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

// MARK: - State Model

typealias GesturePreferenceValues = [String: [String: Int?]]

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
    var previousFunctionKeysEnabled: Bool?
    var disabledShortcutIDs: [Int]
    var previousShortcutStates: [Int: Bool]?
    var mouseSpeedChanged: Bool
    var previousMouseSpeed: Double?
    var gesturesChanged: Bool
    var previousGestureValues: GesturePreferenceValues?
    var lowPowerModeChanged: Bool
    var previousLowPowerModeEnabled: Bool?

    static let empty = AppliedChanges(
        functionKeysChanged: false,
        previousFunctionKeysEnabled: nil,
        disabledShortcutIDs: [],
        previousShortcutStates: nil,
        mouseSpeedChanged: false,
        previousMouseSpeed: nil,
        gesturesChanged: false,
        previousGestureValues: nil,
        lowPowerModeChanged: false,
        previousLowPowerModeEnabled: nil
    )

    // Migration-safe decoder: older journals won't have gesture fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        functionKeysChanged = try container.decode(Bool.self, forKey: .functionKeysChanged)
        previousFunctionKeysEnabled = try container.decodeIfPresent(Bool.self, forKey: .previousFunctionKeysEnabled)
        disabledShortcutIDs = try container.decode([Int].self, forKey: .disabledShortcutIDs)
        previousShortcutStates = try container.decodeIfPresent([Int: Bool].self, forKey: .previousShortcutStates)
        mouseSpeedChanged = try container.decode(Bool.self, forKey: .mouseSpeedChanged)
        previousMouseSpeed = try container.decodeIfPresent(Double.self, forKey: .previousMouseSpeed)
        gesturesChanged = try container.decodeIfPresent(Bool.self, forKey: .gesturesChanged) ?? false
        let nestedOptionalValues = try? container.decodeIfPresent(
            GesturePreferenceValues.self,
            forKey: .previousGestureValues
        )
        let nestedValues = try? container.decodeIfPresent(
            [String: [String: Int]].self,
            forKey: .previousGestureValues
        )?.mapValues { domainValues in
            domainValues.mapValues { Optional($0) }
        }
        let legacyValues = try? container.decodeIfPresent(
            [String: Int].self,
            forKey: .previousGestureValues
        )?.mapValues { ["legacy": Optional($0)] }
        previousGestureValues = nestedOptionalValues ?? nestedValues ?? legacyValues
        lowPowerModeChanged = try container.decodeIfPresent(Bool.self, forKey: .lowPowerModeChanged) ?? false
        previousLowPowerModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .previousLowPowerModeEnabled)
    }

    init(functionKeysChanged: Bool, previousFunctionKeysEnabled: Bool? = nil,
         disabledShortcutIDs: [Int], previousShortcutStates: [Int: Bool]? = nil,
         mouseSpeedChanged: Bool, previousMouseSpeed: Double?, gesturesChanged: Bool = false,
         previousGestureValues: GesturePreferenceValues? = nil,
         lowPowerModeChanged: Bool = false, previousLowPowerModeEnabled: Bool? = nil) {
        self.functionKeysChanged = functionKeysChanged
        self.previousFunctionKeysEnabled = previousFunctionKeysEnabled
        self.disabledShortcutIDs = disabledShortcutIDs
        self.previousShortcutStates = previousShortcutStates
        self.mouseSpeedChanged = mouseSpeedChanged
        self.previousMouseSpeed = previousMouseSpeed
        self.gesturesChanged = gesturesChanged
        self.previousGestureValues = previousGestureValues
        self.lowPowerModeChanged = lowPowerModeChanged
        self.previousLowPowerModeEnabled = previousLowPowerModeEnabled
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

    static let shared = StateJournal()

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("state.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            return appSupport.appendingPathComponent("GameMode")
        }()
    }

    // MARK: - Instance methods

    /// Write state atomically. MUST complete before settings are modified.
    func write(_ state: GameModeState) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
            Log.debug("Journal written: isActive=\(state.isActive)", category: "StateJournal")
        } catch {
            Log.error("Journal write failed: \(error)", category: "StateJournal")
        }
    }

    /// Load-mutate-write helper for changes that happen mid-session
    /// (for example, mouse boost toggles while game mode remains active).
    func update(_ mutate: (inout GameModeState) -> Void) {
        var state = load()
        mutate(&state)
        write(state)
        Log.debug("Journal updated", category: "StateJournal")
    }

    /// Load state. Returns inactive if file is missing or corrupt.
    func load() -> GameModeState {
        guard let data = try? Data(contentsOf: fileURL) else {
            Log.debug("No journal found (clean state)", category: "StateJournal")
            return .inactive
        }
        guard let state = try? JSONDecoder().decode(GameModeState.self, from: data) else {
            Log.warning("Journal corrupt, returning inactive", category: "StateJournal")
            return .inactive
        }
        return state
    }

    /// Clear journal after successful restore.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        Log.debug("Journal cleared", category: "StateJournal")
    }

    /// Check if there's a dirty state (gaming mode was active when app died).
    var hasDirtyState: Bool {
        let dirty = load().isActive
        if dirty {
            Log.warning("Dirty state detected in journal", category: "StateJournal")
        }
        return dirty
    }

    // MARK: - Static convenience (preserves existing call sites)

    static func write(_ state: GameModeState) { shared.write(state) }
    static func update(_ mutate: (inout GameModeState) -> Void) { shared.update(mutate) }
    static func load() -> GameModeState { shared.load() }
    static func clear() { shared.clear() }
    static var hasDirtyState: Bool { shared.hasDirtyState }
}
