//
//  AppSettingsTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Combine
import ComposableArchitecture
import ConcurrencyExtras
import XCTest
@testable import GameMode

@MainActor
final class AppSettingsTests: XCTestCase {
    private func store(state: AppSettings.State = .init(), client: SettingsClient = .testValue) -> TestStoreOf<AppSettings> {
        TestStore(initialState: state) { AppSettings() } withDependencies: { $0.settingsClient = client }
    }

    private func preferences() -> (UserDefaults, SettingsClient) {
        let suite = "GameMode.AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (defaults, .preferences(defaults, detectShortcuts: { [] }))
    }

    private enum Failure: LocalizedError {
        case save
        var errorDescription: String? { "The configuration could not be saved." }
    }

    func testSuccessiveBindingsSaveTheWholeLatestConfiguration() async throws {
        let (_, client) = preferences()
        let store = store(client: client)
        await store.send(.binding(.set(\.config.receivesBetaUpdates, true))) {
            $0.config.receivesBetaUpdates = true
            $0.hasSavedConfiguration = true
        }
        await store.send(.binding(.set(\.config.mouse.gamingSpeed, 1.25))) {
            $0.config.mouse.gamingSpeed = 1.25
        }
        await store.send(.binding(.set(\.config.system.restoreOnLaunch, false))) {
            $0.config.system.restoreOnLaunch = false
        }
        XCTAssertEqual(client.load().config, store.state.config)
        XCTAssertTrue(client.load().hasSavedConfiguration)
    }

    func testFailedSaveKeepsLastSavedConfigurationAndAllowsRetry() async {
        let shouldFail = LockIsolated(true)
        let writes = LockIsolated<[GameModeConfig]>([])
        var client = SettingsClient.testValue
        client.save = { config in
            if shouldFail.value { throw Failure.save }
            writes.withValue { $0.append(config) }
        }
        let store = store(client: client)
        await store.send(.binding(.set(\.config.isInputGuardEnabled, true))) {
            $0.persistenceError = Failure.save.localizedDescription
        }
        XCTAssertTrue(writes.value.isEmpty)
        XCTAssertEqual(store.state.config.inputGuardPolicy, .disabled)
        shouldFail.setValue(false)
        await store.send(.binding(.set(\.config.isInputGuardEnabled, true))) {
            $0.config.isInputGuardEnabled = true
            $0.hasSavedConfiguration = true
            $0.persistenceError = nil
        }
        XCTAssertEqual(writes.value, [store.state.config])
    }

    func testTransitionRecoveryAndCorruptionBlockAllEditEntryPoints() async {
        let lockedStates = [
            AppSettings.State(runtime: .init(isTransitioning: true)),
            AppSettings.State(runtime: .init(recoveryRequired: true, recoveryMessage: "Restore failed")),
            AppSettings.State(configurationLoadError: "Unreadable configuration", hasSavedConfiguration: true)
        ]
        var edited = GameModeConfig.defaults
        edited.functionKeysInGamingMode = true
        let app = MonitoredApp(id: UUID(), bundleID: "test.game", name: "Game", isEnabled: true, source: .manual)
        for state in lockedStates {
            // Unimplemented dependencies also assert that no write was attempted.
            let store = store(state: state)
            await store.send(.binding(.set(\.config.functionKeysInGamingMode, true)))
            await store.send(.configurationEdited(edited))
            await store.send(.addApp(app))
            await store.send(.toggleShortcut(state.config.shortcuts[0].id))
            await store.send(.toggleGesture(state.config.gestures[0].id))
            await store.send(.toggleHotkey(state.config.hotkeys[0].id))
            await store.send(.managedDisplayChanged(id: "display", name: "Display", isEnabled: false))
            await store.send(.save)
        }
    }

