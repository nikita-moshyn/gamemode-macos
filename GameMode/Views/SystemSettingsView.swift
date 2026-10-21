//
//  SystemSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import SwiftUI

struct SystemSettingsView: View {
    @Bindable var store: StoreOf<AppSettings>

    private var modeStatus: String {
        if store.runtime.recoveryRequired { return "Recovery required" }
        if store.runtime.isTransitioning { return "Updating settings…" }
        return store.runtime.isGamingMode ? "Enabled" : "Disabled"
    }

    var body: some View { systemForm }

    private var systemForm: some View {
        Form {
            if let error = store.persistenceError {
                Section("Changes Not Saved") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Text("Your last saved preferences are still in use. Try the change again.")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = store.configurationLoadError {
                Section("Configuration Needs Attention") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Text("Your saved configuration has been preserved. Resolve the problem before changing preferences, or reset your saved configuration below.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Engine") {
                LabeledContent("Game Mode", value: modeStatus)
                LabeledContent("Configuration", value: store.configurationLoadError == nil ? "Loaded" : "Needs attention")
            }

            Section {
                LabeledContent("Accessibility", value: store.runtime.isAccessibilityGranted ? "Granted" : "Not granted")
                if !store.runtime.isAccessibilityGranted {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            permissionButton
                            accessibilitySettingsButton
                        }
                        VStack(alignment: .leading) {
                            permissionButton
                            accessibilitySettingsButton
                        }
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Accessibility access allows Input Guard and global hotkeys to work while another app is focused.")
            }

            RecoverySettingsSection(store: store)

            DiagnosticsSettingsSection(store: store)

            Section {
                Button("Reset Saved Configuration…", role: .destructive) { store.send(.confirmationRequested(.resetConfiguration)) }
                    .disabled(store.runtime.isTransitioning || store.runtime.recoveryRequired || store.runtime.isGamingMode)
            } header: {
                Text("Advanced")
            } footer: {
                Text("Returns application preferences to their defaults. Turn off Game Mode and finish recovery before resetting.")
            }
        }
        .formStyle(.grouped)
    }

    private var permissionButton: some View {
        Button("Request Permission") {
            store.send(.command(.requestAccessibility))
        }
    }

    private var accessibilitySettingsButton: some View {
        Button("Open System Settings") {
            store.send(.command(.accessibilitySettings))
        }
    }
}
