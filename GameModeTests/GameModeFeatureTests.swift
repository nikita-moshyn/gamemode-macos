//
//  GameModeFeatureTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 13/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import XCTest
@testable import GameMode

@MainActor
final class GameModeFeatureTests: XCTestCase {
    private func game(_ id: String = "test.game", lock: Bool = false) -> MonitoredApp {
        MonitoredApp(id: UUID(), bundleID: id, name: id, isEnabled: true, source: .manual, lockRefreshRate: lock)
    }

    func testOverlappingRulesCountEachProcessOnceAndHonorEveryRefreshRequest() async {
        let wildcard = game("test.*")
        let exact = game(lock: true)
        for entries in [[wildcard, exact], [exact, wildcard]] {
            let harness = Harness(apps: entries)
            let store = harness.store()
            await store.send(.runningAppsLoaded(["test.game"], activate: false)).finish()
            XCTAssertEqual(store.state.activeGameCount, 1)
            XCTAssertTrue(store.state.needsDisplay)
            await store.send(.settings(.appEnabledChanged(exact.id, false))).finish()
            XCTAssertFalse(store.state.needsDisplay)
            await store.send(.settings(.appRefreshRateLockChanged(wildcard.id, true))).finish()
            XCTAssertTrue(store.state.needsDisplay)
            XCTAssertTrue(harness.transitions.isEmpty)
        }
    }

    func testDuplicateProcessesKeepModeAndRefreshUntilFinalExit() async {
        let harness = Harness(apps: [game("test.locked", lock: true), game("test.other")])
        let store = harness.store()
        let events: [(String, Bool, Int, Bool)] = [
            ("test.locked", true, 1, true), ("test.locked", true, 2, true),
            ("test.other", true, 3, true), ("test.locked", false, 2, true),
            ("test.locked", false, 1, false), ("test.other", false, 0, false)
        ]
        for (id, launch, count, display) in events {
            await store.send(.platform(launch ? .launched(id) : .terminated(id))).finish()
            XCTAssertEqual(store.state.activeGameCount, count)
            XCTAssertEqual(store.state.needsDisplay, display)
            XCTAssertEqual(store.session.appliedMode, count > 0)
        }
        XCTAssertEqual(harness.transitions.map(\.isEnabled), [true, false])
    }

    func testInitialDuplicateProcessesAndUnknownExitsAreTrackedWithoutSpuriousActivation() async {
        let harness = Harness(apps: [game(lock: true)])
        let store = harness.store()
        await store.send(.runningAppsLoaded(["test.game", "test.game", "unmonitored"], activate: false)).finish()
        XCTAssertEqual(store.state.activeGameCount, 2)
        await store.send(.platform(.terminated("test.unknown"))).finish()
        await store.send(.platform(.terminated("test.game"))).finish()
        XCTAssertEqual(store.state.activeGameCount, 1)
        XCTAssertTrue(store.state.needsDisplay)
        await store.send(.platform(.terminated("test.game"))).finish()
        await store.send(.platform(.terminated("test.game"))).finish()
        XCTAssertEqual(store.state.activeGameCount, 0)
        XCTAssertFalse(store.state.needsDisplay)
        XCTAssertTrue(harness.transitions.isEmpty)
    }

    func testQualifyingGamesUpdateRefreshPolicyWithoutRestartingMode() async {
        let harness = Harness(apps: [game("test.a"), game("test.b", lock: true), game("test.c", lock: true)])
        let store = harness.store()
        let events: [(String, Bool, Bool)] = [("a", true, false), ("b", true, true), ("c", true, true), ("b", false, true), ("c", false, false), ("a", false, false)]
        for (id, launch, display) in events {
            await store.send(.platform(launch ? .launched("test.\(id)") : .terminated("test.\(id)"))).finish()
            XCTAssertEqual(store.state.needsDisplay, display)
        }
        XCTAssertEqual(harness.transitions.map(\.isEnabled), [true, false])
    }

    func testStartupRestorationCompletesBeforeActivatingAlreadyRunningGame() async {
        let harness = Harness(apps: [game()])
        harness.initial.session.phase = .recovering
        harness.initial.settings.runtime.isTransitioning = true
        harness.running = ["test.game"]
        let store = harness.store()
        await store.send(.launched).finish()
        XCTAssertEqual(harness.operations.map(\.operation), [.startup])
        XCTAssertEqual(harness.transitions.map(\.isEnabled), [true])
        XCTAssertEqual(harness.order, ["startup", "mode-on"])
        XCTAssertTrue(store.session.appliedMode)
        XCTAssertFalse(store.settings.runtime.isTransitioning)
    }

