//
//  AppSettings.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import Foundation

/// Owns saved preferences. Session status is a projection of GameSession;
/// restoring system settings and committing the recovery journal stay with the engine.
@Reducer
struct AppSettings {
    struct Runtime: Equatable {
        var isGamingMode = false
        var isMouseBoostApplied = false
        var sessionMouseBaselineSpeed: Double?
        var isTransitioning = false
        var recoveryRequired = false
        var recoveryMessage: String?
        var isAccessibilityGranted = false
    }

    @ObservableState
    struct State: Equatable {
        var config: GameModeConfig = .defaults
        var configurationLoadError: String?
        var persistenceError: String?
        var hasSavedConfiguration = false
        var runtime = Runtime()
        var isPreview = false
        var recordingHotkeyID: String?
        var selectedSection: SettingsSection = .general
        var backHistory: [SettingsLocation] = []
        var forwardHistory: [SettingsLocation] = []
        var confirmation: Confirmation?
        @Presents var appPicker: ApplicationPicker.State?
        var scanID: UUID?
        var scanSummary: String?
        var displayStatus = SettingsDisplayStatus()
        var recoveryStatus = RecoveryStatus()
        var recoveryKitPath: String?
        var recoveryToolError: String?
        var recoveryPageIsPresented = false
        var recoveryDocument: RecoveryBackup?
        var importedRecovery: RecoveryBackup?
        var importedRecoveryName: String?
        var selectedRecoverySettings: Set<RecoveryBackup.Setting> = []
        var recoveryNotice: String?
        var loginStatus: LoginItemStatus = .notRegistered
        var loginError: String?
        var isUpdatingLoginItem = false

        var navigationDestination: SettingsDestination? {
            if selectedSection == .system, recoveryPageIsPresented { return .recovery }
            if selectedSection == .applications, appPicker != nil { return .addApplications }
            return nil
        }

        var navigationTitle: String { navigationDestination?.title ?? selectedSection.title }

        var navigationLocation: SettingsLocation {
            switch navigationDestination {
            case .recovery: .recovery
            case .addApplications: .addApplications
            case nil: .section(selectedSection)
            }
        }

        func canVisit(_ location: SettingsLocation) -> Bool {
            SettingsSection.availableCases.contains(location.section) && (location != .addApplications || canEdit)
        }

        var canNavigateBack: Bool {
            navigationDestination != nil || backHistory.contains { $0 != navigationLocation && canVisit($0) }
        }

        var canNavigateForward: Bool {
            forwardHistory.contains { $0 != navigationLocation && canVisit($0) }
        }

        var canEdit: Bool {
            configurationLoadError == nil && !runtime.isTransitioning && !runtime.recoveryRequired
        }
        var canResetConfiguration: Bool { !runtime.isTransitioning && !runtime.recoveryRequired && !runtime.isGamingMode }
        var canAcceptCurrentSettings: Bool { !runtime.isTransitioning && runtime.recoveryRequired }
    }

