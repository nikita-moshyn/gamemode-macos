//
//  GeneralSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @Bindable var store: StoreOf<AppSettings>

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { store.loginStatus == .enabled || store.loginStatus == .requiresApproval }, set: { store.send(.launchAtLoginChanged($0)) })
    }

    private var modeStatus: String {
        if store.configurationLoadError != nil { return "Configuration needs attention" }
        if store.runtime.recoveryRequired { return "Recovery required" }
        if store.runtime.isTransitioning { return "Updating settings…" }
        return store.runtime.isGamingMode ? "Enabled" : "Disabled"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Game Mode", value: modeStatus)
                LabeledContent("Mouse Preset", value: store.runtime.isMouseBoostApplied ? "Enabled" : "Disabled")
            } header: {
                Text("Overview")
            } footer: {
                Text("Use the menu bar or your hotkeys to control Game Mode. Choose what changes in Input Guard, Mouse, and Displays, or select applications in Auto-Activation.")
            }

            Section {
                Toggle("Launch at login", isOn: launchAtLogin)
                    .disabled(store.isUpdatingLoginItem || !store.canEdit)
                if store.loginStatus == .requiresApproval {
                    Label("Approval required in System Settings", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings") {
                        store.send(.command(.loginSettings))
                    }
                }
                if let error = store.loginError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Keep GameMode available in the menu bar whenever you sign in.")
            }

            Section {
                Toggle("Receive beta updates", isOn: $store.config.receivesBetaUpdates)
                Button("Check for Updates…") { store.send(.command(.checkForUpdates)) }
                    .disabled(store.isPreview)
            } header: {
                Text("Updates")
            } footer: {
                Text("Try beta and release candidate builds before the next stable release. These builds may be less reliable. Turning this off keeps your installed version until a newer stable release is available.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                LabeledContent("License", value: "MIT")
                LabeledContent("Author", value: "Nikita Moshyn")
            }

            Section("Support") {
                Link("GitHub Repository", destination: URL(string: "https://github.com/nikita-moshyn/gamemode-macos")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/nikita-moshyn/gamemode-macos/issues")!)
            }
            .disabled(store.isPreview)
        }
        .formStyle(.grouped)
        .task { await store.send(.loginStatusRequested).finish() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.send(.loginStatusRequested)
        }
    }

}
