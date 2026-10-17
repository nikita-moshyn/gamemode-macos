//
//  LogsSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import SwiftUI

/// A section of System settings, so diagnostics share the parent form's scrolling.
struct DiagnosticsSettingsSection: View {
    @Bindable var store: StoreOf<AppSettings>

    private var settingsLocked: Bool {
        store.runtime.isTransitioning || store.runtime.recoveryRequired || store.configurationLoadError != nil
    }

    var body: some View {
        Section {
            Toggle("Enable logging", isOn: $store.config.loggingEnabled)
                .disabled(settingsLocked)

            Picker("Minimum log level", selection: $store.config.logLevel) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .disabled(settingsLocked || !store.config.loggingEnabled)

            Button("Open Console.app") {
                store.send(.command(.console))
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("When enabled, diagnostic messages are written to the unified log. Open Console and filter by process \"GameMode\" to see them. Messages below the selected level are suppressed; debug builds show all levels.")
                .foregroundStyle(.secondary)
        }
    }
}
