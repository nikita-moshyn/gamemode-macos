//
//  SettingsNavigationTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import ConcurrencyExtras
import XCTest
@testable import GameMode

@MainActor
final class SettingsNavigationTests: XCTestCase {
    private let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

    private func store(state: AppSettings.State = .init(), client: SettingsClient = .testValue, viewClient: SettingsViewClient = .testValue) -> TestStoreOf<AppSettings> {
        TestStore(initialState: state) { AppSettings() } withDependencies: {
            $0.settingsClient = client
            $0.settingsViewClient = viewClient
            $0.uuid = .constant(operationID)
        }
    }

    private enum Failure: LocalizedError {
        case save
        var errorDescription: String? { "Could not save preferences" }
    }

    func testSidebarSelectionDefersDiscoveryAndRetainsTheLastDestination() async {
        let sections = LockIsolated<[SettingsSection]>([])
        let saved = LockIsolated<[GameModeConfig]>([])
        let discovered = ShortcutEntry(id: 999, name: "New shortcut", category: "Test", disableInGamingMode: true)
        var client = SettingsClient.testValue
        client.saveSelectedSection = { section in sections.withValue { $0.append(section) } }
        client.detectShortcuts = { [discovered] }
        client.save = { config in saved.withValue { $0.append(config) } }
        let store = store(client: client)
        await store.send(.sectionSelected(.shortcuts)) { $0.selectedSection = .shortcuts }
        await store.receive(\.refreshShortcuts) {
            $0.config.shortcuts.append(.init(id: 999, name: "New shortcut", category: "Test", disableInGamingMode: false))
            $0.hasSavedConfiguration = true
        }
        await store.send(.sectionSelected(.shortcuts))
        await store.send(.sectionSelected(nil))
        #if FEATURE_DISPLAYS
        await store.send(.sectionSelected(.display)) { $0.selectedSection = .display }
        #else
        await store.send(.sectionSelected(.display))
        #endif
        await store.send(.sectionSelected(.system)) { $0.selectedSection = .system }
        #if FEATURE_DISPLAYS
        XCTAssertEqual(sections.value, [.shortcuts, .display, .system])
        #else
        XCTAssertEqual(sections.value, [.shortcuts, .system])
        #endif
        XCTAssertEqual(saved.value.count, 1)
    }

    func testSavedDisplayDestinationRespectsBuildAvailabilityWithoutErasingPreferences() throws {
        let defaults = UserDefaults(suiteName: "GameMode.DisplayAvailability.\(UUID().uuidString)")!
        defer { defaults.removeObject(forKey: "GameModeSettingsSection"); defaults.removeObject(forKey: "GameModeConfig_v2") }
        var config = GameModeConfig.defaults
        config.display.isRefreshRateLockEnabled = true
        config.display.autoDisableLowPowerMode = true
        let data = try JSONEncoder().encode(config)
        defaults.set(data, forKey: "GameModeConfig_v2")
        defaults.set("display", forKey: "GameModeSettingsSection")
        let loaded = SettingsClient.preferences(defaults, detectShortcuts: { [] }).load()
        #if FEATURE_DISPLAYS
        XCTAssertTrue(SettingsSection.availableCases.contains(.display))
        XCTAssertEqual(loaded.selectedSection, .display)
        #else
        XCTAssertFalse(SettingsSection.availableCases.contains(.display))
        XCTAssertEqual(loaded.selectedSection, .general)
        #endif
        XCTAssertEqual(loaded.config, config)
        XCTAssertEqual(defaults.data(forKey: "GameModeConfig_v2"), data)
    }

    func testSidebarDiscoveryCannotPublishBeforeTheSelectionCallbackReturns() async {
        let saved = LockIsolated(false)
        var client = SettingsClient.testValue
        client.saveSelectedSection = { _ in }
        client.detectShortcuts = { [.init(id: 999, name: "New", category: "Test", disableInGamingMode: true)] }
        client.save = { _ in saved.setValue(true) }
        let store = Store(initialState: AppSettings.State()) { AppSettings() } withDependencies: { $0.settingsClient = client }
        // Unlike TestStore.send, this call does not suspend/yield the UI callback.
        let effect = store.send(.sectionSelected(.shortcuts))
        XCTAssertFalse(saved.value)
        await effect.finish()
        XCTAssertTrue(saved.value)
    }

    func testRememberedLegacyAndInvalidSectionsNeverRewriteSavedConfiguration() async throws {
        for (identifier, expected) in [("logs", SettingsSection.system), ("unknown", .general)] {
            let suite = "GameMode.Navigation.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(identifier, forKey: "GameModeSettingsSection")
            let unreadable = Data("preserved configuration".utf8)
            defaults.set(unreadable, forKey: "GameModeConfig_v2")
            let client = SettingsClient.preferences(defaults, detectShortcuts: { [] })
            let store = store(state: client.load(), client: client)
            XCTAssertEqual(store.state.selectedSection, expected)
            await store.send(.settingsOpened)
            XCTAssertEqual(defaults.string(forKey: "GameModeSettingsSection"), expected.rawValue)
            XCTAssertEqual(defaults.data(forKey: "GameModeConfig_v2"), unreadable)
            XCTAssertFalse(store.state.canEdit)
        }
    }

