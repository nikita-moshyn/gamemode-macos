//
//  SymbolicHotkeysTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 21/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import XCTest
@testable import GameMode

final class SymbolicHotkeysTests: XCTestCase {

    func test_categoriesAreUnique() {
        let categories = SymbolicHotkeys.categories
        XCTAssertEqual(Set(categories).count, categories.count)
    }

    func test_categoriesPreserveOrder() {
        let categories = SymbolicHotkeys.categories
        XCTAssertEqual(categories.first, "Spotlight")
        XCTAssertTrue(categories.count >= 2)
        XCTAssertEqual(categories[1], "Input Sources")
    }

    func test_entriesForCategory_spotlight() {
        let entries = SymbolicHotkeys.entries(for: "Spotlight")
        XCTAssertEqual(entries.count, 2)
        let ids = Set(entries.map { $0.id })
        XCTAssertTrue(ids.contains(64))
        XCTAssertTrue(ids.contains(65))
    }

    func test_entriesForCategory_unknown_returnsEmpty() {
        let entries = SymbolicHotkeys.entries(for: "Nonexistent")
        XCTAssertTrue(entries.isEmpty)
    }

    func test_nameForID_known() {
        XCTAssertEqual(SymbolicHotkeys.name(for: 64), "Show Spotlight Search")
        XCTAssertEqual(SymbolicHotkeys.name(for: 175), "Siri")
    }

    func test_nameForID_unknown_returnsNil() {
        XCTAssertNil(SymbolicHotkeys.name(for: 9999))
    }

    func test_allEntriesHaveValidCategories() {
        let validCategories = Set(SymbolicHotkeys.categories)
        for entry in SymbolicHotkeys.all {
            XCTAssertTrue(
                validCategories.contains(entry.category),
                "Entry \(entry.id) has invalid category: \(entry.category)"
            )
        }
    }

    func test_allEntriesHaveUniqueIDs() {
        let ids = SymbolicHotkeys.all.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
