//
//  ConfigStoreTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 21/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import XCTest
@testable import GameMode

final class ConfigStoreTests: XCTestCase {

    private var suiteName: String!
    private var testDefaults: UserDefaults!
    private var store: ConfigStore!

    override func setUp() {
        super.setUp()
        suiteName = "com.moshyn.nikita.GameModeTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
        store = ConfigStore(defaults: testDefaults)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        store = nil
        testDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Init & Persistence

    func test_initialLoad_noSavedData_usesDefaults() {
        XCTAssertEqual(store.config.monitoredApps.count, MonitoredApp.presets.count)
        XCTAssertTrue(store.config.functionKeysInGamingMode)
    }

    func test_isFirstLaunch_trueWhenNoData() {
        XCTAssertTrue(store.isFirstLaunch)
    }

    func test_isFirstLaunch_falseAfterSave() {
        store.save()
        XCTAssertFalse(store.isFirstLaunch)
    }

    func test_saveAndLoad_roundTrip() {
        store.config.functionKeysInGamingMode = false
        // didSet triggers save() automatically

        let store2 = ConfigStore(defaults: testDefaults)
        XCTAssertFalse(store2.config.functionKeysInGamingMode)
    }

    // MARK: - App Management

    func test_addApp_success() {
        let app = MonitoredApp(
            id: UUID(), bundleID: "com.test.newgame",
            name: "New Game", isEnabled: true, source: .manual
        )
        store.addApp(app)
        XCTAssertTrue(store.config.monitoredApps.contains { $0.bundleID == "com.test.newgame" })
    }

    func test_addApp_duplicateBundleID_noop() {
        let app1 = MonitoredApp(
            id: UUID(), bundleID: "com.test.dup",
            name: "Game 1", isEnabled: true, source: .manual
        )
        let app2 = MonitoredApp(
            id: UUID(), bundleID: "com.test.dup",
            name: "Game 2", isEnabled: false, source: .manual
        )
        store.addApp(app1)
        let countBefore = store.config.monitoredApps.count
        store.addApp(app2)
        XCTAssertEqual(store.config.monitoredApps.count, countBefore)
    }

    func test_removeApp_removesCorrectApp() {
        let app = MonitoredApp(
            id: UUID(), bundleID: "com.test.remove",
            name: "Remove Me", isEnabled: true, source: .manual
        )
        store.addApp(app)
        store.removeApp(id: app.id)
        XCTAssertFalse(store.config.monitoredApps.contains { $0.id == app.id })
    }

    func test_removeApp_nonexistentID_noop() {
        let countBefore = store.config.monitoredApps.count
        store.removeApp(id: UUID())
        XCTAssertEqual(store.config.monitoredApps.count, countBefore)
    }

    func test_toggleApp_flipsIsEnabled() {
        let presetID = store.config.monitoredApps[0].id
        let wasBefore = store.config.monitoredApps[0].isEnabled
        store.toggleApp(id: presetID)
        XCTAssertEqual(store.config.monitoredApps[0].isEnabled, !wasBefore)
    }

    // MARK: - Shortcut Management

    func test_mergeDetectedShortcuts_addsNew() {
        let newEntry = ShortcutEntry(
            id: 999, name: "New Shortcut",
            category: "Test", disableInGamingMode: true
        )
        store.mergeDetectedShortcuts([newEntry])
        let found = store.config.shortcuts.first { $0.id == 999 }
        XCTAssertNotNil(found)
        // New entries are always added with disableInGamingMode=false
        XCTAssertFalse(found!.disableInGamingMode)
    }

    func test_mergeDetectedShortcuts_preservesExisting() {
        // Default shortcuts[0] has disableInGamingMode=true (Spotlight)
        let existingID = store.config.shortcuts[0].id
        XCTAssertTrue(store.config.shortcuts[0].disableInGamingMode)

        // Merge with same ID — should not overwrite
        let duplicate = ShortcutEntry(
            id: existingID, name: "Same",
            category: "Same", disableInGamingMode: false
        )
        store.mergeDetectedShortcuts([duplicate])
        let existing = store.config.shortcuts.first { $0.id == existingID }
        XCTAssertTrue(existing!.disableInGamingMode)
    }

    func test_toggleShortcut_flipsDisableInGamingMode() {
        let id = store.config.shortcuts[0].id
        let wasBefore = store.config.shortcuts[0].disableInGamingMode
        store.toggleShortcut(id: id)
        XCTAssertEqual(store.config.shortcuts[0].disableInGamingMode, !wasBefore)
    }

    // MARK: - Gesture Management

    func test_toggleGesture_flipsDisableInGamingMode() {
        let id = store.config.gestures[0].id
        let wasBefore = store.config.gestures[0].disableInGamingMode
        store.toggleGesture(id: id)
        XCTAssertEqual(store.config.gestures[0].disableInGamingMode, !wasBefore)
    }

    // MARK: - Hotkey Management

    func test_toggleHotkey_flipsIsEnabled() {
        let wasBefore = store.config.hotkeys[0].isEnabled
        store.toggleHotkey(id: "toggleGameMode")
        XCTAssertEqual(store.config.hotkeys[0].isEnabled, !wasBefore)
    }

    func test_updateHotkey_updatesKeyCodeAndModifiers() {
        store.updateHotkey(id: "toggleGameMode", keyCode: 0, modifiers: 256)
        let hotkey = store.config.hotkeys.first { $0.id == "toggleGameMode" }
        XCTAssertEqual(hotkey?.keyCode, 0)
        XCTAssertEqual(hotkey?.modifiers, 256)
    }

    // MARK: - Reset

    func test_resetAllSavedData() {
        // Mutate config
        store.config.functionKeysInGamingMode = false
        store.isGamingMode = true
        store.isMouseBoostApplied = true
        store.sessionMouseBaselineSpeed = 0.5

        store.resetAllSavedData()

        XCTAssertTrue(store.config.functionKeysInGamingMode)
        XCTAssertFalse(store.isGamingMode)
        XCTAssertFalse(store.isMouseBoostApplied)
        XCTAssertNil(store.sessionMouseBaselineSpeed)
    }
}
