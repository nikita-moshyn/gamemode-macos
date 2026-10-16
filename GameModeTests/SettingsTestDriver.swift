//
//  SettingsTestDriver.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Combine
import ComposableArchitecture
import Foundation
@testable import GameMode

/// Test convenience for preference and rendered-view fixtures.
/// Production uses the root store directly.
final class SettingsTestDriver {

    let settingsStore: StoreOf<AppSettings>
    var settings: AppSettings.State { settingsStore.state }

    var config: GameModeConfig {
        get { settings.config }
        set { settingsStore.send(.configurationEdited(newValue)) }
    }

    var configPublisher: AnyPublisher<GameModeConfig, Never> {
        settingsStore.publisher.map(\.config).removeDuplicates().eraseToAnyPublisher()
    }

    var configurationLoadError: String? { settings.configurationLoadError }
    var configurationLoadErrorPublisher: AnyPublisher<String?, Never> {
        settingsStore.publisher.map(\.configurationLoadError).removeDuplicates().eraseToAnyPublisher()
    }
    var canChangeMode: Bool { settings.canEdit }
    var isFirstLaunch: Bool { !settings.hasSavedConfiguration }

    // Runtime setup never saves preferences.
    var isGamingMode: Bool {
        get { settings.runtime.isGamingMode }
        set { updateRuntime(\.isGamingMode, to: newValue) }
    }
    var isMouseBoostApplied: Bool {
        get { settings.runtime.isMouseBoostApplied }
        set { updateRuntime(\.isMouseBoostApplied, to: newValue) }
    }
    var sessionMouseBaselineSpeed: Double? {
        get { settings.runtime.sessionMouseBaselineSpeed }
        set { updateRuntime(\.sessionMouseBaselineSpeed, to: newValue) }
    }
    var isTransitioning: Bool {
        get { settings.runtime.isTransitioning }
        set { updateRuntime(\.isTransitioning, to: newValue) }
    }
    var recoveryRequired: Bool {
        get { settings.runtime.recoveryRequired }
        set { updateRuntime(\.recoveryRequired, to: newValue) }
    }
    var recoveryMessage: String? {
        get { settings.runtime.recoveryMessage }
        set { updateRuntime(\.recoveryMessage, to: newValue) }
    }

    // Permission state can be supplied without reading the host computer.
    var isAccessibilityGranted: Bool {
        get { settings.runtime.isAccessibilityGranted }
        set { updateRuntime(\.isAccessibilityGranted, to: newValue) }
    }
    let isPreview: Bool
    let preferences: UserDefaults

    init(defaults: UserDefaults, key: String = "GameModeConfig_v2", isPreview: Bool = false, shortcutDetector: (@Sendable () -> [ShortcutEntry])? = nil, settingsClient: SettingsClient? = nil, viewClient: SettingsViewClient? = nil) {
        self.preferences = defaults
        self.isPreview = isPreview
        let client = settingsClient ?? .preferences(defaults, key: key, detectShortcuts: shortcutDetector ?? {
            isPreview ? [] : AppDetector.detectAvailableShortcuts()
        })
        var initialState = client.load()
        initialState.isPreview = isPreview
        settingsStore = Store(initialState: initialState) { AppSettings() } withDependencies: {
            $0.settingsClient = client
            $0.settingsViewClient = viewClient ?? .previewValue
        }
    }

    func updateSession(_ session: GameSession.State) {
        var runtime = settings.runtime
        runtime.isGamingMode = session.appliedMode
        runtime.isTransitioning = session.isBusy
        runtime.recoveryRequired = session.recoveryMessage != nil
        runtime.recoveryMessage = session.recoveryMessage ?? "No settings are waiting for recovery."
        // Configuration validity also notifies the session store. Its unchanged
        // presentation must not feed back into an in-flight settings action.
        guard runtime != settings.runtime else { return }
        settingsStore.send(.runtimeUpdated(runtime))
    }

    private func updateRuntime<Value>(_ keyPath: WritableKeyPath<AppSettings.Runtime, Value>, to value: Value) {
        var runtime = settings.runtime
        runtime[keyPath: keyPath] = value
        settingsStore.send(.runtimeUpdated(runtime))
    }

    func save() { settingsStore.send(.save) }

    /// Preference-only fixture action; journal ordering is tested by GameModeFeatureTests.
    func resetAllSavedData() { settingsStore.send(.resetAfterRecovery) }

    func addApp(_ app: MonitoredApp) { settingsStore.send(.addApp(app)) }
    func removeApp(id: UUID) { settingsStore.send(.removeApp(id)) }
    func toggleApp(id: UUID) { settingsStore.send(.toggleApp(id)) }
    func toggleAppRefreshRateLock(id: UUID) { settingsStore.send(.toggleAppRefreshRateLock(id)) }
    func setManagedDisplay(id: String, name: String, isEnabled: Bool) { settingsStore.send(.managedDisplayChanged(id: id, name: name, isEnabled: isEnabled)) }
    func refreshDetectedShortcuts() { settingsStore.send(.refreshShortcuts) }
    func mergeDetectedShortcuts(_ detected: [ShortcutEntry]) { settingsStore.send(.mergeShortcuts(detected)) }
    func toggleShortcut(id: Int) { settingsStore.send(.toggleShortcut(id)) }
    func toggleGesture(id: String) { settingsStore.send(.toggleGesture(id)) }
    func updateHotkey(id: String, keyCode: UInt16?, modifiers: UInt) { settingsStore.send(.updateHotkey(id: id, keyCode: keyCode, modifiers: modifiers)) }
    func toggleHotkey(id: String) { settingsStore.send(.toggleHotkey(id)) }

}