    enum Confirmation: Equatable { case resetConfiguration, acceptCurrentSettings }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// Atomic configuration replacement for import and persistence tests.
        case configurationEdited(GameModeConfig)
        case runtimeUpdated(Runtime)
        case runtimeChanged
        case save
        /// The root sends this only after journaled recovery and reset succeed.
        case resetAfterRecovery
        case addApp(MonitoredApp)
        case removeApp(UUID)
        case toggleApp(UUID)
        case toggleAppRefreshRateLock(UUID)
        case managedDisplayChanged(id: String, name: String, isEnabled: Bool)
        case refreshShortcuts
        case mergeShortcuts([ShortcutEntry])
        case toggleShortcut(Int)
        case toggleGesture(String)
        case updateHotkey(id: String, keyCode: UInt16?, modifiers: UInt)
        case toggleHotkey(String)
        case restoreDefaultHotkeys
        case seedConfiguration([MonitoredApp])
        case command(AppPlatformClient.Command)
        case applyMouse, retryRecovery, acceptCurrentSettings, resetConfiguration
        case recordHotkey(String)
        case recordedHotkey(String, ShortcutRecordingClient.Key?)
        case stopRecording
        case settingsOpened
        case sectionSelected(SettingsSection?)
        case confirmationRequested(Confirmation)
        case confirmationDismissed(Confirmation)
        case addAppButtonTapped
        case appPicker(PresentationAction<ApplicationPicker.Action>)
        case scanButtonTapped
        case scanFinished(UUID, [MonitoredApp])
        case appEnabledChanged(UUID, Bool)
        case appRefreshRateLockChanged(UUID, Bool)
        case shortcutSelectionChanged(Int, Bool)
        case gestureSelectionChanged(String, Bool)
        case hotkeyEnabledChanged(String, Bool)
        case displayStatusRequested
        case displayStatusLoaded(SettingsDisplayStatus)
        case loginStatusRequested
        case loginStatusLoaded(LoginItemStatus)
        case launchAtLoginChanged(Bool)
        case loginItemUpdateFinished(Result<LoginItemStatus, Error>)
        case recoveryStatusRequested, recoveryStatusLoaded(RecoveryStatus)
        case openRecoverySettings
        case navigationBackRequested, navigationForwardRequested
        case restoreNormalSettings, removeFunctionKeyOverride(FunctionKeyPreferences), exportRecoveryKit
        case recoveryPageOpened, recoveryPageClosed, importRecoveryFile, restoreRecoveryFile, discardRecoveryFile
        case recoveryFileLoaded(Result<RecoveryBackup, Error>, String)
        case recoverySettingSelected(RecoveryBackup.Setting, Bool)
    }

    @Dependency(\.settingsClient) var client
    @Dependency(\.settingsViewClient) var viewClient
    @Dependency(\.uuid) var uuid
    @Dependency(\.shortcutRecording) var shortcutRecording
    @Dependency(\.appPlatform) var platform

    private enum CancelID { case scan, displayStatus, recording }

    var body: some ReducerOf<Self> {
        BindingReducer()
            .onChange(of: \.config) { previous, state in
                let edited = state.config
                // Complete validation and persistence in the same reduction,
                // before the store publishes anything to the live engine.
                state.config = previous
                guard state.canEdit else { return .none }
                persist(edited, into: &state)
                return .none
            }
        Reduce { state, action in
            var config = state.config
            switch action {
            case .seedConfiguration(let apps):
                guard !state.hasSavedConfiguration, state.configurationLoadError == nil else { return .none }
                merge(client.detectShortcuts(), into: &config)
                var known = Set(config.monitoredApps.map(\.bundleID))
                config.monitoredApps.append(contentsOf: apps.filter { known.insert($0.bundleID).inserted })
                persist(config, into: &state)
                return .none
            case .restoreNormalSettings, .removeFunctionKeyOverride, .exportRecoveryKit, .restoreRecoveryFile:
                return .none
            case .navigationBackRequested:
                return traverseHistory(backwards: true, state: &state)
            case .navigationForwardRequested:
                return traverseHistory(backwards: false, state: &state)
            case .recoveryPageOpened:
                return visit(.recovery, state: &state)
            case .recoveryPageClosed:
                guard state.navigationDestination == .recovery else { return .none }
                return traverseHistory(backwards: true, state: &state)
            case .appPicker(.dismiss):
                guard state.navigationDestination == .addApplications else { return .none }
                return traverseHistory(backwards: true, state: &state)
            case .importRecoveryFile:
                guard !state.runtime.isTransitioning else { return .none }
                return .run { send in
                    guard let url = await viewClient.chooseRecoveryFile() else { return }
                    await send(.recoveryFileLoaded(Result { try viewClient.readRecoveryFile(url) }, url.lastPathComponent))
                }
            case let .recoveryFileLoaded(result, name):
                guard state.recoveryPageIsPresented, !state.runtime.isTransitioning else { return .none }
                switch result {
                case .success(let backup):
                    state.importedRecovery = backup
                    state.importedRecoveryName = name
                    state.selectedRecoverySettings = backup.settings
                    state.recoveryToolError = nil
                    state.recoveryNotice = nil
                case .failure(let error): state.recoveryToolError = error.localizedDescription
                }
                return .none
            case .recoverySettingSelected(let setting, let selected):
                guard !state.runtime.isTransitioning, state.importedRecovery?.settings.contains(setting) == true else { return .none }
                if selected { state.selectedRecoverySettings.insert(setting) }
                else { state.selectedRecoverySettings.remove(setting) }
                return .none
            case .discardRecoveryFile:
                state.importedRecovery = nil
                state.importedRecoveryName = nil
                state.recoveryToolError = nil
                return .none
            case .recoveryStatusRequested:
                return .run { send in await send(.recoveryStatusLoaded(viewClient.recoveryStatus())) }
            case .recoveryStatusLoaded(let status):
                state.recoveryStatus = status
                return .none
            case .openRecoverySettings:
                return .run { _ in await viewClient.openRecoverySettings() }
            case .command, .applyMouse, .retryRecovery, .acceptCurrentSettings, .resetConfiguration:
                return .none
            case .recordHotkey(let id):
                guard state.canEdit, config.hotkeys.contains(where: { $0.id == id }) else { return .none }
                if state.recordingHotkeyID == id {
                    state.recordingHotkeyID = nil
                    return .cancel(id: CancelID.recording)
                }
                state.recordingHotkeyID = id
                return .run { [preview = state.isPreview] send in
                    guard !Task.isCancelled else { return }
                    if !preview { await platform.configureHotkeys([]) }
                    guard !Task.isCancelled else { return }
                    var recorded: ShortcutRecordingClient.Key?
                    for await key in await shortcutRecording.events() { recorded = key; break }
                    guard !Task.isCancelled else { return }
                    await send(.recordedHotkey(id, recorded))
                }.cancellable(id: CancelID.recording, cancelInFlight: true)
            case .restoreDefaultHotkeys:
                guard state.canEdit else { return .none }
                state.recordingHotkeyID = nil
                config.hotkeys = AppHotkey.defaults
                if config != state.config { persist(config, into: &state) }
                return .cancel(id: CancelID.recording)
            case let .recordedHotkey(id, key):
                guard state.recordingHotkeyID == id else { return .none }
                state.recordingHotkeyID = nil
                guard state.canEdit, let key, let index = config.hotkeys.firstIndex(where: { $0.id == id }) else { return .none }
                config.hotkeys[index].keyCode = key.code
                config.hotkeys[index].modifiers = key.modifiers
            case .stopRecording:
                state.recordingHotkeyID = nil
                return .cancel(id: CancelID.recording)
            case .settingsOpened:
                client.saveSelectedSection(state.selectedSection)
                return state.selectedSection == .shortcuts ? .run { send in await send(.refreshShortcuts) } : .none
            case .sectionSelected(let section):
                guard let section else { return .none }
                return visit(.section(section), state: &state)
            case .confirmationRequested(let confirmation):
                guard confirmation == .resetConfiguration ? state.canResetConfiguration : state.canAcceptCurrentSettings else { return .none }
                state.confirmation = confirmation
                return .none
            case .confirmationDismissed(let confirmation):
                guard state.confirmation == confirmation else { return .none }
                state.confirmation = nil
                return .none
            case .addAppButtonTapped:
                guard state.canEdit else { return .none }
                return visit(.addApplications, state: &state)
            case let .appPicker(.presented(.delegate(.addApplication(app, clearManualEntry)))):
                guard state.canEdit, state.appPicker != nil else { return .none }
                guard !config.monitoredApps.contains(where: { $0.bundleID == app.bundleID }) else {
                    state.appPicker?.feedback = "\(app.name) has already been added."
                    return .none
                }
                config.monitoredApps.append(MonitoredApp(id: uuid(), bundleID: app.bundleID, name: app.name, isEnabled: true, source: .manual))
                persist(config, into: &state)
                if let error = state.persistenceError { state.appPicker?.feedback = error }
                else {
                    state.appPicker?.feedback = "Added \(app.name)."
                    if clearManualEntry { state.appPicker?.manualBundleID = "" }
                }
                return .none
            case .appPicker:
                return .none
            case .scanButtonTapped:
                guard state.canEdit, state.scanID == nil else { return .none }
                let id = uuid()
                state.scanID = id
                state.scanSummary = nil
                return .run { send in
                    let apps = await viewClient.scanGames()
                    guard !Task.isCancelled else { return }
                    await send(.scanFinished(id, apps))
                }.cancellable(id: CancelID.scan, cancelInFlight: true)
            case let .scanFinished(id, apps):
                guard state.scanID == id else { return .none }
                state.scanID = nil
                guard state.canEdit else { return .none }
                var knownIDs = Set(config.monitoredApps.map(\.bundleID))
                let added = apps.filter { knownIDs.insert($0.bundleID).inserted }
                if !added.isEmpty {
                    config.monitoredApps.append(contentsOf: added)
                    persist(config, into: &state)
                    guard state.persistenceError == nil else {
                        state.scanSummary = "Scan complete. The detected applications could not be saved. Try again."
                        return .none
                    }
                }
                state.scanSummary = added.isEmpty ? "Scan complete. No new games found." : "Scan complete. Added \(added.count) \(added.count == 1 ? "application" : "applications")."
                return .none
            case .displayStatusRequested:
                return .run { send in await send(.displayStatusLoaded(viewClient.displayStatus())) }
                    .cancellable(id: CancelID.displayStatus, cancelInFlight: true)
            case .displayStatusLoaded(let status):
                state.displayStatus = status
                return .none
            case .loginStatusRequested:
                return .run { send in await send(.loginStatusLoaded(viewClient.loginStatus())) }
            case .loginStatusLoaded(let status):
                state.loginStatus = status
                return .none
            case .launchAtLoginChanged(let enabled):
                guard state.canEdit, !state.isUpdatingLoginItem else { return .none }
                state.isUpdatingLoginItem = true
                return .run { send in
                    let result = await Result { try await viewClient.setLaunchAtLogin(enabled) }
                    await send(.loginItemUpdateFinished(result))
                }
            case .loginItemUpdateFinished(let result):
                state.isUpdatingLoginItem = false
                switch result {
                case .success(let status): state.loginStatus = status; state.loginError = nil
                case .failure(let error):
                    state.loginError = error.localizedDescription
                    return .run { send in await send(.loginStatusLoaded(viewClient.loginStatus())) }
                }
                return .none
            case .binding:
                return .none
            case .configurationEdited(let edited):
                guard state.canEdit else { return .none }
                config = edited
            case .runtimeUpdated(let runtime):
                state.runtime = runtime
                fallthrough
            case .runtimeChanged:
                if !state.canEdit {
                    state.appPicker = nil
                    if state.scanID != nil {
                        state.scanID = nil
                        state.scanSummary = "Scan stopped. Finish recovery or the current transition before adding applications."
                    }
                }
                if state.confirmation == .resetConfiguration, !state.canResetConfiguration { state.confirmation = nil }
                if state.confirmation == .acceptCurrentSettings, !state.canAcceptCurrentSettings { state.confirmation = nil }
                if !state.canEdit {
                    state.recordingHotkeyID = nil
                    return .merge(.cancel(id: CancelID.scan), .cancel(id: CancelID.recording))
                }
                return .none
            case .save:
                guard state.canEdit else { return .none }
                persist(config, into: &state)
                return .none
            case .resetAfterRecovery:
                state.appPicker = nil
                state.confirmation = nil
                state.scanID = nil
                state.scanSummary = nil
                let defaults = GameModeConfig.defaults
                do {
                    try client.reset(defaults, state.configurationLoadError != nil)
                    state.config = defaults
                    state.configurationLoadError = nil
                    state.persistenceError = nil
                    state.hasSavedConfiguration = true
                    state.runtime.isGamingMode = false
                    state.runtime.isMouseBoostApplied = false
                    state.runtime.sessionMouseBaselineSpeed = nil
                } catch {
                    state.persistenceError = error.localizedDescription
                }
                return .cancel(id: CancelID.scan)
            case .refreshShortcuts:
                guard state.configurationLoadError == nil else { return .none }
                merge(client.detectShortcuts(), into: &config)
            case .mergeShortcuts(let detected):
                guard state.configurationLoadError == nil else { return .none }
                merge(detected, into: &config)
            case .addApp(let app):
                guard state.canEdit, !config.monitoredApps.contains(where: { $0.bundleID == app.bundleID }) else { return .none }
                config.monitoredApps.append(app)
            case .removeApp(let id):
                guard state.canEdit else { return .none }
                config.monitoredApps.removeAll { $0.id == id }
            case .toggleApp(let id):
                guard state.canEdit, let index = config.monitoredApps.firstIndex(where: { $0.id == id }) else { return .none }
                config.monitoredApps[index].isEnabled.toggle()
            case .toggleAppRefreshRateLock(let id):
                guard state.canEdit, let index = config.monitoredApps.firstIndex(where: { $0.id == id }) else { return .none }
                config.monitoredApps[index].lockRefreshRate.toggle()
            case let .managedDisplayChanged(id, name, isEnabled):
                guard state.canEdit else { return .none }
                config.display.setDisplayEnabled(isEnabled, id: id, name: name)
            case .toggleShortcut(let id):
                guard state.canEdit, let index = config.shortcuts.firstIndex(where: { $0.id == id }) else { return .none }
                config.shortcuts[index].disableInGamingMode.toggle()
            case .toggleGesture(let id):
                guard state.canEdit, let index = config.gestures.firstIndex(where: { $0.id == id }) else { return .none }
                config.gestures[index].disableInGamingMode.toggle()
            case let .updateHotkey(id, keyCode, modifiers):
                guard state.canEdit, let index = config.hotkeys.firstIndex(where: { $0.id == id }) else { return .none }
                config.hotkeys[index].keyCode = keyCode
                config.hotkeys[index].modifiers = modifiers
            case .toggleHotkey(let id):
                guard state.canEdit, let index = config.hotkeys.firstIndex(where: { $0.id == id }) else { return .none }
                config.hotkeys[index].isEnabled.toggle()
            case let .appEnabledChanged(id, enabled):
                guard state.canEdit, let index = config.monitoredApps.firstIndex(where: { $0.id == id }) else { return .none }
                config.monitoredApps[index].isEnabled = enabled
            case let .appRefreshRateLockChanged(id, enabled):
                guard state.canEdit, let index = config.monitoredApps.firstIndex(where: { $0.id == id }) else { return .none }
                config.monitoredApps[index].lockRefreshRate = enabled
            case let .shortcutSelectionChanged(id, enabled):
                guard state.canEdit, let index = config.shortcuts.firstIndex(where: { $0.id == id }) else { return .none }
                config.shortcuts[index].disableInGamingMode = enabled
            case let .gestureSelectionChanged(id, enabled):
                guard state.canEdit, let index = config.gestures.firstIndex(where: { $0.id == id }) else { return .none }
                config.gestures[index].disableInGamingMode = enabled
            case let .hotkeyEnabledChanged(id, enabled):
                guard state.canEdit, let index = config.hotkeys.firstIndex(where: { $0.id == id }) else { return .none }
                config.hotkeys[index].isEnabled = enabled
            }
            if config != state.config { persist(config, into: &state) }
            return .none
        }
        .ifLet(\.$appPicker, action: \.appPicker) { ApplicationPicker() }
    }

    private func visit(_ location: SettingsLocation, state: inout State) -> Effect<Action> {
        guard state.canVisit(location), location != state.navigationLocation else { return .none }
        state.backHistory = Array((state.backHistory + [state.navigationLocation]).suffix(100))
        state.forwardHistory = []
        return show(location, state: &state)
    }

    private func traverseHistory(backwards: Bool, state: inout State) -> Effect<Action> {
        let current = state.navigationLocation
        var history = backwards ? state.backHistory : state.forwardHistory
        var destination: SettingsLocation?
        while let location = history.popLast() {
            if location != current, state.canVisit(location) { destination = location; break }
        }
        // A directly opened child page still has a parent even without history.
        if destination == nil, backwards, state.navigationDestination != nil { destination = .section(state.selectedSection) }
        guard let destination else { return .none }
        if backwards {
            state.backHistory = history
            state.forwardHistory = Array((state.forwardHistory + [current]).suffix(100))
        } else {
            state.forwardHistory = history
            state.backHistory = Array((state.backHistory + [current]).suffix(100))
        }
        let effect = show(destination, state: &state)
        // Re-entering Recovery refreshes its saved settings through the same engine.
        return destination == .recovery ? .merge(effect, .send(.recoveryPageOpened)) : effect
    }

    private func show(_ location: SettingsLocation, state: inout State) -> Effect<Action> {
        let changedSection = state.selectedSection != location.section
        state.selectedSection = location.section
        state.recoveryPageIsPresented = location == .recovery
        state.appPicker = location == .addApplications ? .init(existingIDs: Set(state.config.monitoredApps.map(\.bundleID))) : nil
        state.importedRecovery = nil
        state.importedRecoveryName = nil
        state.selectedRecoverySettings = []
        state.confirmation = nil
        if changedSection { client.saveSelectedSection(location.section) }
        // Sidebar selection can run inside SwiftUI's update transaction.
        // Discovery publishes preferences only after that transaction ends.
        return changedSection && location.section == .shortcuts ? .run { send in await send(.refreshShortcuts) } : .none
    }

    private func persist(_ config: GameModeConfig, into state: inout State) {
        // These small UserDefaults writes are synchronous, as before. Publish only
        // after saving so live observers cannot apply a rejected edit, and an older
        // asynchronous save cannot overwrite a later edit or completed reset.
        do {
            try client.save(config)
            state.config = config
            state.hasSavedConfiguration = true
            state.persistenceError = nil
            state.appPicker?.existingIDs = Set(config.monitoredApps.map(\.bundleID))
        } catch {
            state.persistenceError = error.localizedDescription
        }
    }

    private func merge(_ detected: [ShortcutEntry], into config: inout GameModeConfig) {
        var ids = Set(config.shortcuts.map(\.id))
        config.shortcuts.append(contentsOf: detected.filter { ids.insert($0.id).inserted }.map {
            ShortcutEntry(id: $0.id, name: $0.name, category: $0.category, disableInGamingMode: false)
        })
    }
}
