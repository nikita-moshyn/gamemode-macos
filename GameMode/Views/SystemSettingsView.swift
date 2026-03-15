//
//  SystemSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct SystemSettingsView: View {
    @ObservedObject var configStore: ConfigStore
    var onForceRestore: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                    Text(StateJournal.hasDirtyState ? "Active (stale)" : "Inactive")
                        .foregroundColor(StateJournal.hasDirtyState ? .orange : .secondary)
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
