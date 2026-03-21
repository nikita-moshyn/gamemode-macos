//
//  StateJournalTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 21/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import XCTest
@testable import GameMode

final class StateJournalTests: XCTestCase {

    private var tempDir: URL!
    private var journal: StateJournal!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameModeTests-\(UUID().uuidString)")
        journal = StateJournal(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        journal = nil
        tempDir = nil
        super.tearDown()
    }

    func test_load_noFile_returnsInactive() {
        let state = journal.load()
        XCTAssertFalse(state.isActive)
    }

    func test_writeAndLoad_roundTrip() {
        let changes = AppliedChanges(
            functionKeysChanged: true,
            previousFunctionKeysEnabled: false,
            disabledShortcutIDs: [64, 60],
            previousShortcutStates: [64: true, 60: true],
            mouseSpeedChanged: true,
            previousMouseSpeed: 0.3,
            gesturesChanged: true,
            previousGestureValues: ["TrackpadKey": ["com.apple.domain": 2]]
        )
        let state = GameModeState(
            isActive: true,
            activatedAt: Date(),
            appliedChanges: changes
        )

        journal.write(state)
        let loaded = journal.load()

        XCTAssertTrue(loaded.isActive)
        XCTAssertTrue(loaded.appliedChanges.functionKeysChanged)
        XCTAssertEqual(loaded.appliedChanges.previousFunctionKeysEnabled, false)
        XCTAssertEqual(loaded.appliedChanges.disabledShortcutIDs, [64, 60])
        XCTAssertEqual(loaded.appliedChanges.previousMouseSpeed, 0.3)
        XCTAssertTrue(loaded.appliedChanges.gesturesChanged)
    }

    func test_hasDirtyState_trueWhenActive() {
        let state = GameModeState(
            isActive: true, activatedAt: Date(),
            appliedChanges: .empty
        )
        journal.write(state)
        XCTAssertTrue(journal.hasDirtyState)
    }

    func test_hasDirtyState_falseWhenInactive() {
        let state = GameModeState(
            isActive: false, activatedAt: nil,
            appliedChanges: .empty
        )
        journal.write(state)
        XCTAssertFalse(journal.hasDirtyState)
    }

    func test_clear_removesFile() {
        let state = GameModeState(
            isActive: true, activatedAt: Date(),
            appliedChanges: .empty
        )
        journal.write(state)
        journal.clear()

        XCTAssertFalse(journal.load().isActive)
        XCTAssertFalse(journal.hasDirtyState)
    }

    func test_update_mutatesAndPersists() {
        journal.write(.inactive)
        journal.update { $0.isActive = true }
        XCTAssertTrue(journal.load().isActive)
    }

    func test_update_modifiesAppliedChanges() {
        let state = GameModeState(
            isActive: true, activatedAt: Date(),
            appliedChanges: .empty
        )
        journal.write(state)

        journal.update {
            $0.appliedChanges.mouseSpeedChanged = true
            $0.appliedChanges.previousMouseSpeed = 0.3
        }

        let loaded = journal.load()
        XCTAssertTrue(loaded.appliedChanges.mouseSpeedChanged)
        XCTAssertEqual(loaded.appliedChanges.previousMouseSpeed, 0.3)
    }
}

// MARK: - AppliedChanges Codable Migration Tests

final class AppliedChangesCodableTests: XCTestCase {

    func test_decodeWithoutGestureFields_defaultsToFalse() throws {
        let json = """
        {
            "functionKeysChanged": true,
            "previousFunctionKeysEnabled": false,
            "disabledShortcutIDs": [64],
            "mouseSpeedChanged": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppliedChanges.self, from: json)
        XCTAssertTrue(decoded.functionKeysChanged)
        XCTAssertFalse(decoded.gesturesChanged)
        XCTAssertNil(decoded.previousGestureValues)
    }

    func test_fullRoundTrip() throws {
        let original = AppliedChanges(
            functionKeysChanged: true,
            previousFunctionKeysEnabled: true,
            disabledShortcutIDs: [64, 60],
            previousShortcutStates: [64: true, 60: false],
            mouseSpeedChanged: true,
            previousMouseSpeed: 0.5,
            gesturesChanged: true,
            previousGestureValues: [
                "TrackpadThreeFingerVertSwipeGesture": [
                    "com.apple.AppleMultitouchTrackpad": 2,
                    "com.apple.driver.AppleBluetoothMultitouch.trackpad": 2,
                ],
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppliedChanges.self, from: data)

        XCTAssertEqual(decoded.functionKeysChanged, original.functionKeysChanged)
        XCTAssertEqual(decoded.previousFunctionKeysEnabled, original.previousFunctionKeysEnabled)
        XCTAssertEqual(decoded.disabledShortcutIDs, original.disabledShortcutIDs)
        XCTAssertEqual(decoded.previousShortcutStates, original.previousShortcutStates)
        XCTAssertEqual(decoded.mouseSpeedChanged, original.mouseSpeedChanged)
        XCTAssertEqual(decoded.previousMouseSpeed, original.previousMouseSpeed)
        XCTAssertEqual(decoded.gesturesChanged, original.gesturesChanged)
        XCTAssertNotNil(decoded.previousGestureValues)
    }
}
