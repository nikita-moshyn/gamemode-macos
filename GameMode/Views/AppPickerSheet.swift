//
//  AppPickerSheet.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import SwiftUI
import AppKit

struct AppPickerSheet: View {
    @Bindable var store: StoreOf<ApplicationPicker>

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
                    if store.runningApps.isEmpty {
                        Text("No running applications are available. Browse for an app below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.runningApps) { app in
                        runningAppRow(app)
                    }
                }

                Section {
                    Button("Browse for an Application…") { store.send(.browseButtonTapped) }
                        .disabled(store.isBrowsing)
                }

                Section {
                    HStack(alignment: .firstTextBaseline) {
                        TextField("Bundle identifier", text: $store.manualBundleID, prompt: Text("com.example.game"))
                            .onSubmit { store.send(.manualAddButtonTapped) }
                        Button("Add") { store.send(.manualAddButtonTapped) }
                            .disabled(store.validationMessage != nil)
                            .accessibilityLabel("Add application by bundle identifier")
                    }
                    if !store.manualBundleID.isEmpty, let validationMessage = store.validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Add Manually")
                } footer: {
                    Text("Enter a bundle identifier, or end it with .* to match a group of applications.")
                }

                if let feedback = store.feedback {
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
                Button("Done") { store.send(.doneButtonTapped) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 580, maxWidth: 720, minHeight: 460, idealHeight: 560, maxHeight: 720)
        .onExitCommand { store.send(.doneButtonTapped) }
        .task { await store.send(.runningApplicationsRequested).finish() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in store.send(.runningApplicationsRequested) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in store.send(.runningApplicationsRequested) }
    }

    private func runningAppRow(_ app: ApplicationCandidate) -> some View {
        HStack(spacing: 10) {
            if let url = app.url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                Text(app.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            if store.existingIDs.contains(app.bundleID) {
                Label("Added", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Add") {
                    store.send(.addButtonTapped(app))
                }
                .accessibilityLabel("Add \(app.name)")
            }
        }
    }

}
