//
//  GameModeConfigTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 21/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

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
    }

    func test_defaults_hasExpectedStructure() {
        let config = GameModeConfig.defaults
        XCTAssertEqual(config.monitoredApps.count, MonitoredApp.presets.count)
        XCTAssertTrue(config.functionKeysInGamingMode)
        XCTAssertEqual(config.mouse.gamingSpeed, 0.5)
        XCTAssertTrue(config.system.restoreOnShutdown)
        XCTAssertTrue(config.system.restoreOnLaunch)
        XCTAssertEqual(config.shortcuts.count, ShortcutEntry.defaults.count)
        XCTAssertEqual(config.gestures.count, GestureEntry.defaults.count)
        XCTAssertEqual(config.hotkeys.count, AppHotkey.defaults.count)
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