    func testFailedStartupBlocksAutomaticAndManualActivationUntilRetrySucceeds() async {
        let harness = Harness(apps: [game()])
        harness.initial.session.phase = .recovering
        harness.failure = "Original settings are still pending"
        harness.running = ["test.game"]
        let store = harness.store()
        await store.send(.launched).finish()
        XCTAssertEqual(store.session.phase, .needsRecovery(harness.failure!))
        await store.send(.platform(.launched("test.game"))).finish()
        await store.send(.toggleMode(.menu)).finish()
        XCTAssertTrue(harness.transitions.isEmpty)
        harness.failure = nil
        await store.send(.retryRecovery).finish()
        XCTAssertEqual(harness.operations.map(\.operation), [.startup, .recover])
        XCTAssertEqual(harness.transitions.map(\.isEnabled), [true])
        XCTAssertFalse(store.settings.runtime.recoveryRequired)
    }

    func testAcceptCurrentSettingsSeedsGamesWithoutActivatingOrReplayingSetters() async {
        let harness = Harness(apps: [game()])
        harness.initial.session.phase = .needsRecovery("Pending")
        harness.initial.settings.runtime.recoveryRequired = true
        harness.running = ["test.game", "test.game"]
        let store = harness.store()
        await store.send(.acceptCurrentSettings).finish()
        XCTAssertEqual(harness.operations.map(\.operation), [.accept])
        XCTAssertTrue(harness.transitions.isEmpty)
        XCTAssertEqual(store.state.activeGameCount, 2)
        XCTAssertFalse(store.session.appliedMode)
        XCTAssertFalse(store.needsInitialAppScan)
    }

    func testResetWaitsForDurableRecoveryAndDoesNotSaveOnFailure() async {
        let harness = Harness(apps: [game()])
        harness.failure = "Journal could not commit"
        let store = harness.store()
        await store.send(.resetConfiguration).finish()
        XCTAssertEqual(harness.operations.map(\.operation), [.reset])
        XCTAssertEqual(harness.resets, 0)
        XCTAssertEqual(store.settings.config.monitoredApps, harness.initial.settings.config.monitoredApps)
        XCTAssertTrue(store.settings.runtime.recoveryRequired)
    }

    func testSuccessfulResetCommitsPreferencesAfterRecoveryAndDoesNotActivateRunningGames() async {
        let harness = Harness(apps: [game()])
        harness.running = ["test.game"]
        let store = harness.store()
        await store.send(.resetConfiguration).finish()
        XCTAssertEqual(harness.order, ["reset", "preferences-reset"])
        XCTAssertEqual(harness.resets, 1)
        XCTAssertEqual(store.settings.config, .defaults)
        XCTAssertEqual(store.session.phase, .ready)
        XCTAssertFalse(store.settings.runtime.isTransitioning)
        XCTAssertTrue(harness.transitions.isEmpty)
    }

    func testMouseFailureKeepsBaselineAndBlocksFurtherEdits() async {
        let harness = Harness(apps: [game()])
        harness.setActive()
        harness.failure = "Mouse restore failed"
        harness.snapshot = .init(mouseIsApplied: true, mouseBaseline: 1.25)
        let store = harness.store()
        await store.send(.applyMouse).finish()
        XCTAssertEqual(store.session.phase, .needsRecovery("Mouse restore failed"))
        XCTAssertEqual(store.settings.runtime.sessionMouseBaselineSpeed, 1.25)
        XCTAssertTrue(store.settings.runtime.isMouseBoostApplied)
        let config = store.settings.config
        await store.send(.settings(.binding(.set(\.config.mouse.gamingSpeed, 2)))).finish()
        XCTAssertEqual(store.settings.config, config)
        await store.send(.toggleMouse).finish()
        XCTAssertEqual(harness.operations.count, 1)
    }

