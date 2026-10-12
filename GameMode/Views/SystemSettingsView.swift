//
//  SystemSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct SystemSettingsView: View {
    @ObservedObject var configStore: ConfigStore
    var onForceRestore: (() -> Void)?
    var onResetAllSavedData: (() -> Void)?
    var onAcceptCurrentSettings: (() -> Void)?
    @State private var confirmingReset = false
    @State private var confirmingCurrentSettings = false

    private var settingsLocked: Bool {
        configStore.isTransitioning || configStore.recoveryRequired || configStore.configurationLoadError != nil
    }

    private var modeStatus: String {
        if configStore.recoveryRequired { return "Recovery required" }
        if configStore.isTransitioning { return "Updating settings…" }
        return configStore.isGamingMode ? "Enabled" : "Disabled"
    }

    var body: some View {
        Form {
            if let error = configStore.configurationLoadError {
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
                LabeledContent("Configuration", value: configStore.configurationLoadError == nil ? "Loaded" : "Needs attention")
            }

            Section {
                LabeledContent("Accessibility", value: configStore.isAccessibilityGranted ? "Granted" : "Not granted")
                if !configStore.isAccessibilityGranted {
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
                if configStore.recoveryRequired || configStore.recoveryMessage != nil {
                    Label(configStore.recoveryMessage ?? "Recovery must finish before Game Mode can start.", systemImage: configStore.recoveryRequired ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(configStore.recoveryRequired ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                } else {
                    LabeledContent("Status", value: "No recovery required")
                }
                if configStore.recoveryRequired {
                    Button("Retry Recovery") { onForceRestore?() }
                        .disabled(configStore.isTransitioning)
                    Button("Use Current Settings as Normal…", role: .destructive) {
                        confirmingCurrentSettings = true
                    }
                    .disabled(configStore.isTransitioning)
                } else {
                    Button("Restore Saved Settings") { onForceRestore?() }
                        .disabled(configStore.isTransitioning)
                }

                Group {
                    Toggle("Restore before shutdown or restart", isOn: $configStore.config.system.restoreOnShutdown)
                    Toggle("Recover interrupted sessions on launch", isOn: $configStore.config.system.restoreOnLaunch)
                }
                .disabled(settingsLocked)

                LabeledContent("Recovery journal") {
                    Text("~/Library/Application Support/GameMode/manifest.json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Recovery")
            } footer: {
                Text("GameMode saves your normal settings before applying changes. After an interrupted session, recovery uses those saved values before a new session can begin.")
            }

            DiagnosticsSettingsSection(configStore: configStore)

            Section {
                DisclosureGroup("Display Compatibility") {
                    Group {
                        Toggle("Prefer fixed modes on built-in displays", isOn: $configStore.config.display.preferExactModeSwitching)
                        Toggle("Use ProMotion fallback when needed", isOn: $configStore.config.display.allowOverlayFallback)
                    }
                    .disabled(settingsLocked || !configStore.config.display.isRefreshRateLockEnabled)
                    Text("The fallback keeps a built-in ProMotion display active when a fixed refresh rate is unavailable. Its effectiveness depends on macOS and the display.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Reset Saved Configuration…", role: .destructive) { confirmingReset = true }
                    .disabled(configStore.isTransitioning || configStore.recoveryRequired || configStore.isGamingMode)
            } header: {
                Text("Advanced")
            } footer: {
                Text("Returns application preferences to their defaults. Turn off Game Mode and finish recovery before resetting.")
            }
        }
        .formStyle(.grouped)
        .alert("Use current settings as normal?", isPresented: $confirmingCurrentSettings) {
            Button("Cancel", role: .cancel) {}
            Button("Use Current Settings", role: .destructive) { onAcceptCurrentSettings?() }
        } message: {
            Text("First set your preferred normal keyboard, mouse, and system settings in macOS. This accepts the current settings as your normal configuration and ends recovery. The previous saved values will no longer be used for automatic recovery.")
        }
        .alert("Reset saved configuration?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Configuration", role: .destructive) { onResetAllSavedData?() }
        } message: {
            Text("This resets monitored applications, shortcuts, presets, and other GameMode preferences. Your current macOS settings will not be changed.")
        }
    }

    private var permissionButton: some View {
        Button("Request Permission") {
            guard !configStore.isPreview else { return }
            HotkeyManager.requestAccessibilityPermission()
        }
    }

    private var accessibilitySettingsButton: some View {
        Button("Open System Settings") {
            guard !configStore.isPreview else { return }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
