//
//  AppsSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 10/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct AppsSettingsView: View {
    @ObservedObject var configStore: ConfigStore
    @State private var showingAddSheet = false
    @State private var isScanning = false
    @State private var scanSummary: String?

    var body: some View {
        Form {
            Section {
                Text("Game Mode activates when an enabled application launches and restores your settings after the last enabled application quits.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Activation")
            }

            if configStore.config.monitoredApps.isEmpty {
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

            Section {
                HStack(spacing: 12) {
                    Button("Add App") {
                        showingAddSheet = true
                    }

                    Button(isScanning ? "Scanning…" : "Scan for Games") { scanForGames() }
                        .disabled(isScanning)
                    if isScanning {
                        ProgressView().controlSize(.small)
                    }
                }
            } footer: {
                Text(scanSummary ?? "Add an application or scan for installed games. Turn on the applications that should activate Game Mode.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddSheet) {
            AppPickerSheet(configStore: configStore, isPresented: $showingAddSheet)
        }
    }

    private func appRow(_ app: MonitoredApp) -> some View {
        HStack {
            let binding = Binding<Bool>(
                get: {
                    configStore.config.monitoredApps
                        .first(where: { $0.id == app.id })?.isEnabled ?? false
                },
                set: { _ in
                    configStore.toggleApp(id: app.id)
                }
            )
            Toggle(isOn: binding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                    Text(app.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if app.source != .preset {
                Spacer()
                Button(role: .destructive) {
                    configStore.removeApp(id: app.id)
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

    private func scanForGames() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let detected = AppDetector.scanForGames()
            DispatchQueue.main.async {
                guard configStore.configurationLoadError == nil, !configStore.recoveryRequired, !configStore.isTransitioning else {
                    isScanning = false
                    scanSummary = "Scan finished. Finish recovery before adding detected applications."
                    return
                }
                let previousCount = configStore.config.monitoredApps.count
                for app in detected { configStore.addApp(app) }
                let added = configStore.config.monitoredApps.count - previousCount
                scanSummary = added == 0 ? "Scan complete. No new games found." : "Scan complete. Added \(added) \(added == 1 ? "application" : "applications")."
                isScanning = false
            }
        }
    }

    private struct AppGroup {
        let title: String
        let apps: [MonitoredApp]
    }

    private var groupedSources: [AppGroup] {
        let apps = configStore.config.monitoredApps
        return [
            AppGroup(title: "Presets", apps: apps.filter { $0.source == .preset }),
            AppGroup(title: "Detected Games", apps: apps.filter { $0.source == .detected }),
            AppGroup(title: "Custom", apps: apps.filter { $0.source == .manual }),
        ]
    }
}
