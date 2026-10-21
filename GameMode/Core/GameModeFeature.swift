//
//  GameModeFeature.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import Foundation

/// The app's single state owner. Native adapters only deliver events, render state,
/// and execute commands; all operation ordering and recovery gates live here.
@Reducer
struct GameModeFeature {
    @ObservableState
    struct State: Equatable {
        var settings: AppSettings.State
        var session: GameSession.State
        var started = false
        var settingsIsVisible = false
        var needsInitialAppScan = true
        var processCounts: [String: Int] = [:]
        var operationSequence: UInt64 = 0
        var operation: GameEngineClient.Request?
        var pendingOperations: [GameEngineClient.Operation] = []
        var mouse = GameEngineClient.Snapshot()
        var shouldReplyToTermination = false

        init(settings: AppSettings.State) {
            self.settings = settings
            session = GameSession.State(configurationIsValid: settings.configurationLoadError == nil)
            if settings.isPreview { session.phase = .ready }
            self.settings.runtime.isTransitioning = session.isBusy
        }

        var activeGameCount: Int { processCounts.values.reduce(0, +) }
        func monitors(_ id: String) -> Bool {
            settings.config.monitoredApps.contains { $0.isEnabled && $0.matches(bundleID: id) }
        }
        var needsDisplay: Bool {
            settings.config.monitoredApps.contains { entry in
                entry.isEnabled && entry.lockRefreshRate && processCounts.keys.contains { entry.matches(bundleID: $0) }
            }
        }
        var visibleMouseTarget: Bool? {
            guard case .mouse(let enabled) = operation?.operation else { return nil }
            return enabled
        }
        var engineContext: GameEngineClient.Context {
            .init(config: settings.config, session: session, request: operation, needsDisplay: needsDisplay)
        }
    }

    enum Action {
        case settings(AppSettings.Action)
        case session(GameSession.Action)
        case launched
        case initialDiscoveryFinished([MonitoredApp])
        case platform(AppPlatformClient.Event)
        case runningAppsLoaded([String], activate: Bool)
        case operationFinished(GameEngineClient.Request, GameEngineClient.Response)
        case toggleMode(GameSession.Source)
        case toggleMouse
        case applyMouse
        case retryRecovery
        case acceptCurrentSettings
        case resetConfiguration
        case settingsRequested
        case reviewRecovery
        case aboutRequested
        case reopenRequested
        case settingsClosed
        case settingsBecameKey
        case accessibilityChanged(Bool)
        case terminationRequested(reply: Bool)
        case command(AppPlatformClient.Command)
        case recoveryKitDestinationChosen(URL?)
    }

    @Dependency(\.gameEngine) var engine
    @Dependency(\.appPlatform) var platform
    @Dependency(\.settingsViewClient) var settingsView
    @Dependency(\.continuousClock) var clock
    private enum CancelID { case events, permissions }

