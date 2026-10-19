//
//  GameSessionTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import XCTest
@testable import GameMode

@MainActor
final class GameSessionTests: XCTestCase {
    private func store(state: GameSession.State = .init(phase: .ready), client: GameSessionClient = .testValue) -> TestStoreOf<GameSession> {
        TestStore(initialState: state) { GameSession() } withDependencies: { $0.gameSession = client }
    }

    func testStartupAndFailedRecoveryBlockEveryActivationSource() async {
        let store = store(state: .init())
        for source in [GameSession.Source.automatic, .menu, .hotkey] {
            await store.send(.modeRequested(true, source: source))
        }
        await store.send(.recoveryFailed("Previous session needs recovery")) {
            $0.phase = .needsRecovery("Previous session needs recovery")
        }
        for source in [GameSession.Source.automatic, .menu, .hotkey] {
            await store.send(.modeRequested(true, source: source))
        }
        await store.send(.recoveryStarted) { $0.phase = .recovering }
        await store.send(.modeRequested(true, source: .automatic))
        await store.send(.recoverySucceeded) { $0.phase = .ready }
        XCTAssertTrue(store.state.recoveryReady)
        XCTAssertFalse(store.state.isBusy)
    }

    func testAppliedModeChangesOnlyAfterSuccessAndManualRequestsAreIgnoredWhileBusy() async {
        let gate = TransitionGate()
        let store = store(client: .init(transition: { try await gate.run($0) }))
        let activation = GameSession.Transition(id: 1, isEnabled: true)
        await store.send(.modeRequested(true, source: .menu)) {
            $0.desiredMode = true
            $0.phase = .transitioning(activation)
            $0.transitionSequence = 1
        }
        let request = await gate.nextRequest()
        XCTAssertEqual(request, activation)
        XCTAssertFalse(store.state.appliedMode)
        await store.send(.modeRequested(false, source: .menu))
        await store.send(.modeRequested(false, source: .hotkey))
        await store.send(.modeRequested(true, source: .automatic))
        await gate.complete(activation)
        await store.receive(\.transitionFinished) {
            $0.phase = .ready
            $0.appliedMode = true
        }
        await store.send(.modeRequested(true, source: .menu))
        await store.finish()
    }

    func testAutomaticExitWaitsForActivationThenRestoresWithoutOverlap() async {
        let gate = TransitionGate()
        let store = store(client: .init(transition: { try await gate.run($0) }))
        let activation = GameSession.Transition(id: 1, isEnabled: true)
        let restoration = GameSession.Transition(id: 2, isEnabled: false)
        await store.send(.modeRequested(true, source: .automatic)) {
            $0.desiredMode = true
            $0.phase = .transitioning(activation)
            $0.transitionSequence = 1
        }
        _ = await gate.nextRequest()
        await store.send(.modeRequested(false, source: .automatic)) { $0.desiredMode = false }
        let count = await gate.requestCount
        XCTAssertEqual(count, 1)
        await gate.complete(activation)
        await store.receive(\.transitionFinished) {
            $0.appliedMode = true
            $0.phase = .transitioning(restoration)
            $0.transitionSequence = 2
        }
        let request = await gate.nextRequest()
        XCTAssertEqual(request, restoration)
        await gate.complete(restoration)
        await store.receive(\.transitionFinished) {
            $0.appliedMode = false
            $0.phase = .ready
        }
        await store.finish()
    }

    func testAutomaticBurstsCoalesceToTheLatestTarget() async {
        let gate = TransitionGate()
        let store = store(client: .init(transition: { try await gate.run($0) }))
        let activation = GameSession.Transition(id: 1, isEnabled: true)
        await store.send(.modeRequested(true, source: .automatic)) {
            $0.desiredMode = true
            $0.phase = .transitioning(activation)
            $0.transitionSequence = 1
        }
        _ = await gate.nextRequest()
        await store.send(.modeRequested(false, source: .automatic)) { $0.desiredMode = false }
        await store.send(.modeRequested(true, source: .automatic)) { $0.desiredMode = true }
        await gate.complete(activation)
        await store.receive(\.transitionFinished) {
            $0.appliedMode = true
            $0.phase = .ready
        }
        await store.finish()
        let count = await gate.requestCount
        XCTAssertEqual(count, 1)
    }

