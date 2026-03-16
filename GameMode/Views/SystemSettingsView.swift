//
//  SystemSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2025 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct SystemSettingsView: View {
    @ObservedObject var configStore: ConfigStore
    var onForceRestore: (() -> Void)?

    var body: some View {
        Form {
            Section("Accessibility Permission") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(configStore.isAccessibilityGranted ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(configStore.isAccessibilityGranted ? "Granted" : "Not Granted")
                        .foregroundStyle(configStore.isAccessibilityGranted ? .green : .red)
                }

                if !configStore.isAccessibilityGranted {
                    Text("Accessibility access is required for global hotkeys and gesture control.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button("Request Permission") {
                            HotkeyManager.requestAccessibilityPermission()
                        }

                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                } else {
                    Text("GameMode can monitor global hotkeys and control system gestures.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Restore settings on shutdown / restart",
                       isOn: $configStore.config.system.restoreOnShutdown)
            } header: {
                Text("Shutdown Protection")
            } footer: {
                Text("Deactivates gaming mode before macOS shuts down, so your system starts clean.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Auto-restore on launch",
                       isOn: $configStore.config.system.restoreOnLaunch)
            } header: {
                Text("Crash Recovery")
            } footer: {
                Text("If the app was killed while gaming mode was active, restore all settings on next launch.")
                    .foregroundStyle(.secondary)
            }

            Section("State") {
                LabeledContent("Gaming mode") {
                    Text(configStore.isGamingMode ? "Active" : (StateJournal.hasDirtyState ? "Active (stale)" : "Inactive"))
                        .foregroundStyle(configStore.isGamingMode ? .green : (StateJournal.hasDirtyState ? .orange : .secondary))
                }

                LabeledContent("State file") {
                    Text("~/Library/Application Support/GameMode/state.json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section {
                Button("Force Restore All Settings", role: .destructive) {
                    onForceRestore?()
                }
            } footer: {
                Text("Emergency button: reads the state journal and restores every setting to pre-gaming values.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
