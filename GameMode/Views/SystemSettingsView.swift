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

    private var settingsLocked: Bool {
        store.runtime.isTransitioning || store.runtime.recoveryRequired || store.configurationLoadError != nil
    }

    private var modeStatus: String {
        if store.runtime.recoveryRequired { return "Recovery required" }
        if store.runtime.isTransitioning { return "Updating settings…" }
        return store.runtime.isGamingMode ? "Enabled" : "Disabled"
    }

    var body: some View {
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

            Section {
                if store.runtime.recoveryRequired || store.runtime.recoveryMessage != nil {
                    Label(store.runtime.recoveryMessage ?? "Recovery must finish before Game Mode can start.", systemImage: store.runtime.recoveryRequired ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(store.runtime.recoveryRequired ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                } else {
                    LabeledContent("Status", value: "No recovery required")
                }
                if store.runtime.recoveryRequired {
                    Button("Retry Recovery") { store.send(.retryRecovery) }
                        .disabled(store.runtime.isTransitioning)
                    Button("Use Current Settings as Normal…", role: .destructive) {
                        store.send(.confirmationRequested(.acceptCurrentSettings))
                    }
                    .disabled(store.runtime.isTransitioning)
                } else {
                    Button("Restore Saved Settings") { store.send(.retryRecovery) }
                        .disabled(store.runtime.isTransitioning)
                }

                Group {
                    Toggle("Restore before shutdown or restart", isOn: $store.config.system.restoreOnShutdown)
                    Toggle("Recover interrupted sessions on launch", isOn: $store.config.system.restoreOnLaunch)
                }
                .disabled(settingsLocked)

                DisclosureGroup("Recovery Details") {
                    Text("Recovery journal")
                    Text("~/Library/Application Support/GameMode/manifest.json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Recovery")
            } footer: {
                Text("GameMode saves your normal settings before applying changes. After an interrupted session, recovery uses those saved values before a new session can begin.")
            }

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
        .alert("Use current settings as normal?", isPresented: confirmationBinding(.acceptCurrentSettings)) {
            Button("Cancel", role: .cancel) {}
            Button("Use Current Settings", role: .destructive) {
                guard store.canAcceptCurrentSettings else { return }
                store.send(.confirmationDismissed(.acceptCurrentSettings))
                store.send(.acceptCurrentSettings)
            }
        } message: {
            Text("First set your preferred normal keyboard, mouse, and system settings in macOS. This accepts the current settings as your normal configuration and ends recovery. The previous saved values will no longer be used for automatic recovery.")
        }
        .alert("Reset saved configuration?", isPresented: confirmationBinding(.resetConfiguration)) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Configuration", role: .destructive) {
                guard store.canResetConfiguration else { return }
                store.send(.confirmationDismissed(.resetConfiguration))
                store.send(.resetConfiguration)
            }
        } message: {
            Text("This resets monitored applications, shortcuts, presets, and other GameMode preferences. Your current macOS settings will not be changed.")
        }
    }

    private func confirmationBinding(_ confirmation: AppSettings.Confirmation) -> Binding<Bool> {
        Binding(get: { store.confirmation == confirmation }, set: { if !$0 { store.send(.confirmationDismissed(confirmation)) } })
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