    func testRecoveryLinkOverridesRememberedSelectionBeforeWindowOpens() async {
        let sections = LockIsolated<[SettingsSection]>([])
        var client = SettingsClient.testValue
        client.saveSelectedSection = { section in sections.withValue { $0.append(section) } }
        let store = store(state: .init(runtime: .init(recoveryRequired: true), selectedSection: .mouse), client: client)
        await store.send(.sectionSelected(.system)) { $0.selectedSection = .system }
        await store.send(.settingsOpened)
        XCTAssertEqual(sections.value, [.system, .system])
        XCTAssertFalse(store.state.canEdit)
        await store.send(.addAppButtonTapped)
        await store.send(.scanButtonTapped)
    }

    func testManualPickerAddsValidatedApplicationAndPreservesPrefixMatching() async {
        var client = SettingsClient.testValue
        client.save = { _ in }
        let store = store(client: client)
        let existing = Set(store.state.config.monitoredApps.map(\.bundleID))
        await store.send(.addAppButtonTapped) { $0.appPicker = .init(existingIDs: existing) }
        await store.send(.appPicker(.presented(.binding(.set(\.manualBundleID, " com.example.games.* "))))) {
            $0.appPicker?.manualBundleID = " com.example.games.* "
        }
        await store.send(.appPicker(.presented(.manualAddButtonTapped)))
        let added = MonitoredApp(id: operationID, bundleID: "com.example.games.*", name: "com.example.games.*", isEnabled: true, source: .manual)
        await store.receive(\.appPicker.presented.delegate) {
            $0.config.monitoredApps.append(added)
            $0.hasSavedConfiguration = true
            $0.appPicker?.existingIDs.insert(added.bundleID)
            $0.appPicker?.manualBundleID = ""
            $0.appPicker?.feedback = "Added com.example.games.*."
        }
        XCTAssertTrue(added.matches(bundleID: "com.example.games.first"))
        await store.send(.appPicker(.presented(.doneButtonTapped)))
        await store.receive(\.appPicker.dismiss) { $0.appPicker = nil }
    }

    func testPickerDoesNotClaimSuccessOrClearInputWhenSavingFails() async {
        var client = SettingsClient.testValue
        client.save = { _ in throw Failure.save }
        let picker = ApplicationPicker.State(manualBundleID: "com.example.game")
        let store = store(state: .init(appPicker: picker), client: client)
        await store.send(.appPicker(.presented(.manualAddButtonTapped)))
        await store.receive(\.appPicker.presented.delegate) {
            $0.persistenceError = Failure.save.localizedDescription
            $0.appPicker?.feedback = Failure.save.localizedDescription
        }
        XCTAssertEqual(store.state.appPicker?.manualBundleID, "com.example.game")
        XCTAssertEqual(store.state.config, .defaults)
    }

    func testDuplicatePickerRequestDoesNotWritePreferences() async {
        let existing = MonitoredApp.presets[0]
        let store = store(state: .init(appPicker: .init()))
        await store.send(.appPicker(.presented(.addButtonTapped(.init(bundleID: existing.bundleID, name: existing.name)))))
        await store.receive(\.appPicker.presented.delegate) {
            $0.appPicker?.feedback = "\(existing.name) has already been added."
        }
    }

    func testNavigationDismissesPickerAndRecoveryDismissesStaleConfirmation() async {
        var client = SettingsClient.testValue
        client.saveSelectedSection = { _ in }
        let store = store(state: .init(selectedSection: .applications, appPicker: .init(manualBundleID: "unfinished")), client: client)
        await store.send(.sectionSelected(.system)) {
            $0.selectedSection = .system
            $0.appPicker = nil
        }
        await store.send(.confirmationRequested(.resetConfiguration)) { $0.confirmation = .resetConfiguration }
        await store.send(.runtimeUpdated(.init(isTransitioning: true))) {
            $0.runtime.isTransitioning = true
            $0.confirmation = nil
        }
        await store.send(.confirmationRequested(.resetConfiguration))
        await store.send(.confirmationRequested(.acceptCurrentSettings))
        await store.send(.runtimeUpdated(.init(recoveryRequired: true))) {
            $0.runtime = .init(recoveryRequired: true)
        }
        await store.send(.confirmationRequested(.acceptCurrentSettings)) { $0.confirmation = .acceptCurrentSettings }
        await store.send(.confirmationDismissed(.resetConfiguration))
        await store.send(.runtimeUpdated(.init())) {
            $0.runtime = .init()
            $0.confirmation = nil
        }
    }

