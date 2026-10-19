//
//  ConfigStoreTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ConcurrencyExtras
import XCTest
@testable import GameMode

final class SettingsPersistenceTests: XCTestCase {

    private var suiteName: String!
    private var testDefaults: UserDefaults!
    private var store: SettingsTestDriver!

    override func setUp() {
        super.setUp()
        suiteName = "com.moshyn.nikita.GameModeTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
        store = SettingsTestDriver(defaults: testDefaults)
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
        XCTAssertFalse(store.config.functionKeysInGamingMode)
        XCTAssertFalse(store.config.isInputGuardEnabled)
        XCTAssertTrue(store.config.shortcuts.allSatisfy { !$0.disableInGamingMode })
        XCTAssertTrue(store.config.gestures.allSatisfy { !$0.disableInGamingMode })
    }

    func test_isFirstLaunch_trueWhenNoData() {
        XCTAssertTrue(store.isFirstLaunch)
    }

    func test_isFirstLaunch_falseAfterSave() {
        store.save()
        XCTAssertFalse(store.isFirstLaunch)
    }

    func test_saveAndLoad_roundTrip() {
        store.config.functionKeysInGamingMode = true
        // The compatibility setter sends an action and persists synchronously.

        let store2 = SettingsTestDriver(defaults: testDefaults)
        XCTAssertTrue(store2.config.functionKeysInGamingMode)
    }

    func test_betaOptInPersistsAndOptOutSurvivesRelaunch() {
        XCTAssertFalse(store.config.receivesBetaUpdates)
        store.config.receivesBetaUpdates = true
        let optedIn = SettingsTestDriver(defaults: testDefaults)
        XCTAssertEqual(optedIn.config.allowedUpdateChannels, ["beta", "rc"])
        optedIn.config.receivesBetaUpdates = false
        XCTAssertTrue(SettingsTestDriver(defaults: testDefaults).config.allowedUpdateChannels.isEmpty)
    }

    func test_corruptConfigurationIsPreservedUntilExplicitReset() {
        let corrupt = Data("not-json".utf8)
        testDefaults.set(corrupt, forKey: "GameModeConfig_v2")
        let damaged = SettingsTestDriver(defaults: testDefaults)
        XCTAssertNotNil(damaged.configurationLoadError)
        XCTAssertFalse(damaged.isFirstLaunch)
        damaged.config.functionKeysInGamingMode = true
        XCTAssertEqual(testDefaults.data(forKey: "GameModeConfig_v2"), corrupt)
        damaged.resetAllSavedData()
        XCTAssertNil(damaged.configurationLoadError)
        XCTAssertNotEqual(testDefaults.data(forKey: "GameModeConfig_v2"), corrupt)
        XCTAssertTrue(testDefaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("GameModeConfig_v2_unreadable_") })
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

    func test_refreshDetectedShortcutsPreservesSelectionsAndAddsUniqueEntriesOff() {
        let firstID = ShortcutEntry.defaults[0].id
        let secondID = ShortcutEntry.defaults[1].id
        let newEntry = ShortcutEntry(id: 999, name: "New Shortcut", category: "Test", disableInGamingMode: true)
        let detected = LockIsolated([
            ShortcutEntry(id: firstID, name: "Changed name", category: "Test", disableInGamingMode: false),
            ShortcutEntry(id: secondID, name: "Other shortcut", category: "Test", disableInGamingMode: true),
            newEntry, newEntry
        ])
        let subject = SettingsTestDriver(defaults: testDefaults, isPreview: true, shortcutDetector: { detected.value })
        subject.config.isInputGuardEnabled = true
        subject.config.functionKeysInGamingMode = true
        subject.config.shortcuts[0].disableInGamingMode = true
        subject.isGamingMode = true
        let selections = subject.config.shortcuts
        let activePolicy = subject.config.inputGuardPolicy

        subject.refreshDetectedShortcuts()
        XCTAssertEqual(Array(subject.config.shortcuts.prefix(selections.count)), selections)
        XCTAssertEqual(subject.config.shortcuts.filter { $0.id == newEntry.id }.count, 1)
        XCTAssertEqual(subject.config.shortcuts.first { $0.id == newEntry.id }?.disableInGamingMode, false)
        XCTAssertEqual(subject.config.inputGuardPolicy, activePolicy)
        XCTAssertTrue(subject.isGamingMode)

        subject.toggleShortcut(id: newEntry.id)
        let savedSelection = subject.config.shortcuts.first { $0.id == newEntry.id }
        detected.setValue([]) // A temporarily unavailable shortcut must not erase a choice.
        subject.refreshDetectedShortcuts()
        detected.setValue([newEntry])
        subject.refreshDetectedShortcuts()
        XCTAssertEqual(subject.config.shortcuts.first { $0.id == newEntry.id }, savedSelection)
        XCTAssertEqual(subject.config.shortcuts.count, selections.count + 1)
        XCTAssertEqual(SettingsTestDriver(defaults: testDefaults).config.shortcuts, subject.config.shortcuts)
    }