    func testFunctionKeyCheckboxUpdatesActiveInputGuardWithoutRestartingGameMode() async {
        let harness = Harness(apps: [game()])
        harness.setActive()
        harness.initial.started = true
        harness.initial.settings.config.isInputGuardEnabled = true
        let store = harness.store()
        await store.send(.settings(.binding(.set(\.config.functionKeysInGamingMode, true)))).finish()
        await store.send(.settings(.binding(.set(\.config.functionKeysInGamingMode, false)))).finish()
        XCTAssertEqual(harness.operations.map(\.operation), [.inputGuard, .inputGuard])
        XCTAssertTrue(store.session.appliedMode)
        XCTAssertTrue(harness.transitions.isEmpty)
        XCTAssertFalse(store.settings.runtime.isTransitioning)
    }

    func testFunctionKeySelectionWhileGameModeIsOffOnlySavesConfiguration() async {
        let harness = Harness(apps: [game()])
        harness.initial.started = true
        harness.initial.settings.config.isInputGuardEnabled = true
        let store = harness.store()
        await store.send(.settings(.binding(.set(\.config.functionKeysInGamingMode, true)))).finish()
        XCTAssertTrue(store.settings.config.functionKeysInGamingMode)
        XCTAssertEqual(harness.saves, 1)
        XCTAssertTrue(harness.operations.isEmpty)
        XCTAssertTrue(harness.transitions.isEmpty)
    }

    func testLastGameExitWaitsForMouseOperationThenRestores() async {
        let harness = Harness(apps: [game()])
        harness.setActive()
        harness.initial.processCounts = ["test.game": 1]
        harness.holdOperations = true
        let started = expectation(description: "Mouse operation started")
        harness.onOperation = { _ in started.fulfill() }
        let store = harness.store()
        let task = store.send(.applyMouse)
        await fulfillment(of: [started], timeout: 2)
        await store.send(.platform(.terminated("test.game"))).finish()
        XCTAssertFalse(store.session.desiredMode)
        XCTAssertTrue(store.session.appliedMode)
        XCTAssertTrue(harness.transitions.isEmpty)
        harness.complete()
        await task.finish()
        XCTAssertEqual(harness.transitions.map(\.isEnabled), [false])
        XCTAssertEqual(harness.order, ["mouse(true)", "mode-off"])
        XCTAssertFalse(store.settings.runtime.isTransitioning)
    }

    func testAuxiliaryFailureDiscardsQueuedDisplayChanges() async {
        let harness = Harness(apps: [game(lock: true)])
        harness.setActive()
        harness.holdOperations = true
        let started = expectation(description: "Mouse operation started")
        harness.onOperation = { _ in started.fulfill() }
        let store = harness.store()
        let task = store.send(.applyMouse)
        await fulfillment(of: [started], timeout: 2)
        await store.send(.platform(.launched("test.game"))).finish()
        XCTAssertEqual(store.pendingOperations, [.display])
        harness.failure = "Checkpoint failed"
        harness.complete()
        await task.finish()
        XCTAssertTrue(store.pendingOperations.isEmpty)
        XCTAssertEqual(harness.operations.count, 1)
        XCTAssertTrue(store.settings.runtime.recoveryRequired)
    }

    func testConsecutiveAuxiliaryOperationsKeepUIBusy() async {
        let harness = Harness(apps: [game(lock: true)])
        harness.setActive()
        harness.holdOperations = true
        let first = expectation(description: "Mouse started")
        let second = expectation(description: "Display started")
        harness.onOperation = { request in if request.operation == .display { second.fulfill() } else { first.fulfill() } }
        let store = harness.store()
        let task = store.send(.applyMouse)
        await fulfillment(of: [first], timeout: 2)
        await store.send(.platform(.launched("test.game"))).finish()
        harness.complete()
        await fulfillment(of: [second], timeout: 2)
        XCTAssertTrue(store.session.settingsAreChanging)
        XCTAssertTrue(store.settings.runtime.isTransitioning)
        XCTAssertFalse(store.settings.canEdit)
        harness.complete()
        await task.finish()
        XCTAssertFalse(store.settings.runtime.isTransitioning)
    }

    func testLateRecoverySuccessCannotClearAnExternalFailureOrResetPreferences() async {
        let harness = Harness(apps: [game()])
        harness.holdOperations = true
        let started = expectation(description: "Reset started")
        harness.onOperation = { _ in started.fulfill() }
        let store = harness.store()
        let task = store.send(.resetConfiguration)
        await fulfillment(of: [started], timeout: 2)
        await store.send(.session(.recoveryFailed("New recovery failure"))).finish()
        harness.complete()
        await task.finish()
        XCTAssertEqual(store.session.phase, .needsRecovery("New recovery failure"))
        XCTAssertEqual(harness.resets, 0)
        XCTAssertFalse(store.settings.runtime.isTransitioning)
        XCTAssertTrue(store.settings.runtime.recoveryRequired)
    }

