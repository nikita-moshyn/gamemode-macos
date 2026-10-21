//
//  RecoveryFixture.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

#if DEBUG
import Foundation

/// Subprocess tests exercise real SIGKILL and locks against a file-backed keyboard.
/// This entry point is absent from release executables.
enum RecoveryFixture {
    struct Keyboard: Codable {
        var live: Bool
        var preferences: FunctionKeyPreferences
        var bootSession: String
    }

    static func access(at url: URL) -> SettingsManager.FunctionKeyAccess {
        func read() throws -> Keyboard { try JSONDecoder().decode(Keyboard.self, from: Data(contentsOf: url)) }
        func write(_ keyboard: Keyboard) throws { try JSONEncoder().encode(keyboard).write(to: url, options: .atomic) }
        return .init(read: { try? read().live }, apply: { value in
            do { var keyboard = try read(); keyboard.live = value; try write(keyboard); return true }
            catch { return false }
        }, bootSession: { (try? read().bootSession) ?? "" },
                     readPreferences: { try read().preferences }, removeOverride: { expected in
            var keyboard = try read()
            guard keyboard.preferences == expected else { throw JournalError.changedBaseline }
            keyboard.preferences.host = nil
            try write(keyboard)
        }, removeLegacyPreference: {
            var keyboard = try read()
            guard keyboard.preferences.hasLegacyConflict else { return }
            keyboard.preferences.host = nil
            try write(keyboard)
        })
    }

    struct SystemState: Codable {
        var mouse: Double
        var gesture: Int
        var power: [String: Int]
        var refreshRate: Double
    }

    static func controller(files: RecoveryAgentFiles, settings: SettingsManager, journal: StateJournal) -> RecoveryController {
        let native = RecoveryController.system(journal: journal, settings: settings)
        let file = files.support.appendingPathComponent("system.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return native }
        func read() throws -> SystemState { try JSONDecoder().decode(SystemState.self, from: Data(contentsOf: file)) }
        func update(_ change: (inout SystemState) -> Void) throws {
            var value = try read()
            change(&value)
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
        }
        var operations = native.operations
        operations.readMouse = { try? read().mouse }
        operations.applyMouse = { speed in do { try update { $0.mouse = speed }; return true } catch { return false } }
        operations.restoreKeyboard = { changes in
            var keyboardOnly = changes
            keyboardOnly.gesturesChanged = false
            var errors = settings.restoreKeyboardSettings(from: keyboardOnly)
            if changes.gesturesChanged {
                do { try update { $0.gesture = (changes.previousGestureValues?["fixture"]?["fixture"] ?? nil) ?? 2 } }
                catch { errors.append(error.localizedDescription) }
            }
            return errors
        }
        operations.restorePower = { values in do { try update { $0.power = values }; return [] } catch { return [error.localizedDescription] } }
        operations.restoreDisplays = { records in
            do { if let first = records.first { try update { $0.refreshRate = first.mode.refreshRate } }; return [] }
            catch { return [error.localizedDescription] }
        }
        return RecoveryController(journal: journal, operations: operations)
    }

    static func ownSession(files: RecoveryAgentFiles, settings: SettingsManager) throws {
        let lock = ApplicationInstanceLock(directory: files.support)
        try lock.acquire()
        defer { withExtendedLifetime(lock) {} }
        try CrashRecoveryProtection.handshake(files: files)
        let snapshot = try settings.captureKeyboardSettings(functionKeyBehavior: .standard, shortcutIDs: [], gestures: [])
        var changes = AppliedChanges.empty
        changes.functionKeysChanged = snapshot.functionKeysChanged
        changes.previousFunctionKeysEnabled = snapshot.previousFunctionKeysEnabled
        changes.functionKeyContext = snapshot.functionKeyContext
        let systemFile = files.support.appendingPathComponent("system.json")
        var system = try? JSONDecoder().decode(SystemState.self, from: Data(contentsOf: systemFile))
        if let original = system {
            changes.mouseSpeedChanged = true
            changes.previousMouseSpeed = original.mouse
            changes.gesturesChanged = true
            changes.previousGestureValues = ["fixture": ["fixture": original.gesture]]
            changes.lowPowerModeChanged = true
            changes.previousLowPowerModeSettings = original.power
            changes.displayRestores = [.init(displayUUID: "fixture", displayName: "Fixture Display", mode: .init(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: original.refreshRate, ioFlags: 0, modeID: 1))]
        }
        let journal = StateJournal(directory: files.support.appendingPathComponent("GameMode"))
        try journal.begin(.init(isActive: true, activatedAt: Date(), appliedChanges: changes))
        try settings.applyKeyboardSettings(snapshot)
        if system != nil {
            system?.mouse = 1.5
            system?.gesture = 0
            system?.power = ["b": 0, "c": 0]
            system?.refreshRate = 120
            try JSONEncoder().encode(system).write(to: systemFile, options: .atomic)
        }
        try Data("armed".utf8).write(to: files.support.appendingPathComponent("armed"))
        RunLoop.main.run()
    }
}
#endif
