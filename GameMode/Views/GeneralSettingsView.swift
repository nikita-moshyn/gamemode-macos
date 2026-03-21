//
//  GeneralSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 16/03/2026.
//  Copyright © 2025 Nikita Moshyn. All rights reserved.
//

import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @ObservedObject var configStore: ConfigStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }

                if let error = loginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: buildNumber)
                LabeledContent("License", value: "MIT")
                LabeledContent("Author", value: "Nikita Moshyn")
            }

            Section("Links") {
                Link("GitHub Repository", destination: URL(string: "https://github.com/nikita-moshyn/gamemode-macos")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/nikita-moshyn/gamemode-macos/issues")!)
            }
        }
        .formStyle(.grouped)
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