    func testRelaunchDuringRestorationWaitsBeforeActivatingAgain() async {
        let gate = TransitionGate()
        let store = store(state: .init(phase: .ready, desiredMode: true, appliedMode: true), client: .init(transition: { try await gate.run($0) }))
        let restoration = GameSession.Transition(id: 1, isEnabled: false)
        let activation = GameSession.Transition(id: 2, isEnabled: true)
        await store.send(.modeRequested(false, source: .automatic)) {
            $0.desiredMode = false
            $0.phase = .transitioning(restoration)
            $0.transitionSequence = 1
        }
        _ = await gate.nextRequest()
        await store.send(.modeRequested(true, source: .automatic)) { $0.desiredMode = true }
        await gate.complete(restoration)
        await store.receive(\.transitionFinished) {
            $0.appliedMode = false
            $0.phase = .transitioning(activation)
            $0.transitionSequence = 2
        }
        let request = await gate.nextRequest()
        XCTAssertEqual(request, activation)
        await gate.complete(activation)
        await store.receive(\.transitionFinished) {
            $0.appliedMode = true
            $0.phase = .ready
        }
        await store.finish()
    }

    func testFailedRestoreKeepsAppliedStateAndDiscardsPendingActivationUntilRecovery() async {
        let gate = TransitionGate()
        let store = store(state: .init(phase: .ready, desiredMode: true, appliedMode: true), client: .init(transition: { try await gate.run($0) }))
        let restoration = GameSession.Transition(id: 1, isEnabled: false)
        await store.send(.modeRequested(false, source: .menu)) {
            $0.desiredMode = false
            $0.phase = .transitioning(restoration)
            $0.transitionSequence = 1
        }
        _ = await gate.nextRequest()
        await store.send(.modeRequested(true, source: .automatic)) { $0.desiredMode = true }
        await gate.fail(restoration, message: "Display unavailable")
        await store.receive(\.transitionFailed) { $0.phase = .needsRecovery("Display unavailable") }
        await store.send(.modeRequested(false, source: .menu))
        await store.send(.modeRequested(true, source: .automatic))
        await store.send(.recoveryStarted) {
            $0.phase = .recovering
            $0.desiredMode = false
        }
        await store.send(.recoverySucceeded) {
            $0.phase = .ready
            $0.appliedMode = false
        }
        await store.finish()
    }

    func testInvalidConfigurationAndLiveSettingsChangesGateManualRequests() async {
        let store = store(state: .init(phase: .ready, configurationIsValid: false))
        await store.send(.modeRequested(true, source: .automatic))
        await store.send(.modeRequested(true, source: .menu))
        await store.send(.configurationValidityChanged(true)) { $0.configurationIsValid = true }
        await store.send(.settingsActivityChanged(true)) { $0.settingsAreChanging = true }
        await store.send(.modeRequested(true, source: .menu))
        await store.send(.modeRequested(true, source: .hotkey))
        await store.send(.settingsActivityChanged(false)) { $0.settingsAreChanging = false }
    }

    func testAutomaticRequestsQueueDuringLiveSettingsChangesAndRunAfterTheyFinish() async {
        let store = store(state: .init(phase: .ready, settingsAreChanging: true), client: .init(transition: { _ in .applied }))
        await store.send(.modeRequested(true, source: .automatic)) { $0.desiredMode = true }
        XCTAssertTrue(store.state.isBusy)
        XCTAssertFalse(store.state.appliedMode)
        await store.send(.settingsActivityChanged(false)) {
            $0.settingsAreChanging = false
            $0.phase = .transitioning(.init(id: 1, isEnabled: true))
            $0.transitionSequence = 1
        }
        await store.receive(\.transitionFinished) {
            $0.appliedMode = true
            $0.phase = .ready
        }
        XCTAssertFalse(store.state.isBusy)
        await store.finish()
    }

