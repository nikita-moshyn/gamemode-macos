//
//  KeyCodeMapTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 21/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import XCTest
@testable import GameMode

final class KeyCodeMapTests: XCTestCase {

    // MARK: - name(for:)

    func test_letterKeys() {
        XCTAssertEqual(KeyCodeMap.name(for: 0), "A")
        XCTAssertEqual(KeyCodeMap.name(for: 5), "G")
        XCTAssertEqual(KeyCodeMap.name(for: 46), "M")
    }

    func test_numberKeys() {
        XCTAssertEqual(KeyCodeMap.name(for: 18), "1")
        XCTAssertEqual(KeyCodeMap.name(for: 29), "0")
    }

    func test_functionKeys() {
        XCTAssertEqual(KeyCodeMap.name(for: 122), "F1")
        XCTAssertEqual(KeyCodeMap.name(for: 120), "F2")
        XCTAssertEqual(KeyCodeMap.name(for: 111), "F12")
        XCTAssertEqual(KeyCodeMap.name(for: 90), "F20")
    }

    func test_arrowKeys() {
        XCTAssertEqual(KeyCodeMap.name(for: 123), "←")
        XCTAssertEqual(KeyCodeMap.name(for: 124), "→")
        XCTAssertEqual(KeyCodeMap.name(for: 125), "↓")
        XCTAssertEqual(KeyCodeMap.name(for: 126), "↑")
    }

    func test_specialKeys() {
        XCTAssertEqual(KeyCodeMap.name(for: 36), "Return")
        XCTAssertEqual(KeyCodeMap.name(for: 49), "Space")
        XCTAssertEqual(KeyCodeMap.name(for: 53), "Escape")
        XCTAssertEqual(KeyCodeMap.name(for: 48), "Tab")
        XCTAssertEqual(KeyCodeMap.name(for: 51), "Delete")
    }

    func test_unknownKeyCode_returnsKeyN() {
        XCTAssertEqual(KeyCodeMap.name(for: 255), "Key255")
        XCTAssertEqual(KeyCodeMap.name(for: 200), "Key200")
    }

    // MARK: - menuKeyEquivalent(for:)

    func test_menuKeyEquivalent_letterKeys() {
        XCTAssertEqual(KeyCodeMap.menuKeyEquivalent(for: 0), "a")
        XCTAssertEqual(KeyCodeMap.menuKeyEquivalent(for: 5), "g")
    }

    func test_menuKeyEquivalent_numberKeys() {
        XCTAssertEqual(KeyCodeMap.menuKeyEquivalent(for: 18), "1")
    }

    func test_menuKeyEquivalent_functionKey_returnsNil() {
        XCTAssertNil(KeyCodeMap.menuKeyEquivalent(for: 122))
    }

    func test_menuKeyEquivalent_arrowKey_returnsNil() {
        XCTAssertNil(KeyCodeMap.menuKeyEquivalent(for: 123))
    }

    func test_menuKeyEquivalent_unknownKey_returnsNil() {
        XCTAssertNil(KeyCodeMap.menuKeyEquivalent(for: 255))
    }
}