    func testQueuedEngineCommandsRecheckRecoveryAndTerminationAtExecution() {
        let request = GameEngineClient.Request(id: 1, operation: .mouse(true))
        var context = GameEngineClient.Context(config: .defaults, session: .init(phase: .ready, desiredMode: true, appliedMode: true), request: request, needsDisplay: false)
        XCTAssertTrue(context.allows(request))
        context.session.phase = .needsRecovery("Pending")
        XCTAssertFalse(context.allows(request))
        context.session.phase = .terminating
        XCTAssertFalse(context.allows(request))
        let termination = GameEngineClient.Request(id: 2, operation: .terminate)
        context.request = termination
        XCTAssertTrue(context.allows(termination))
        XCTAssertFalse(context.allows(request))
    }

    func testTerminationSupersedesQueuedWorkAndRepliesEvenWhenRestorationFails() async {
        let harness = Harness(apps: [game()])
        harness.setActive()
        harness.failure = "Shutdown restore incomplete"
        let store = harness.store()
        await store.send(.terminationRequested(reply: true)).finish()
        XCTAssertEqual(harness.operations.map(\.operation), [.terminate])
        XCTAssertEqual(store.session.phase, .terminating)
        XCTAssertEqual(harness.commands.filter { $0 == .replyToTermination }.count, 1)
        await store.send(.platform(.launched("test.game"))).finish()
        await store.send(.toggleMode(.menu)).finish()
        XCTAssertTrue(harness.transitions.isEmpty)
    }

    func testSettingsActionsDriveHotkeysAndUpdaterWithoutSavingRuntimeStatus() async {
        let harness = Harness(apps: [])
        harness.initial.started = true
        let store = harness.store()
        await store.send(.settings(.binding(.set(\.config.receivesBetaUpdates, true)))).finish()
        XCTAssertEqual(harness.commands, [.resetUpdateCycle])
        await store.send(.settings(.updateHotkey(id: "toggleGameMode", keyCode: 5, modifiers: 123))).finish()
        XCTAssertEqual(harness.hotkeys.last?.first { $0.id == "toggleGameMode" }?.modifiers, 123)
        let writes = harness.saves
        await store.send(.accessibilityChanged(true)).finish()
        XCTAssertEqual(harness.saves, writes)
    }

    func testRecoveryNavigationAndPermissionPollingStopWhenSettingsClose() async {
        let harness = Harness(apps: [])
        let firstRead = expectation(description: "Initial permission read")
        let secondRead = expectation(description: "Permission refreshed")
        var reads = 0
        harness.onAccessibilityRead = {
            reads += 1
            if reads == 1 { firstRead.fulfill() }
            if reads == 2 { secondRead.fulfill() }
        }
        let store = harness.store()
        let task = store.send(.reviewRecovery)
        await fulfillment(of: [firstRead], timeout: 2)
        XCTAssertEqual(store.settings.selectedSection, .system)
        XCTAssertTrue(store.settingsIsVisible)
        XCTAssertTrue(harness.commands.contains(.showSettings))
        harness.permissionGranted = false
        await harness.clock.advance(by: .seconds(2))
        await fulfillment(of: [secondRead], timeout: 2)
        await store.send(.settingsClosed).finish()
        await task.finish()
        await harness.clock.advance(by: .seconds(10))
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(store.settingsIsVisible)
        XCTAssertFalse(store.settings.runtime.isAccessibilityGranted)
        XCTAssertEqual(harness.saves, 0)
    }

    func testRecordingPersistsWholeShortcutOnceAndRestoresRegistration() async {
        let harness = Harness(apps: [])
        harness.initial.started = true
        harness.keys = AsyncStream { continuation in
            continuation.yield(.init(code: 5, modifiers: 123))
            continuation.finish()
        }
        let store = harness.store()
        await store.send(.settings(.recordHotkey("toggleGameMode"))).finish()
        XCTAssertEqual(harness.saves, 1)
        XCTAssertEqual(store.settings.config.hotkeys.first { $0.id == "toggleGameMode" }?.keyCode, 5)
        XCTAssertEqual(store.settings.config.hotkeys.first { $0.id == "toggleGameMode" }?.modifiers, 123)
        XCTAssertNil(store.settings.recordingHotkeyID)
        XCTAssertEqual(harness.hotkeys.first, [])
        XCTAssertEqual(harness.hotkeys.last, store.settings.config.hotkeys)
    }

