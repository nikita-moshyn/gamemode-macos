//
//  AppsSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct AppsSettingsView: View {
    @ObservedObject var configStore: ConfigStore
    @State private var showingAddSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Trigger Applications")
                    .font(.headline)

                Text("Gaming mode activates when any enabled app launches.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(groupedSources, id: \.title) { group in
                    if !group.apps.isEmpty {
                        Section {
                            ForEach(group.apps) { app in
                                appRow(app)
                            }
                        } header: {
                            Text(group.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("Add App") {
                        showingAddSheet = true
                    }

                    Button("Re-scan") {
                        let detected = AppDetector.scanForGames()
                        for app in detected {
                            configStore.addApp(app)
                        }
                    }

                    Spacer()
                }
                .padding(.top, 8)
            }
            .padding()
        }
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
                        .foregroundColor(.secondary)
                }
            }

            if app.source != .preset {
                Spacer()
                Button(role: .destructive) {
                    configStore.removeApp(id: app.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
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
