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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Accessibility Permission
                Text("Accessibility Permission")
                    .font(.headline)

                HStack(spacing: 8) {
                    Circle()
                        .fill(configStore.isAccessibilityGranted ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(configStore.isAccessibilityGranted ? "Granted" : "Not Granted")
                        .foregroundColor(configStore.isAccessibilityGranted ? .green : .red)
                }

                if !configStore.isAccessibilityGranted {
                    Text("Accessibility access is required for global hotkeys and gesture control. Without it, keyboard shortcuts will only work when the app is focused.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("How to enable:")
                            .font(.caption)
                            .bold()
                        Text("1. Click \"Open System Settings\" below")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("2. Find GameMode in the list")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("3. Toggle the switch next to it")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("4. If not listed, click \"+\" and add GameMode.app")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

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
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Shutdown Protection
                Text("Shutdown Protection")
                    .font(.headline)

                Toggle("Restore settings on shutdown / restart",
                       isOn: $configStore.config.system.restoreOnShutdown)

                Text("Deactivates gaming mode before macOS shuts down, so your system starts clean.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                // Crash Recovery
                Text("Crash Recovery")
                    .font(.headline)

                Toggle("Auto-restore on launch",
                       isOn: $configStore.config.system.restoreOnLaunch)

                Text("If the app was killed or the Mac was force-rebooted while gaming mode was active, restore all settings on next launch.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                // State
                Text("State")
                    .font(.headline)

                HStack {
                    Text("Gaming mode:")
                    Text(configStore.isGamingMode ? "Active" : (StateJournal.hasDirtyState ? "Active (stale)" : "Inactive"))
                        .foregroundColor(configStore.isGamingMode ? .green : (StateJournal.hasDirtyState ? .orange : .secondary))
                }

                HStack {
                    Text("State file:")
                    Text("~/Library/Application Support/GameMode/state.json")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Divider()

                Button("Force Restore All Settings") {
                    onForceRestore?()
                }

                Text("Emergency button: reads the state journal and restores every setting to pre-gaming values. Use if something feels stuck.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }
}
