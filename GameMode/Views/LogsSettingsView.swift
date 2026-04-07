//
//  LogsSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 23/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct LogsSettingsView: View {
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        Form {
            Section {
                Toggle("Enable logging", isOn: $configStore.config.loggingEnabled)
            } header: {
                Text("Logging")
            } footer: {
                Text("When enabled, diagnostic messages are written to the unified log (visible in Console.app).")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Minimum log level", selection: $configStore.config.logLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!configStore.config.loggingEnabled)
            } header: {
                Text("Log Level")
            } footer: {
                Text("Messages below this level are suppressed. In debug builds, all levels are shown regardless of this setting.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Open Console.app") {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
                    )
                }
            } footer: {
                Text("Filter by process \"GameMode\" in Console.app to see logs.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