    func test_automaticShortcutRefreshDoesNotChangeCorruptConfiguration() {
        let corrupt = Data("not-json".utf8)
        testDefaults.set(corrupt, forKey: "GameModeConfig_v2")
        let detections = LockIsolated(0)
        let subject = SettingsTestDriver(defaults: testDefaults, isPreview: true, shortcutDetector: {
            detections.withValue { $0 += 1 }
            return [ShortcutEntry(id: 999, name: "New", category: "Test", disableInGamingMode: false)]
        })
        subject.refreshDetectedShortcuts()
        XCTAssertEqual(detections.value, 0)
        XCTAssertEqual(testDefaults.data(forKey: "GameModeConfig_v2"), corrupt)
    }

    func test_previewDoesNotAutomaticallyReadRealSystemShortcuts() {
        let subject = SettingsTestDriver(defaults: testDefaults, isPreview: true)
        subject.refreshDetectedShortcuts()
        XCTAssertEqual(subject.config.shortcuts, ShortcutEntry.defaults)
        XCTAssertTrue(subject.isFirstLaunch, "An unchanged discovery must not save configuration")
    }

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
        // Preserve a user's explicit choice when detection finds the same shortcut.
        store.config.shortcuts[0].disableInGamingMode = true
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

    func test_inputGuardMasterAndSelectionsPersistIndependently() {
        store.config.isInputGuardEnabled = true
        store.config.functionKeysInGamingMode = true
        store.config.shortcuts[0].disableInGamingMode = true
        store.config.gestures[0].disableInGamingMode = true
        let selected = store.config.inputGuardPolicy
        store.config.isInputGuardEnabled = false

        let reloaded = SettingsTestDriver(defaults: testDefaults)
        XCTAssertEqual(reloaded.config.inputGuardPolicy, .disabled)
        reloaded.config.isInputGuardEnabled = true
        XCTAssertEqual(reloaded.config.inputGuardPolicy, selected)
    }

    func test_resetAllSavedData() {
        // Mutate config
        store.config.receivesBetaUpdates = true
        store.config.isInputGuardEnabled = true
        store.config.functionKeysInGamingMode = true
        store.config.shortcuts[0].disableInGamingMode = true
        store.config.gestures[0].disableInGamingMode = true
        store.isGamingMode = true
        store.isMouseBoostApplied = true
        store.sessionMouseBaselineSpeed = 0.5

        store.resetAllSavedData()

        XCTAssertFalse(store.config.receivesBetaUpdates)
        XCTAssertFalse(store.config.functionKeysInGamingMode)
        XCTAssertFalse(store.config.isInputGuardEnabled)
        XCTAssertTrue(store.config.shortcuts.allSatisfy { !$0.disableInGamingMode })
        XCTAssertTrue(store.config.gestures.allSatisfy { !$0.disableInGamingMode })
        XCTAssertFalse(store.isGamingMode)
        XCTAssertFalse(store.isMouseBoostApplied)
        XCTAssertNil(store.sessionMouseBaselineSpeed)
    }
}
