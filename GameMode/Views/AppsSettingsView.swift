//
//  AppsSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import SwiftUI

struct AppsSettingsView: View {
    @Bindable var store: StoreOf<AppSettings>
    private var isScanning: Bool { store.scanID != nil }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Button("Add App…") { store.send(.addAppButtonTapped) }
                    Button(isScanning ? "Scanning…" : "Scan for Games") { store.send(.scanButtonTapped) }
                        .disabled(isScanning)
                    if isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Scanning for games")
                    }
                }
            } header: {
                Text("Activation")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Game Mode activates when an enabled application launches and restores your settings after the last enabled application quits.")
                    if let summary = store.scanSummary {
                        Text(summary)
                    }
                }
            }

            if store.config.monitoredApps.isEmpty {
                Section {
                    ContentUnavailableView("No Applications", systemImage: "app.dashed", description: Text("Add an application to enable Game Mode automatically when it launches."))
                }
            }
            ForEach(groupedSources, id: \.title) { group in
                if !group.apps.isEmpty {
                    Section(group.title) {
                        ForEach(group.apps) { app in
                            appRow(app)
                        }
                    }
                }
            }

            if !store.config.monitoredApps.isEmpty {
                Section {
                    DisclosureGroup("Application Details") {
                        ForEach(store.config.monitoredApps) { app in
                            LabeledContent(app.name) {
                                Text(app.bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func appRow(_ app: MonitoredApp) -> some View {
        HStack {
            let binding = Binding<Bool>(
                get: {
                    store.config.monitoredApps
                        .first(where: { $0.id == app.id })?.isEnabled ?? false
                },
                set: { store.send(.appEnabledChanged(app.id, $0)) }
            )
            Toggle(app.name, isOn: binding)
                .help(app.bundleID)

            if app.source != .preset {
                Spacer()
                Button(role: .destructive) {
                    store.send(.removeApp(app.id))
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(app.name)")
                .help("Remove \(app.name)")
            }
        }
    }

    private struct AppGroup {
        let title: String
        let apps: [MonitoredApp]
    }

    private var groupedSources: [AppGroup] {
        let apps = store.config.monitoredApps
        return [
            AppGroup(title: "Presets", apps: apps.filter { $0.source == .preset }),
            AppGroup(title: "Detected Games", apps: apps.filter { $0.source == .detected }),
            AppGroup(title: "Custom", apps: apps.filter { $0.source == .manual }),
        ]
    }
}
