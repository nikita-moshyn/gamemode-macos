//
//  GeneralSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @ObservedObject var configStore: ConfigStore
    var onCheckForUpdates: (() -> Void)?
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: toggleLaunchAtLogin)
    }

    private var modeStatus: String {
        if configStore.configurationLoadError != nil { return "Configuration needs attention" }
        if configStore.recoveryRequired { return "Recovery required" }
        if configStore.isTransitioning { return "Updating settings…" }
        return configStore.isGamingMode ? "Enabled" : "Disabled"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Game Mode", value: modeStatus)
                LabeledContent("Mouse Preset", value: configStore.isMouseBoostApplied ? "Enabled" : "Disabled")
            } header: {
                Text("Overview")
            } footer: {
                Text("Use the menu bar or your hotkeys to control Game Mode. Choose what changes in Input Guard, Mouse, and Displays, or select applications in Auto-Activation.")
            }

            Section {
                Toggle("Launch at login", isOn: launchAtLogin)
                if loginStatus == .requiresApproval {
                    Label("Approval required in System Settings", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings") {
                        guard !configStore.isPreview else { return }
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                if let error = loginError {
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
                Toggle("Receive beta updates", isOn: $configStore.config.receivesBetaUpdates)
                Button("Check for Updates…") { onCheckForUpdates?() }
                    .disabled(onCheckForUpdates == nil || configStore.isPreview)
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
            .disabled(configStore.isPreview)
        }
        .formStyle(.grouped)
        .onAppear { refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginStatus()
        }
    }

    private func refreshLoginStatus() {
        guard !configStore.isPreview else { return }
        loginStatus = SMAppService.mainApp.status
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        if configStore.isPreview {
            loginStatus = enable ? .enabled : .notRegistered
            return
        }
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        refreshLoginStatus()
    }
}
