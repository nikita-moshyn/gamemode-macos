//
//  AppHotkeyTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 21/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import XCTest
import AppKit
@testable import GameMode

final class AppHotkeyTests: XCTestCase {

    func test_displayString_commandShiftG() {
        let hotkey = AppHotkey(
            id: "test", name: "Test",
            keyCode: 5,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            isEnabled: true
        )
        XCTAssertEqual(hotkey.displayString, "⇧⌘G")
    }

    func test_displayString_controlOptionA() {
        let hotkey = AppHotkey(
            id: "test", name: "Test",
            keyCode: 0,
            modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue,
            isEnabled: true
        )
        XCTAssertEqual(hotkey.displayString, "⌃⌥A")
    }

    func test_displayString_nilKeyCode_returnsNotSet() {
        let hotkey = AppHotkey(
            id: "test", name: "Test",
            keyCode: nil,
            modifiers: 0,
            isEnabled: false
        )
        XCTAssertEqual(hotkey.displayString, "Not Set")
    }

    func test_displayString_noModifiers_keyOnly() {
        let hotkey = AppHotkey(
            id: "test", name: "Test",
            keyCode: 49,
            modifiers: 0,
            isEnabled: true
        )
        XCTAssertEqual(hotkey.displayString, "Space")
    }

    func test_codableRoundTrip() throws {
        let original = AppHotkey(
            id: "toggleGameMode", name: "Toggle Gaming Mode",
            keyCode: 5,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            isEnabled: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppHotkey.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.keyCode, original.keyCode)
        XCTAssertEqual(decoded.modifiers, original.modifiers)
        XCTAssertEqual(decoded.isEnabled, original.isEnabled)
    }

    func test_defaults_count() {
        XCTAssertEqual(AppHotkey.defaults.count, 3)
    }

    func test_defaults_toggleGameMode_isEnabled() {
        let toggle = AppHotkey.defaults.first { $0.id == "toggleGameMode" }
        XCTAssertNotNil(toggle)
        XCTAssertTrue(toggle!.isEnabled)
        XCTAssertEqual(toggle!.keyCode, 5)
    }
}