    func testTerminationDoesNotCancelMutationAndIgnoresLateSuccess() async {
        let gate = TransitionGate()
        let store = store(client: .init(transition: { try await gate.run($0) }))
        let activation = GameSession.Transition(id: 1, isEnabled: true)
        await store.send(.modeRequested(true, source: .menu)) {
            $0.desiredMode = true
            $0.phase = .transitioning(activation)
            $0.transitionSequence = 1
        }
        _ = await gate.nextRequest()
        await store.send(.terminationRequested) {
            $0.phase = .terminating
            $0.desiredMode = false
        }
        await store.send(.modeRequested(true, source: .automatic))
        await store.send(.recoverySucceeded)
        await store.send(.recoveryFailed("Shutdown restore still pending"))
        await gate.complete(activation)
        await store.receive(\.transitionFinished)
        await store.finish()
        XCTAssertFalse(store.state.appliedMode)
    }

    func testExternalRecoveryFailureCannotBeClearedByAnInFlightSuccess() async {
        let gate = TransitionGate()
        let store = store(client: .init(transition: { try await gate.run($0) }))
        let activation = GameSession.Transition(id: 1, isEnabled: true)
        await store.send(.modeRequested(true, source: .automatic)) {
            $0.desiredMode = true
            $0.phase = .transitioning(activation)
            $0.transitionSequence = 1
        }
        _ = await gate.nextRequest()
        await store.send(.recoveryFailed("Mouse restore failed")) {
            $0.phase = .needsRecovery("Mouse restore failed")
            $0.desiredMode = false
        }
        await gate.complete(activation)
        await store.receive(\.transitionFinished)
        await store.finish()
        XCTAssertEqual(store.state.recoveryMessage, "Mouse restore failed")
    }

    func testSkippedWorkerOperationIsNeverPresentedAsApplied() async {
        let store = store(client: .init(transition: { _ in .skipped }))
        await store.send(.modeRequested(true, source: .menu)) {
            $0.desiredMode = true
            $0.phase = .transitioning(.init(id: 1, isEnabled: true))
            $0.transitionSequence = 1
        }
        await store.receive(\.transitionFinished) {
            $0.desiredMode = false
            $0.phase = .ready
        }
        XCTAssertFalse(store.state.appliedMode)
    }

    /// Tests control completions explicitly, without sleeps or scheduler timing.
    private actor TransitionGate {
        private var pending: [UInt64: CheckedContinuation<GameSessionClient.Outcome, Error>] = [:]
        private var requests: [GameSession.Transition] = []
        private var waiters: [CheckedContinuation<GameSession.Transition, Never>] = []
        private(set) var requestCount = 0

        func run(_ transition: GameSession.Transition) async throws -> GameSessionClient.Outcome {
            try await withCheckedThrowingContinuation { continuation in
                requestCount += 1
                pending[transition.id] = continuation
                if waiters.isEmpty { requests.append(transition) }
                else { waiters.removeFirst().resume(returning: transition) }
            }
        }

        func nextRequest() async -> GameSession.Transition {
            if !requests.isEmpty { return requests.removeFirst() }
            return await withCheckedContinuation { waiters.append($0) }
        }

        func complete(_ transition: GameSession.Transition) {
            pending.removeValue(forKey: transition.id)?.resume(returning: .applied)
        }

        func fail(_ transition: GameSession.Transition, message: String) {
            pending.removeValue(forKey: transition.id)?.resume(throwing: RecoveryController.Failure.message(message))
        }
    }
}

@MainActor
final class GameSessionRecoveryTests: XCTestCase {
    func testSessionCanCompleteWhileTheMenuTrackingRunLoopIsActive() {
        let queue = DispatchQueue(label: "GameSessionTests.menuTracking")
        let store = Store(initialState: GameSession.State(phase: .ready)) { GameSession() } withDependencies: {
            $0.gameSession = .serialized(on: queue, shouldExecute: { _ in true }, apply: { _ in })
        }
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        store.send(.modeRequested(true, source: .menu))
        let deadline = Date().addingTimeInterval(2)
        while store.isBusy && Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(store.appliedMode)
        XCTAssertFalse(store.isBusy)
    }

