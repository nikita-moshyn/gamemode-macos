//
//  AppPickerSheet.swift
//  GameMode
//
//  Created by Nikita Moshyn on 11/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI
import AppKit

/// Validation shared by the manual entry UI and its tests.
enum ApplicationPickerValidation {
    static func problem(for bundleID: String, existingIDs: Set<String>) -> String? {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter an application bundle identifier." }
        guard trimmed.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*(?:\\.\\*)?$", options: .regularExpression) != nil else {
            return "Use letters, numbers, hyphens, and periods, with an optional .* suffix to match a group of applications."
        }
        guard !existingIDs.contains(trimmed) else { return "This application has already been added." }
        return nil
    }
}

struct AppPickerSheet: View {
    @ObservedObject var configStore: ConfigStore
    @Binding var isPresented: Bool
    @State private var manualBundleID = ""
    @State private var runningApps: [NSRunningApplication] = []
    @State private var feedback: String?

    private var validationMessage: String? {
        ApplicationPickerValidation.problem(for: manualBundleID, existingIDs: Set(configStore.config.monitoredApps.map(\.bundleID)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Applications").font(.title2.weight(.semibold))
                Text("Choose a running app, browse your Mac, or enter its bundle identifier.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Form {
                Section("Running Applications") {
                    if runningApps.isEmpty {
                        Text("No running applications are available. Browse for an app below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        runningAppRow(app)
                    }
                }

                Section {
                    Button("Browse for an Application…") { browseForApp() }
                }

                Section {
                    HStack(alignment: .firstTextBaseline) {
                        TextField("Bundle identifier", text: $manualBundleID, prompt: Text("com.example.game"))
                            .onSubmit { addManualBundleID() }
                        Button("Add") { addManualBundleID() }
                            .disabled(validationMessage != nil)
                            .accessibilityLabel("Add application by bundle identifier")
                    }
                    if !manualBundleID.isEmpty, let validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Add Manually")
                } footer: {
                    Text("Enter a bundle identifier, or end it with .* to match a group of applications.")
                }

                if let feedback {
                    Section {
                        Text(feedback)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 580, maxWidth: 720, minHeight: 460, idealHeight: 560, maxHeight: 720)
        .onExitCommand { isPresented = false }
        .onAppear { refreshRunningApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshRunningApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshRunningApps() }
    }

    private func runningAppRow(_ app: NSRunningApplication) -> some View {
        HStack(spacing: 10) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.localizedName ?? app.bundleIdentifier ?? "Application")
                Text(app.bundleIdentifier ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            if configStore.config.monitoredApps.contains(where: { $0.bundleID == app.bundleIdentifier }) {
                Label("Added", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Add") {
                    guard let bundleID = app.bundleIdentifier else { return }
                    addApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
                }
                .accessibilityLabel("Add \(app.localizedName ?? app.bundleIdentifier ?? "application")")
            }
        }
    }

    private func refreshRunningApps() {
        var seen = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier, app.activationPolicy == .regular,
                  bundleID != Bundle.main.bundleIdentifier else { return false }
            return seen.insert(bundleID).inserted
        }
        .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add Application"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            feedback = "The selected application does not have a bundle identifier."
            return
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        addApp(bundleID: bundleID, name: name)
    }

    private func addManualBundleID() {
        guard validationMessage == nil else { return }
        let trimmed = manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        addApp(bundleID: trimmed, name: trimmed)
        manualBundleID = ""
    }

    private func addApp(bundleID: String, name: String) {
        guard !configStore.config.monitoredApps.contains(where: { $0.bundleID == bundleID }) else {
            feedback = "\(name) has already been added."
            return
        }
        configStore.addApp(MonitoredApp(id: UUID(), bundleID: bundleID, name: name, isEnabled: true, source: .manual))
        feedback = "Added \(name)."
    }
}
