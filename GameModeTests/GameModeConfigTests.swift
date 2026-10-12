//
//  GameModeConfigTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Sparkle
import XCTest
@testable import GameMode

final class GameModeConfigTests: XCTestCase {

    func test_codableRoundTrip() throws {
        let original = GameModeConfig.defaults
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GameModeConfig.self, from: data)

        XCTAssertEqual(decoded.monitoredApps.count, original.monitoredApps.count)
        XCTAssertEqual(decoded.shortcuts.count, original.shortcuts.count)
        XCTAssertEqual(decoded.functionKeysInGamingMode, original.functionKeysInGamingMode)
        XCTAssertEqual(decoded.isInputGuardEnabled, original.isInputGuardEnabled)
        XCTAssertEqual(decoded.gestures.count, original.gestures.count)
        XCTAssertEqual(decoded.hotkeys.count, original.hotkeys.count)
    }

    func test_migrationSafe_missingGesturesAndHotkeys() throws {
        // Simulate old config without gestures and hotkeys
        let oldConfig = """
        {
            "monitoredApps": [],
            "shortcuts": [],
            "functionKeysInGamingMode": true,
            "mouse": {"gamingSpeed": 0.5},
            "system": {"restoreOnShutdown": true, "restoreOnLaunch": true}
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GameModeConfig.self, from: oldConfig)
        XCTAssertEqual(decoded.gestures.count, GestureEntry.defaults.count)
        XCTAssertEqual(decoded.hotkeys.count, AppHotkey.defaults.count)
        XCTAssertTrue(decoded.isInputGuardEnabled, "Keep legacy function-key protection enabled")
    }

    func test_defaults_hasExpectedStructure() {
        let config = GameModeConfig.defaults
        XCTAssertEqual(config.monitoredApps.count, MonitoredApp.presets.count)
        XCTAssertFalse(config.functionKeysInGamingMode)
        XCTAssertFalse(config.isInputGuardEnabled)
        XCTAssertTrue(config.shortcuts.allSatisfy { !$0.disableInGamingMode })
        XCTAssertTrue(config.gestures.allSatisfy { !$0.disableInGamingMode })
        XCTAssertEqual(config.mouse.gamingSpeed, 0.5)
        XCTAssertTrue(config.system.restoreOnShutdown)
        XCTAssertTrue(config.system.restoreOnLaunch)
        XCTAssertEqual(config.shortcuts.count, ShortcutEntry.defaults.count)
        XCTAssertEqual(config.gestures.count, GestureEntry.defaults.count)
        XCTAssertEqual(config.hotkeys.count, AppHotkey.defaults.count)
    }

    func test_betaUpdatesRequireExplicitOptInAndSurviveRoundTrip() throws {
        var config = GameModeConfig.defaults
        XCTAssertFalse(config.receivesBetaUpdates)
        XCTAssertTrue(config.allowedUpdateChannels.isEmpty)

        config.receivesBetaUpdates = true
        var reloaded = try JSONDecoder().decode(GameModeConfig.self, from: JSONEncoder().encode(config))
        XCTAssertTrue(reloaded.receivesBetaUpdates)
        XCTAssertEqual(reloaded.allowedUpdateChannels, ["beta", "rc"])

        reloaded.receivesBetaUpdates = false
        XCTAssertTrue(reloaded.allowedUpdateChannels.isEmpty)
    }

    func test_existingInstallDoesNotAutomaticallyOptIntoBetaUpdates() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(GameModeConfig.defaults)) as? [String: Any])
        object.removeValue(forKey: "receivesBetaUpdates")
        let reloaded = try JSONDecoder().decode(GameModeConfig.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(reloaded.receivesBetaUpdates)
        XCTAssertTrue(reloaded.allowedUpdateChannels.isEmpty)
    }

    func test_sparkleBuildVersionsAdvanceThroughBetaRCAndStable() {
        let comparator = SUStandardVersionComparator.default
        let builds = ["0.1.1", "0.1.2b1", "0.1.2b2", "0.1.2b10", "0.1.2rc1", "0.1.2rc2", "0.1.2", "0.1.3b1"]
        for (older, newer) in zip(builds, builds.dropFirst()) {
            XCTAssertEqual(comparator.compareVersion(older, toVersion: newer), .orderedAscending, "\(older) must precede \(newer)")
        }
        XCTAssertEqual(comparator.compareVersion("0.0.1-beta.3", toVersion: "0.1.2b1"), .orderedAscending)
        XCTAssertEqual(comparator.compareVersion("0.1.2-beta.1", toVersion: "0.1.2-beta.2"), .orderedSame, "Hyphenated display versions must never be used as build versions")
    }

    func test_inputGuardMasterGatesAllEffectsWithoutLosingSelections() throws {
        var config = GameModeConfig.defaults
        config.functionKeysInGamingMode = true
        config.shortcuts[0].disableInGamingMode = true
        config.gestures[0].disableInGamingMode = true
        XCTAssertEqual(config.inputGuardPolicy, .disabled)

        config.isInputGuardEnabled = true
        let selected = config.inputGuardPolicy
        XCTAssertTrue(selected.functionKeysEnabled)
        XCTAssertEqual(selected.shortcutIDs, [config.shortcuts[0].id])
        XCTAssertEqual(selected.gestures, [config.gestures[0]])

        config.isInputGuardEnabled = false
        var reloaded = try JSONDecoder().decode(GameModeConfig.self, from: JSONEncoder().encode(config))
        XCTAssertFalse(reloaded.isInputGuardEnabled)
        XCTAssertEqual(reloaded.inputGuardPolicy, .disabled)
        reloaded.isInputGuardEnabled = true
        XCTAssertEqual(reloaded.inputGuardPolicy, selected)
    }

    func test_legacyInputGuardSelectionsMigrateWithoutOptingInUnselectedFeatures() throws {
        for selection in ["none", "functionKeys", "shortcut", "gesture"] {
            var legacy = GameModeConfig.defaults
            legacy.functionKeysInGamingMode = selection == "functionKeys"
            legacy.shortcuts[0].disableInGamingMode = selection == "shortcut"
            legacy.gestures[0].disableInGamingMode = selection == "gesture"
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
            object.removeValue(forKey: "isInputGuardEnabled")
            let decoded = try JSONDecoder().decode(GameModeConfig.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.isInputGuardEnabled, selection != "none")
            XCTAssertEqual(decoded.functionKeysInGamingMode, legacy.functionKeysInGamingMode)
            XCTAssertEqual(decoded.shortcuts, legacy.shortcuts)
            XCTAssertEqual(decoded.gestures, legacy.gestures)
        }
    }
}

// MARK: - MouseConfig Tests

final class MouseConfigTests: XCTestCase {

    func test_defaultValues() {
        let config = MouseConfig()
        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.gamingSpeed, 0.5)
        XCTAssertFalse(config.isMouseBoostEnabled)
    }

    func test_migrationSafe_missingFields() throws {
        // Only gamingSpeed present — isEnabled and isMouseBoostEnabled should default
        let json = """
        {"gamingSpeed": 0.7}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MouseConfig.self, from: json)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.gamingSpeed, 0.7)
        XCTAssertFalse(decoded.isMouseBoostEnabled)
    }

    func test_codableRoundTrip() throws {
        let original = MouseConfig(isEnabled: false, gamingSpeed: 0.8, isMouseBoostEnabled: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MouseConfig.self, from: data)
        XCTAssertEqual(decoded.isEnabled, false)
        XCTAssertEqual(decoded.gamingSpeed, 0.8)
        XCTAssertEqual(decoded.isMouseBoostEnabled, true)
    }
}
