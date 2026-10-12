//
//  LogsSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 10/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

/// A section of System settings, so diagnostics share the parent form's scrolling.
struct DiagnosticsSettingsSection: View {
    @ObservedObject var configStore: ConfigStore

    private var settingsLocked: Bool {
        configStore.isTransitioning || configStore.recoveryRequired || configStore.configurationLoadError != nil
    }

    var body: some View {
        Section {
            Toggle("Enable logging", isOn: $configStore.config.loggingEnabled)
                .disabled(settingsLocked)

            Picker("Minimum log level", selection: $configStore.config.logLevel) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .disabled(settingsLocked || !configStore.config.loggingEnabled)

            Button("Open Console.app") {
                guard !configStore.isPreview else { return }
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("When enabled, diagnostic messages are written to the unified log. Open Console and filter by process \"GameMode\" to see them. Messages below the selected level are suppressed; debug builds show all levels.")
                .foregroundStyle(.secondary)
        }
    }
}