    func testActiveSessionCanChangeInputGuardWithoutLosingSelections() async {
        let (_, client) = preferences()
        let state = AppSettings.State(runtime: .init(isGamingMode: true))
        let store = store(state: state, client: client)
        await store.send(.toggleShortcut(state.config.shortcuts[0].id)) {
            $0.config.shortcuts[0].disableInGamingMode = true
            $0.hasSavedConfiguration = true
        }
        XCTAssertEqual(store.state.config.inputGuardPolicy, .disabled)
        await store.send(.binding(.set(\.config.isInputGuardEnabled, true))) {
            $0.config.isInputGuardEnabled = true
        }
        XCTAssertEqual(store.state.config.inputGuardPolicy.shortcutIDs, [state.config.shortcuts[0].id])
        await store.send(.binding(.set(\.config.isInputGuardEnabled, false))) {
            $0.config.isInputGuardEnabled = false
        }
        XCTAssertTrue(store.state.config.shortcuts[0].disableInGamingMode)
        XCTAssertTrue(store.state.runtime.isGamingMode)
    }

    func testShortcutDiscoveryPreservesActivePolicyWhileRecoveryIsLocked() async {
        let (_, savedClient) = preferences()
        var state = AppSettings.State(runtime: .init(isGamingMode: true, recoveryRequired: true))
        state.config.isInputGuardEnabled = true
        state.config.shortcuts[0].disableInGamingMode = true
        let original = state.config.shortcuts[0]
        let detected = ShortcutEntry(id: 999, name: "Discovered", category: "Test", disableInGamingMode: true)
        var client = savedClient
        client.detectShortcuts = {
            [ShortcutEntry(id: original.id, name: "New name", category: "Test", disableInGamingMode: false), detected, detected]
        }
        let store = store(state: state, client: client)
        await store.send(.refreshShortcuts) {
            $0.config.shortcuts.append(ShortcutEntry(id: 999, name: "Discovered", category: "Test", disableInGamingMode: false))
            $0.hasSavedConfiguration = true
        }
        await store.send(.refreshShortcuts)
        XCTAssertEqual(store.state.config.inputGuardPolicy, state.config.inputGuardPolicy)
        XCTAssertEqual(savedClient.load().config, store.state.config)
        XCTAssertTrue(store.state.runtime.recoveryRequired)
    }

    func testCorruptConfigurationBlocksDiscoveryAndPreservesOriginalBytes() async {
        let (defaults, client) = preferences()
        let original = Data("not JSON".utf8)
        defaults.set(original, forKey: "GameModeConfig_v2")
        let initial = client.load()
        XCTAssertNotNil(initial.configurationLoadError)
        var dependencies = SettingsClient.testValue
        dependencies.reset = client.reset
        let store = store(state: initial, client: dependencies)
        await store.send(.refreshShortcuts)
        await store.send(.mergeShortcuts([.init(id: 999, name: "New", category: "Test", disableInGamingMode: true)]))
        XCTAssertEqual(defaults.data(forKey: "GameModeConfig_v2"), original)
        await store.send(.resetAfterRecovery) {
            $0.configurationLoadError = nil
        }
        let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("GameModeConfig_v2_unreadable_") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(backups.values.first as? Data, original)
        XCTAssertEqual(client.load().config, .defaults)
    }