    func testRecoveryCancelsBrowseWithoutAddingItsLateResult() async {
        let gate = AsyncStream<ApplicationCandidate>.makeStream()
        var viewClient = SettingsViewClient.testValue
        viewClient.browseApplication = {
            for await app in gate.stream { return app }
            return nil
        }
        let store = store(state: .init(appPicker: .init()), viewClient: viewClient)
        await store.send(.appPicker(.presented(.browseButtonTapped))) { $0.appPicker?.isBrowsing = true }
        await store.send(.runtimeUpdated(.init(recoveryRequired: true))) {
            $0.runtime.recoveryRequired = true
            $0.appPicker = nil
        }
        gate.continuation.yield(.init(bundleID: "late.game", name: "Late game"))
        gate.continuation.finish()
        await store.finish()
        XCTAssertEqual(store.state.config, .defaults)
    }

    func testScanMergesIntoLatestPreferencesInOneSave() async {
        let gate = AsyncStream<[MonitoredApp]>.makeStream()
        let saved = LockIsolated<[GameModeConfig]>([])
        var client = SettingsClient.testValue
        client.save = { config in saved.withValue { $0.append(config) } }
        var viewClient = SettingsViewClient.testValue
        viewClient.scanGames = {
            for await apps in gate.stream { return apps }
            return []
        }
        let store = store(client: client, viewClient: viewClient)
        await store.send(.scanButtonTapped) { $0.scanID = self.operationID }
        await store.send(.scanButtonTapped)
        await store.send(.binding(.set(\.config.receivesBetaUpdates, true))) {
            $0.config.receivesBetaUpdates = true
            $0.hasSavedConfiguration = true
        }
        let app = MonitoredApp(id: UUID(), bundleID: "test.scanned.game", name: "Scanned Game", isEnabled: true, source: .detected)
        gate.continuation.yield([app, app, MonitoredApp.presets[0]])
        gate.continuation.finish()
        await store.receive(\.scanFinished) {
            $0.scanID = nil
            $0.config.monitoredApps.append(app)
            $0.scanSummary = "Scan complete. Added 1 application."
        }
        XCTAssertEqual(saved.value.count, 2)
        XCTAssertTrue(saved.value.last!.receivesBetaUpdates)
        await store.finish()
    }

    func testTransitionCancelsScanAndBlocksStaleResultsAndNewEdits() async {
        let gate = AsyncStream<[MonitoredApp]>.makeStream()
        var viewClient = SettingsViewClient.testValue
        viewClient.scanGames = {
            for await apps in gate.stream { return apps }
            return []
        }
        let store = store(state: .init(appPicker: .init()), viewClient: viewClient)
        await store.send(.scanButtonTapped) { $0.scanID = self.operationID }
        await store.send(.runtimeUpdated(.init(isTransitioning: true))) {
            $0.runtime.isTransitioning = true
            $0.appPicker = nil
            $0.scanID = nil
            $0.scanSummary = "Scan stopped. Finish recovery or the current transition before adding applications."
        }
        gate.continuation.finish()
        await store.finish()
        let app = MonitoredApp(id: UUID(), bundleID: "late.game", name: "Late", isEnabled: true, source: .detected)
        await store.send(.scanFinished(operationID, [app]))
        await store.send(.appEnabledChanged(MonitoredApp.presets[0].id, false))
        await store.send(.appRefreshRateLockChanged(MonitoredApp.presets[0].id, false))
        await store.send(.hotkeyEnabledChanged(AppHotkey.defaults[0].id, false))
        await store.send(.scanButtonTapped)
        await store.send(.addAppButtonTapped)
    }

    func testReadOnlyStatusRefreshesNeverSavePreferences() async {
        var viewClient = SettingsViewClient.testValue
        let status = SettingsDisplayStatus(lowPowerModeEnabled: true, batteryLevel: 25)
        viewClient.displayStatus = { status }
        viewClient.loginStatus = { .requiresApproval }
        let store = store(viewClient: viewClient)
        await store.send(.displayStatusRequested)
        await store.receive(\.displayStatusLoaded) { $0.displayStatus = status }
        await store.send(.loginStatusRequested)
        await store.receive(\.loginStatusLoaded) { $0.loginStatus = .requiresApproval }
        XCTAssertFalse(store.state.hasSavedConfiguration)
    }

    func testLoginItemFailuresAreVisibleAndRecoveryBlocksRegistration() async {
        var viewClient = SettingsViewClient.testValue
        viewClient.setLaunchAtLogin = { _ in throw Failure.save }
        viewClient.loginStatus = { .requiresApproval }
        let store = store(viewClient: viewClient)
        await store.send(.launchAtLoginChanged(true)) { $0.isUpdatingLoginItem = true }
        await store.receive(\.loginItemUpdateFinished) {
            $0.isUpdatingLoginItem = false
            $0.loginError = Failure.save.localizedDescription
        }
        await store.receive(\.loginStatusLoaded) { $0.loginStatus = .requiresApproval }
        await store.send(.runtimeUpdated(.init(recoveryRequired: true))) { $0.runtime.recoveryRequired = true }
        await store.send(.launchAtLoginChanged(true))
    }
}