    func testStaleRecordingCannotOverwriteNewRecorderAndRecoveryCancelsRecording() async {
        let harness = Harness(apps: [])
        let stream = AsyncStream<ShortcutRecordingClient.Key>.makeStream()
        harness.keys = stream.stream
        let store = harness.store()
        let first = store.send(.settings(.recordHotkey("toggleGameMode")))
        await Task.yield()
        let second = store.send(.settings(.recordHotkey("toggleMouseBoost")))
        await store.send(.settings(.recordedHotkey("toggleGameMode", .init(code: 5, modifiers: 123)))).finish()
        XCTAssertEqual(store.settings.recordingHotkeyID, "toggleMouseBoost")
        XCTAssertEqual(harness.saves, 0)
        await store.send(.session(.recoveryFailed("Needs recovery"))).finish()
        await first.finish()
        await second.finish()
        XCTAssertNil(store.settings.recordingHotkeyID)
        XCTAssertTrue(store.settings.runtime.recoveryRequired)
    }

    @MainActor
    private final class Harness {
        var initial: GameModeFeature.State
        var operations: [GameEngineClient.Request] = []
        var transitions: [GameSession.Transition] = []
        var commands: [AppPlatformClient.Command] = []
        var hotkeys: [[AppHotkey]] = []
        var order: [String] = []
        var running: [String] = []
        var snapshot = GameEngineClient.Snapshot()
        var failure: String?
        var saves = 0
        var resets = 0
        var holdOperations = false
        var onOperation: (GameEngineClient.Request) -> Void = { _ in }
        var completions: [@MainActor () -> Void] = []
        var keys: AsyncStream<ShortcutRecordingClient.Key> = .finished
        let clock = TestClock()
        var permissionGranted = true
        var onAccessibilityRead: () -> Void = {}

        init(apps: [MonitoredApp]) {
            var settings = AppSettings.State()
            settings.config.monitoredApps = apps
            settings.hasSavedConfiguration = true
            settings.config.mouse.isEnabled = true
            initial = GameModeFeature.State(settings: settings)
            initial.session.phase = .ready
            initial.settings.runtime.isTransitioning = false
        }

        func setActive() {
            initial.session.appliedMode = true
            initial.session.desiredMode = true
            initial.settings.runtime.isGamingMode = true
        }

        func complete() { if !completions.isEmpty { completions.removeFirst()() } }

        func execute(_ request: GameEngineClient.Request, report: @escaping @MainActor @Sendable (GameEngineClient.Response) -> Void) async {
            operations.append(request)
            order.append(String(describing: request.operation))
            onOperation(request)
            if holdOperations {
                await withCheckedContinuation { continuation in
                    completions.append { [self] in
                        report(failure.map { .failed($0, snapshot) } ?? .completed(snapshot))
                        continuation.resume()
                    }
                }
            } else { report(failure.map { .failed($0, snapshot) } ?? .completed(snapshot)) }
        }

        func store() -> StoreOf<GameModeFeature> {
            Store(initialState: initial) { GameModeFeature() } withDependencies: {
                $0.settingsClient = SettingsClient(load: { .init() }, save: { [self] _ in MainActor.assumeIsolated { saves += 1 } }, reset: { [self] _, _ in MainActor.assumeIsolated { resets += 1; order.append("preferences-reset") } }, detectShortcuts: { [] }, saveSelectedSection: { _ in })
                $0.settingsViewClient = .previewValue
                $0.continuousClock = self.clock
                $0.gameEngine = .init(execute: { [self] in await execute($0, report: $1) }, snapshot: { [self] in MainActor.assumeIsolated { snapshot } })
                $0.gameSession = .init(transition: { [self] request in
                    await MainActor.run { transitions.append(request); order.append(request.isEnabled ? "mode-on" : "mode-off") }
                    return .applied
                })
                $0.appPlatform = .init(events: { .finished }, runningBundleIDs: { [self] in running }, accessibilityGranted: { [self] in onAccessibilityRead(); return permissionGranted }, configureHotkeys: { [self] in hotkeys.append($0) }, command: { [self] in commands.append($0) }, configureLogging: { _ in })
                $0.shortcutRecording = .init(events: { [self] in keys })
            }
        }
    }
}