    func testExecutorPublishesResultBeforeTheNextQueuedSettingsOperation() async {
        let queue = DispatchQueue(label: "GameSessionTests.completionOrdering")
        let events = LockIsolated<[String]>([])
        let nextOperation = expectation(description: "Queued settings operation ran")
        let client = GameSessionClient.serialized(on: queue, shouldExecute: { _ in true }, apply: { _ in
            events.withValue { $0.append("apply") }
            queue.async {
                events.withValue { $0.append("next settings operation") }
                nextOperation.fulfill()
            }
        })
        await client.execute(.init(id: 1, isEnabled: true)) { response in
            XCTAssertEqual(response, .completed(.applied))
            events.withValue { $0.append("published") }
        }
        await fulfillment(of: [nextOperation], timeout: 2)
        XCTAssertEqual(events.value, ["apply", "published", "next settings operation"])
    }

    func testCheckpointFailureThroughTCAStillPerformsNoSystemMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = RecoveryMachine(directory: directory, failCheckpoint: true)
        let store = TestStore(initialState: GameSession.State(phase: .ready)) { GameSession() } withDependencies: {
            $0.gameSession = machine.client
        }
        await store.send(.modeRequested(true, source: .automatic)) {
            $0.desiredMode = true
            $0.phase = .transitioning(.init(id: 1, isEnabled: true))
            $0.transitionSequence = 1
        }
        await store.receive(\.transitionFailed) {
            $0.phase = .needsRecovery(JournalError.io("test checkpoint", 5).localizedDescription)
            $0.desiredMode = false
        }
        XCTAssertEqual(machine.queue.sync { machine.mutationCount }, 0)
        XCTAssertFalse(machine.queue.sync { machine.keyboardEnabled })
        await store.send(.modeRequested(true, source: .menu))
        await store.finish()
    }

    func testInterruptedActivationPreservesOriginalsAcrossFailedRecoveryAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = RecoveryMachine(directory: directory)
        machine.queue.sync { machine.interruptActivation = true }
        let store = TestStore(initialState: GameSession.State(phase: .ready)) { GameSession() } withDependencies: {
            $0.gameSession = machine.client
        }
        await store.send(.modeRequested(true, source: .menu)) {
            $0.desiredMode = true
            $0.phase = .transitioning(.init(id: 1, isEnabled: true))
            $0.transitionSequence = 1
        }
        await store.receive(\.transitionFailed) {
            $0.phase = .needsRecovery("Interrupted after keyboard change")
            $0.desiredMode = false
        }
        XCTAssertTrue(machine.queue.sync { machine.checkpointPrecededMutation })
        XCTAssertTrue(machine.queue.sync { machine.keyboardEnabled })
        XCTAssertEqual(try machine.journal.load().appliedChanges.previousFunctionKeysEnabled, false)
        await store.send(.modeRequested(true, source: .automatic))

        machine.queue.sync { machine.failRestoration = true }
        await store.send(.recoveryStarted) { $0.phase = .recovering }
        do {
            try await machine.restore()
            XCTFail("Restoration should fail")
        } catch {
            await store.send(.recoveryFailed(error.localizedDescription)) { $0.phase = .needsRecovery("Keyboard restore failed") }
        }
        XCTAssertEqual(try machine.journal.load().appliedChanges.previousFunctionKeysEnabled, false)
        await store.send(.modeRequested(true, source: .hotkey))

        machine.queue.sync { machine.failRestoration = false }
        await store.send(.recoveryStarted) { $0.phase = .recovering }
        try await machine.restore(afterRestart: true)
        await store.send(.recoverySucceeded) { $0.phase = .ready }
        XCTAssertFalse(machine.queue.sync { machine.keyboardEnabled })
        XCTAssertEqual(machine.queue.sync { machine.mutationCount }, 1)
        XCTAssertEqual(machine.journal.inspect(), .clean)
        await store.finish()
    }

    func testSuccessfulActivationAndDeactivationUseTheSameDurableRecoveryPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = RecoveryMachine(directory: directory)
        let store = TestStore(initialState: GameSession.State(phase: .ready)) { GameSession() } withDependencies: {
            $0.gameSession = machine.client
        }
        await store.send(.modeRequested(true, source: .hotkey)) {
            $0.desiredMode = true
            $0.phase = .transitioning(.init(id: 1, isEnabled: true))
            $0.transitionSequence = 1
        }
        await store.receive(\.transitionFinished) {
            $0.phase = .ready
            $0.appliedMode = true
        }
        XCTAssertTrue(machine.queue.sync { machine.checkpointPrecededMutation })
        XCTAssertTrue(try machine.journal.load().appliedChanges.functionKeysChanged)
        await store.send(.modeRequested(false, source: .hotkey)) {
            $0.desiredMode = false
            $0.phase = .transitioning(.init(id: 2, isEnabled: false))
            $0.transitionSequence = 2
        }
        await store.receive(\.transitionFinished) {
            $0.phase = .ready
            $0.appliedMode = false
        }
        XCTAssertFalse(machine.queue.sync { machine.keyboardEnabled })
        XCTAssertEqual(machine.journal.inspect(), .clean)
        await store.finish()
    }

    func testExecutorRechecksShutdownGateBeforeRunningQueuedMutation() async throws {
        let queue = DispatchQueue(label: "GameSessionTests.blockedWorker")
        let gate = LockIsolated(true)
        let blockerStarted = expectation(description: "Worker is occupied")
        let release = DispatchSemaphore(value: 0)
        queue.async {
            blockerStarted.fulfill()
            release.wait()
        }
        await fulfillment(of: [blockerStarted], timeout: 2)
        let client = GameSessionClient.serialized(on: queue, shouldExecute: { _ in
            dispatchPrecondition(condition: .onQueue(queue))
            return gate.value
        }, apply: { _ in XCTFail("A queued activation must not run after shutdown") })
        let task = Task {
            await client.execute(.init(id: 1, isEnabled: true)) { response in
                XCTAssertEqual(response, .completed(.skipped))
            }
        }
        gate.setValue(false)
        release.signal()
        await task.value
    }

    /// Mutable fake hardware and its controller are confined to the settings queue.
    /// The real journal writes only into a unique temporary directory.
    private final class RecoveryMachine: @unchecked Sendable {
        let queue = DispatchQueue(label: "GameSessionTests.settings")
        let journal: StateJournal
        var keyboardEnabled = false
        var mutationCount = 0
        var checkpointPrecededMutation = false
        var interruptActivation = false
        var failRestoration = false

        init(directory: URL, failCheckpoint: Bool = false) {
            journal = failCheckpoint
                ? StateJournal(directory: directory, writer: { _, _ in throw JournalError.io("test checkpoint", 5) })
                : StateJournal(directory: directory)
        }

        private var operations: RecoveryController.Operations {
            .init(stopDisplays: { [] }, restoreDisplays: { _ in [] }, restoreKeyboard: { [unowned self] changes in
                if self.failRestoration { return ["Keyboard restore failed"] }
                if let original = changes.previousFunctionKeysEnabled { self.keyboardEnabled = original }
                return []
            }, restorePower: { _ in [] }, readMouse: { 0.3 }, applyMouse: { _ in true })
        }

        private lazy var recovery = RecoveryController(journal: journal, operations: operations)

        var client: GameSessionClient {
            .serialized(on: queue, shouldExecute: { _ in true }, apply: { [self] transition in
                if !transition.isEnabled { try recovery.restore(); return }
                let changes = AppliedChanges(functionKeysChanged: true, previousFunctionKeysEnabled: keyboardEnabled,
                                             disabledShortcutIDs: [], mouseSpeedChanged: false, previousMouseSpeed: nil)
                try recovery.activate(GameModeState(isActive: true, activatedAt: Date(), appliedChanges: changes)) {
                    checkpointPrecededMutation = try journal.load().appliedChanges.previousFunctionKeysEnabled == keyboardEnabled
                    keyboardEnabled = true
                    mutationCount += 1
                    if interruptActivation { throw RecoveryController.Failure.message("Interrupted after keyboard change") }
                }
            })
        }

        func restore(afterRestart: Bool = false) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do {
                        if afterRestart { try RecoveryController(journal: journal, operations: operations).prepareForLaunch(restoreAutomatically: true) }
                        else { try recovery.restore() }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
}