    var body: some ReducerOf<Self> {
        CombineReducers {
            Reduce<State, Action> { state, action in
                switch action {
                case .session(.transitionFinished(let transition, .applied)) where state.session.allows(transition):
                    state.mouse = engine.snapshot()
                    return .run { _ in await platform.command(.notifyMode(transition.isEnabled)) }
                case .session(.transitionFailed(let transition, _)) where state.session.allows(transition):
                    state.mouse = engine.snapshot()
                    return .none
                default: return .none
                }
            }
            Scope(state: \.settings, action: \.settings) { AppSettings() }
            Scope(state: \.session, action: \.session) { GameSession() }
            Reduce<State, Action> { state, action in
                var effects: [Effect<Action>] = []
                func command(_ value: AppPlatformClient.Command) -> Effect<Action> {
                    .run { _ in await platform.command(value) }
                }
                switch action {
                case .launched:
                    guard !state.started else { return .none }
                    state.started = true
                    platform.configureLogging(state.settings.config)
                    if state.settings.isPreview {
                        state.settings.runtime.isAccessibilityGranted = true
                        effects.append(.send(.settingsRequested))
                    } else {
                        effects.append(.run { [hotkeys = state.settings.config.hotkeys] send in
                            let events = await platform.events()
                            await platform.configureHotkeys(hotkeys)
                            await platform.command(.start)
                            let granted = await platform.accessibilityGranted()
                            await send(.accessibilityChanged(granted))
                            if !granted { await platform.command(.requestAccessibility) }
                            for await event in events { await send(.platform(event)) }
                        }.cancellable(id: CancelID.events))
                        let discover = !state.settings.hasSavedConfiguration && state.settings.configurationLoadError == nil
                        effects.append(.run { send in
                            await send(.initialDiscoveryFinished(discover ? await settingsView.scanGames() : []))
                        })
                    }
                case .initialDiscoveryFinished(let apps):
                    guard state.session.phase == .recovering, state.operation == nil else { break }
                    effects.append(.send(.settings(.seedConfiguration(apps))))
                case .settings(.seedConfiguration):
                    if state.session.phase == .recovering, state.operation == nil { effects.append(begin(.startup, state: &state)) }
                case .platform(.launched(let id)):
                    guard state.monitors(id) else { break }
                    let count = state.activeGameCount
                    let neededDisplay = state.needsDisplay
                    state.processCounts[id, default: 0] += 1
                    if count == 0, state.activeGameCount > 0 {
                        effects.append(.send(.session(.modeRequested(true, source: .automatic))))
                    }
                    if state.activeGameCount > 0, neededDisplay != state.needsDisplay { enqueue(.display, state: &state) }
                case .platform(.terminated(let id)):
                    let count = state.activeGameCount
                    let neededDisplay = state.needsDisplay
                    if let processes = state.processCounts[id] {
                        if processes > 1 { state.processCounts[id] = processes - 1 }
                        else { state.processCounts.removeValue(forKey: id) }
                    }
                    if count > 0, state.activeGameCount == 0 {
                        effects.append(.send(.session(.modeRequested(false, source: .automatic))))
                    }
                    if state.activeGameCount > 0, neededDisplay != state.needsDisplay { enqueue(.display, state: &state) }
                case .platform(.hotkey(let id)):
                    guard state.settings.recordingHotkeyID == nil, state.settings.config.hotkeys.contains(where: { $0.id == id && $0.isEnabled && $0.keyCode != nil }) else { break }
                    switch id {
                    case "toggleGameMode": effects.append(.send(.toggleMode(.hotkey)))
                    case "toggleMouseBoost": effects.append(.send(.toggleMouse))
                    case "toggleInputSource": effects.append(command(.toggleInputSource))
                    default: break
                    }
                case .platform(.powerOff): effects.append(.send(.terminationRequested(reply: false)))
                case let .runningAppsLoaded(ids, activate):
                    guard state.session.phase != .terminating else { break }
                    state.processCounts = Dictionary(ids.filter { state.monitors($0) }.map { ($0, 1) }, uniquingKeysWith: +)
                    if activate, state.activeGameCount > 0 {
                        effects.append(.send(.session(.modeRequested(true, source: .automatic))))
                    }
                case let .operationFinished(request, response):
                    guard state.operation == request else { break }
                    state.operation = nil
                    // An external recovery failure may supersede a successful
                    // worker result. Only the still-current recovery can unlock UI.
                    if request.operation.isRecovery, state.session.phase != .recovering {
                        state.session.settingsAreChanging = false
                        break
                    }
                    switch response {
                    case .failed(let message, let snapshot):
                        if request.operation.isReadOnly {
                            state.settings.recoveryToolError = message
                            break
                        }
                        state.mouse = snapshot
                        state.pendingOperations = []
                        if state.session.phase != .terminating {
                            state.session.phase = .needsRecovery(message)
                            state.session.desiredMode = state.session.appliedMode
                        }
                    case .completed(let snapshot):
                        if request.operation == .inspectRecovery {
                            state.settings.recoveryDocument = snapshot.recoveryBackup
                        }
                        if case .exportRecoveryKit(let url) = request.operation {
                            state.settings.recoveryKitPath = url.path
                            state.settings.recoveryToolError = nil
                            state.settings.recoveryNotice = "Recovery file and standalone app exported."
                        }
                        if case .restoreBackup = request.operation {
                            state.settings.importedRecovery = nil
                            state.settings.importedRecoveryName = nil
                            state.settings.recoveryNotice = "Saved settings restored."
                            effects.append(.send(.settings(.recoveryPageOpened)))
                        }
                        if request.operation == .recover, state.settings.recoveryPageIsPresented {
                            state.settings.recoveryNotice = "Settings restored."
                            effects.append(.send(.settings(.recoveryPageOpened)))
                        }
                        state.mouse = snapshot
                        if request.operation == .reset {
                            effects.append(.send(.settings(.resetAfterRecovery)))
                        }
                        if request.operation.isRecovery && request.operation != .reset {
                            state.session.phase = .ready
                            state.session.appliedMode = false
                            state.session.desiredMode = false
                            if request.operation == .accept, state.settings.config.system.repairLegacyFunctionKeyOverride {
                                // Explicitly accepting today's settings must also stop the optional cleanup policy.
                                effects.append(.send(.settings(.binding(.set(\.config.system.repairLegacyFunctionKeyOverride, false)))))
                            }
                            if state.settings.configurationLoadError == nil {
                                let activate = state.needsInitialAppScan && (request.operation == .startup || request.operation == .recover)
                                state.needsInitialAppScan = false
                                effects.append(.run { send in await send(.runningAppsLoaded(platform.runningBundleIDs(), activate: activate)) })
                            }
                        }
                    }
                    // Release the auxiliary lock only after failure/recovery was published.
                    state.session.settingsAreChanging = false
                    effects.append(.send(.session(.modeRequested(state.session.desiredMode, source: .automatic))))
                    if request.operation == .terminate, state.shouldReplyToTermination {
                        state.shouldReplyToTermination = false
                        effects.append(command(.replyToTermination))
                    }
                case .toggleMode(let source):
                    if state.settings.isPreview { state.session.appliedMode.toggle(); state.session.desiredMode = state.session.appliedMode }
                    else { effects.append(.send(.session(.modeRequested(!state.session.appliedMode, source: source)))) }
                case .toggleMouse, .applyMouse:
                    guard state.settings.canEdit, state.session.appliedMode, state.settings.config.mouse.isEnabled else { break }
                    let enabled: Bool
                    if case .applyMouse = action { enabled = true } else { enabled = !state.mouse.mouseIsApplied }
                    if state.settings.isPreview { state.mouse.mouseIsApplied = enabled }
                    else { enqueue(.mouse(enabled), state: &state) }
                case .retryRecovery, .acceptCurrentSettings, .resetConfiguration, .settings(.restoreNormalSettings), .settings(.removeFunctionKeyOverride):
                    guard !state.session.isBusy else { break }
                    if case .settings(.removeFunctionKeyOverride) = action, state.session.appliedMode { break }
                    if case .acceptCurrentSettings = action, !state.settings.canAcceptCurrentSettings { break }
                    if case .resetConfiguration = action, !state.settings.canResetConfiguration { break }
                    let operation: GameEngineClient.Operation
                    switch action {
                    case .acceptCurrentSettings: operation = .accept
                    case .resetConfiguration: operation = .reset
                    case .settings(.restoreNormalSettings): operation = .restoreNormalSettings
                    case .settings(.removeFunctionKeyOverride(let expected)):
                        operation = .removeFunctionKeyOverride(expected)
                    default: operation = .recover
                    }
                    state.pendingOperations = []
                    state.session.phase = .recovering
                    state.session.desiredMode = false
                    state.settings.recoveryToolError = nil
                    if state.settings.isPreview {
                        if operation == .reset { effects.append(.send(.settings(.resetAfterRecovery))) }
                        state.mouse = .init()
                        state.session.phase = .ready
                        state.session.appliedMode = false
                        state.session.desiredMode = false
                    } else { effects.append(begin(operation, state: &state)) }
                case .settingsRequested, .reviewRecovery:
                    if case .reviewRecovery = action {
                        effects.append(.run { send in
                            await send(.settings(.sectionSelected(.system)))
                            await send(.settings(.recoveryPageOpened))
                        })
                    }
                    state.settingsIsVisible = true
                    effects.append(command(.showSettings))
                    if !state.settings.isPreview {
                        effects.append(.run { send in
                            await send(.accessibilityChanged(platform.accessibilityGranted()))
                            for await _ in clock.timer(interval: .seconds(2)) {
                                await send(.accessibilityChanged(platform.accessibilityGranted()))
                            }
                        }.cancellable(id: CancelID.permissions, cancelInFlight: true))
                    }
                case .settingsClosed:
                    state.settingsIsVisible = false
                    effects.append(.send(.settings(.stopRecording)))
                    effects.append(.cancel(id: CancelID.permissions))
                case .settingsBecameKey:
                    effects.append(.send(.settings(.refreshShortcuts)))
                case .accessibilityChanged(let granted): state.settings.runtime.isAccessibilityGranted = granted
                case .aboutRequested: effects.append(command(.showAbout))
                case .reopenRequested: effects.append(command(.reopenWindow))
                case .command(let value):
                    if !state.settings.isPreview { effects.append(command(value)) }
                case .terminationRequested(let reply):
                    state.shouldReplyToTermination = state.shouldReplyToTermination || reply
                    state.pendingOperations = []
                    state.session.phase = .terminating
                    state.session.desiredMode = false
                    effects.append(.send(.settings(.stopRecording)))
                    effects.append(.cancel(id: CancelID.permissions))
                    effects.append(.cancel(id: CancelID.events))
                    if !state.settings.isPreview {
                        if state.operation?.operation != .terminate { effects.append(begin(.terminate, state: &state)) }
                    } else if state.shouldReplyToTermination {
                        state.shouldReplyToTermination = false
                        effects.append(command(.replyToTermination))
                    }
                case .settings(.resetAfterRecovery):
                    guard state.session.phase == .recovering else { break }
                    state.session.phase = .ready
                    state.session.appliedMode = false
                    state.session.desiredMode = false
                    if state.settings.configurationLoadError == nil {
                        state.needsInitialAppScan = false
                        effects.append(.run { send in await send(.runningAppsLoaded(platform.runningBundleIDs(), activate: false)) })
                    }
                case .settings(.exportRecoveryKit):
                    guard !state.session.isBusy else { break }
                    effects.append(.run { send in await send(.recoveryKitDestinationChosen(settingsView.chooseRecoveryKitDestination())) })
                case .settings(.recoveryPageOpened):
                    guard !state.session.isBusy else { break }
                    state.settings.recoveryToolError = nil
                    if !state.settings.isPreview { effects.append(begin(.inspectRecovery, state: &state)) }
                case .settings(.restoreRecoveryFile):
                    guard !state.session.isBusy, let backup = state.settings.importedRecovery, !state.settings.selectedRecoverySettings.isEmpty else { break }
                    state.pendingOperations = []
                    state.session.phase = .recovering
                    state.session.desiredMode = false
                    state.settings.recoveryToolError = nil
                    if state.settings.isPreview {
                        state.session.phase = .ready
                        state.session.appliedMode = false
                        state.settings.importedRecovery = nil
                    } else {
                        effects.append(begin(.restoreBackup(backup, state.settings.selectedRecoverySettings), state: &state))
                    }
                case .recoveryKitDestinationChosen(let destination):
                    guard let destination, !state.session.isBusy else { break }
                    state.settings.recoveryToolError = nil
                    effects.append(begin(.exportRecoveryKit(destination), state: &state))
                case .settings(.command(let value)): effects.append(.send(.command(value)))
                case .settings(.applyMouse): effects.append(.send(.applyMouse))
                case .settings(.retryRecovery): effects.append(.send(.retryRecovery))
                case .settings(.acceptCurrentSettings): effects.append(.send(.acceptCurrentSettings))
                case .settings(.resetConfiguration): effects.append(.send(.resetConfiguration))
                case .settings, .session: break
                }

                return .merge(effects)
            }
        }
        .onChange(of: \.settings.config) { previousConfig, state in
            var effects: [Effect<Action>] = []
            let config = state.settings.config
            platform.configureLogging(config)
            if !state.settings.isPreview, state.started {
                if !previousConfig.system.repairLegacyFunctionKeyOverride, config.system.repairLegacyFunctionKeyOverride,
                   !state.session.appliedMode, !state.session.desiredMode, !state.session.isBusy {
                    effects.append(.send(.retryRecovery))
                }
                if previousConfig.receivesBetaUpdates != config.receivesBetaUpdates { effects.append(.run { _ in await platform.command(.resetUpdateCycle) }) }
                if previousConfig.hotkeys != config.hotkeys, state.settings.recordingHotkeyID == nil {
                    effects.append(.run { _ in await platform.configureHotkeys(config.hotkeys) })
                }
                if previousConfig.mouse.isEnabled && !config.mouse.isEnabled { enqueue(.mouse(false), state: &state) }
                if previousConfig.inputGuardPolicy != config.inputGuardPolicy { enqueue(.inputGuard, state: &state) }
                var oldDisplay = previousConfig.display
                // Power preferences apply at activation, as before.
                oldDisplay.autoDisableLowPowerMode = config.display.autoDisableLowPowerMode
                oldDisplay.lowPowerModeBatteryThreshold = config.display.lowPowerModeBatteryThreshold
                if oldDisplay != config.display || previousConfig.monitoredApps != config.monitoredApps { enqueue(.display, state: &state) }
            }
            return .merge(effects)
        }
        .onChange(of: \.settings.recordingHotkeyID) { previous, state in
            guard previous != nil, state.settings.recordingHotkeyID == nil, !state.settings.isPreview, state.session.phase != .terminating else { return .none }
            return .run { [hotkeys = state.settings.config.hotkeys] _ in await platform.configureHotkeys(hotkeys) }
        }
        Reduce { state, action in
            var effects: [Effect<Action>] = []
            state.session.configurationIsValid = state.settings.configurationLoadError == nil
            if !state.session.recoveryReady || !state.session.desiredMode { state.pendingOperations = [] }
            if state.operation == nil, state.session.phase == .ready, state.session.appliedMode, state.session.desiredMode, !state.pendingOperations.isEmpty {
                effects.append(begin(state.pendingOperations.removeFirst(), state: &state))
            }
            var runtime = state.settings.runtime
            runtime.isGamingMode = state.session.appliedMode
            runtime.isTransitioning = state.session.isBusy
            runtime.recoveryRequired = state.session.recoveryMessage != nil
            runtime.recoveryMessage = state.session.recoveryMessage
            runtime.isMouseBoostApplied = state.mouse.mouseIsApplied
            runtime.sessionMouseBaselineSpeed = state.mouse.mouseBaseline
            if runtime != state.settings.runtime {
                state.settings.runtime = runtime
                effects.append(.send(.settings(.runtimeChanged)))
            }
            return .merge(effects)
        }
    }

    private func enqueue(_ operation: GameEngineClient.Operation, state: inout State) {
        #if !FEATURE_DISPLAYS
        guard operation != .display else { return }
        #endif
        guard state.session.recoveryReady, state.session.desiredMode else { return }
        if !state.pendingOperations.contains(operation) { state.pendingOperations.append(operation) }
    }

    private func begin(_ operation: GameEngineClient.Operation, state: inout State) -> Effect<Action> {
        state.operationSequence += 1
        let request = GameEngineClient.Request(id: state.operationSequence, operation: operation)
        state.operation = request
        state.session.settingsAreChanging = true
        return .run { send in
            await engine.execute(request) { response in send(.operationFinished(request, response)) }
        }
    }
}
