//
//  AppPickerSheet.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI
import AppKit

struct AppPickerSheet: View {
    @ObservedObject var configStore: ConfigStore
    @Binding var isPresented: Bool
    @State private var manualBundleID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Application")
                .font(.headline)

            // Running apps list
            Text("Running Apps")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        HStack {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            }
                            Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown")
                            Spacer()
                            Text(app.bundleIdentifier ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)

                            if isAlreadyAdded(app) {
                                Text("Added")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Button("Add") {
                                    addRunningApp(app)
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                    }
                }
            }
            .frame(maxHeight: 200)

            Divider()

            // Browse for .app
            HStack {
                Button("Browse .app...") {
                    browseForApp()
                }
            }

            // Manual bundle ID
            HStack {
                TextField("Bundle ID", text: $manualBundleID)
                    .textFieldStyle(.roundedBorder)

                Button("Add") {
                    addManualBundleID()
                }
                .disabled(manualBundleID.isEmpty)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 480, height: 400)
    }

    // MARK: - Running Apps

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard let bundleID = app.bundleIdentifier else { return false }
                // Filter out system/background processes
                return app.activationPolicy == .regular
                    && !bundleID.hasPrefix("com.apple.")
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func isAlreadyAdded(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        return configStore.config.monitoredApps.contains { $0.bundleID == bundleID }
    }

    private func addRunningApp(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        let monitored = MonitoredApp(
            id: UUID(),
            bundleID: bundleID,
            name: app.localizedName ?? bundleID,
            isEnabled: true,
            source: .manual
        )
        configStore.addApp(monitored)
    }

    // MARK: - Browse

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        if panel.runModal() == .OK, let url = panel.url {
            guard let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier else { return }

            let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? url.deletingPathExtension().lastPathComponent

            let monitored = MonitoredApp(
                id: UUID(),
                bundleID: bundleID,
                name: name,
                isEnabled: true,
                source: .manual
            )
            configStore.addApp(monitored)
        }
    }

    // MARK: - Manual

    private func addManualBundleID() {
        let trimmed = manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let monitored = MonitoredApp(
            id: UUID(),
            bundleID: trimmed,
            name: trimmed,
            isEnabled: true,
            source: .manual
        )
        configStore.addApp(monitored)
        manualBundleID = ""
    }
}