    func testResetAlsoArchivesUnreadableNonDataPreferences() async {
        let (defaults, client) = preferences()
        defaults.set("legacy unreadable value", forKey: "GameModeConfig_v2")
        let store = store(state: client.load(), client: client)
        await store.send(.resetAfterRecovery) { $0.configurationLoadError = nil }
        let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("GameModeConfig_v2_unreadable_") }
        XCTAssertEqual(backups.values.first as? String, "legacy unreadable value")
        XCTAssertEqual(client.load().config, .defaults)
    }

    func testResetFailurePreservesConfigurationAndRecoveryGate() async {
        var state = AppSettings.State(configurationLoadError: "Unreadable", hasSavedConfiguration: true,
                                      runtime: .init(isGamingMode: true, isMouseBoostApplied: true, sessionMouseBaselineSpeed: 0.3, isTransitioning: true))
        state.config.mouse.gamingSpeed = 1.25
        var client = SettingsClient.testValue
        client.reset = { _, preserveUnreadable in
            XCTAssertTrue(preserveUnreadable)
            throw Failure.save
        }
        let store = store(state: state, client: client)
        await store.send(.resetAfterRecovery) { $0.persistenceError = Failure.save.localizedDescription }
        XCTAssertFalse(store.state.canEdit)
    }

    func testResetClearsPreferencesButOnlySessionCanUnlockRecovery() async {
        let (_, client) = preferences()
        var state = AppSettings.State(hasSavedConfiguration: true,
                                      runtime: .init(isGamingMode: true, isMouseBoostApplied: true, sessionMouseBaselineSpeed: 0.3, isTransitioning: true))
        state.config.isInputGuardEnabled = true
        let store = store(state: state, client: client)
        await store.send(.resetAfterRecovery) {
            $0.config = .defaults
            $0.runtime.isGamingMode = false
            $0.runtime.isMouseBoostApplied = false
            $0.runtime.sessionMouseBaselineSpeed = nil
        }
        await store.send(.binding(.set(\.config.isInputGuardEnabled, true)))
        await store.send(.runtimeUpdated(.init())) { $0.runtime = .init() }
        XCTAssertTrue(store.state.canEdit)
        XCTAssertEqual(client.load().config, .defaults)
    }

    func testDuplicateAndMissingEntriesDoNotWritePreferences() async {
        let store = store()
        let config = store.state.config
        await store.send(.binding(.set(\.config.receivesBetaUpdates, false)))
        await store.send(.configurationEdited(config))
        await store.send(.addApp(config.monitoredApps[0]))
        await store.send(.removeApp(UUID()))
        await store.send(.toggleApp(UUID()))
        await store.send(.toggleAppRefreshRateLock(UUID()))
        await store.send(.toggleShortcut(-1))
        await store.send(.toggleGesture("missing"))
        await store.send(.toggleHotkey("missing"))
        await store.send(.updateHotkey(id: "missing", keyCode: 1, modifiers: 0))
        await store.send(.mergeShortcuts(config.shortcuts))
    }

    func testCompatibilityAdapterPublishesOnlySavedConfigurationChanges() throws {
        let (defaults, client) = preferences()
        let subject = SettingsTestDriver(defaults: defaults, isPreview: true, settingsClient: client)
        var observed: [GameModeConfig] = []
        let subscription = subject.configPublisher.dropFirst().sink { config in
            // The live engine sees the same value a relaunched app would load.
            XCTAssertEqual(client.load().config, config)
            observed.append(config)
        }
        defer { subscription.cancel() }
        subject.settingsStore.send(.binding(.set(\.config.isInputGuardEnabled, true)))
        subject.config.functionKeysInGamingMode = true
        let saved = subject.config
        subject.updateSession(.init(phase: .transitioning(.init(id: 1, isEnabled: true)), desiredMode: true))
        XCTAssertTrue(subject.isTransitioning)
        subject.config.receivesBetaUpdates = true
        subject.updateSession(.init(phase: .ready, desiredMode: true, appliedMode: true))
        XCTAssertTrue(subject.isGamingMode)
        XCTAssertFalse(subject.isTransitioning)
        XCTAssertEqual(observed.count, 2)
        XCTAssertEqual(subject.config, saved)
        XCTAssertEqual(subject.settingsStore.config, saved)
    }

    func testRealEncodingFailureNeverReachesCompatibilityObservers() {
        let (defaults, client) = preferences()
        let subject = SettingsTestDriver(defaults: defaults, isPreview: true, settingsClient: client)
        subject.config.receivesBetaUpdates = true
        let saved = subject.config
        var notifications = 0
        let subscription = subject.configPublisher.dropFirst().sink { _ in notifications += 1 }
        defer { subscription.cancel() }
        subject.settingsStore.send(.binding(.set(\.config.mouse.gamingSpeed, .infinity)))
        XCTAssertNotNil(subject.settings.persistenceError)
        XCTAssertEqual(subject.config, saved)
        XCTAssertEqual(client.load().config, saved)
        XCTAssertEqual(notifications, 0)
    }

    func testPreferenceEditsCannotRewritePendingRecoveryOriginals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = StateJournal(directory: directory)
        var changes = AppliedChanges.empty
        changes.functionKeysChanged = true
        changes.previousFunctionKeysEnabled = false
        let pending = GameModeState(isActive: true, activatedAt: Date(), appliedChanges: changes)
        try journal.begin(pending)
        let baseline = try journal.load()
        let (_, client) = preferences()
        let store = store(state: .init(runtime: .init(isGamingMode: true)), client: client)
        await store.send(.binding(.set(\.config.functionKeysInGamingMode, true))) {
            $0.config.functionKeysInGamingMode = true
            $0.hasSavedConfiguration = true
        }
        await store.send(.runtimeUpdated(.init(recoveryRequired: true))) {
            $0.runtime = .init(recoveryRequired: true)
        }
        await store.send(.binding(.set(\.config.functionKeysInGamingMode, false)))
        XCTAssertEqual(try journal.load(), baseline)
        XCTAssertEqual(journal.inspect(), .pending(baseline))
    }

    func testRecoveryAndSettingsStoresStayLockedUntilRestoreAndResetSucceed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = StateJournal(directory: directory)
        var changes = AppliedChanges.empty
        changes.functionKeysChanged = true
        changes.previousFunctionKeysEnabled = false
        try journal.begin(GameModeState(isActive: true, activatedAt: Date(), appliedChanges: changes))
        var failRestore = true
        var keyboardEnabled = true
        let recovery = RecoveryController(journal: journal, operations: .init(
            stopDisplays: { [] }, restoreDisplays: { _ in [] }, restoreKeyboard: { changes in
                if failRestore { return ["Keyboard restoration failed"] }
                keyboardEnabled = changes.previousFunctionKeysEnabled!
                return []
            }, restorePower: { _ in [] }, readMouse: { 0.3 }, applyMouse: { _ in true }
        ))
        let (defaults, client) = preferences()
        let corrupt = Data("preserve these preferences".utf8)
        defaults.set(corrupt, forKey: "GameModeConfig_v2")
        let settings = SettingsTestDriver(defaults: defaults, isPreview: true, settingsClient: client)
        let session = Store(initialState: GameSession.State(configurationIsValid: false)) { GameSession() }
        var subscriptions = Set<AnyCancellable>()
        // Exercise the same one-way projections used by the AppKit coordinator.
        session.publisher.removeDuplicates().sink { settings.updateSession($0) }.store(in: &subscriptions)
        settings.configurationLoadErrorPublisher.map { $0 == nil }.removeDuplicates()
            .sink { session.send(.configurationValidityChanged($0)) }.store(in: &subscriptions)
        defer { subscriptions.removeAll() }

        do {
            try recovery.reset()
            settings.resetAllSavedData()
            XCTFail("The failed restoration must prevent resetting preferences")
        } catch {
            session.send(.recoveryFailed(error.localizedDescription))
        }
        XCTAssertTrue(settings.recoveryRequired)
        XCTAssertFalse(settings.canChangeMode)
        XCTAssertFalse(session.configurationIsValid)
        XCTAssertEqual(defaults.data(forKey: "GameModeConfig_v2"), corrupt)
        XCTAssertEqual(try journal.load().appliedChanges.previousFunctionKeysEnabled, false)
        session.send(.modeRequested(true, source: .automatic))
        XCTAssertFalse(session.desiredMode)

        failRestore = false
        session.send(.recoveryStarted)
        try recovery.reset()
        settings.resetAllSavedData()
        XCTAssertFalse(keyboardEnabled)
        XCTAssertEqual(journal.inspect(), .clean)
        XCTAssertTrue(session.configurationIsValid)
        XCTAssertTrue(settings.isTransitioning)
        XCTAssertFalse(settings.canChangeMode)
        session.send(.modeRequested(true, source: .menu))
        XCTAssertFalse(session.desiredMode)
        session.send(.recoverySucceeded)
        XCTAssertTrue(settings.canChangeMode)
        XCTAssertFalse(settings.recoveryRequired)
        XCTAssertEqual(client.load().config, .defaults)
    }
}
