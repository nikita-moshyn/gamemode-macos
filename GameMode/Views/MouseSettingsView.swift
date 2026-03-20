//
//  MouseSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct MouseSettingsView: View {
    @ObservedObject var configStore: ConfigStore
    var onApplyConfiguredMouseSpeed: (() -> Void)?

    var body: some View {
        Form {
            Section {
                Toggle("Enable mouse sensitivity management", isOn: $configStore.config.mouse.isEnabled)
            } footer: {
                Text("When disabled, GameMode will never touch your mouse settings. The menu bar toggle is also hidden.")
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gaming Speed")
                        Spacer()
                        Text(String(format: "%.1f", configStore.config.mouse.gamingSpeed))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $configStore.config.mouse.gamingSpeed, in: 0...5, step: 0.1)
                }

                Button("Apply Configured Speed Live") {
                    onApplyConfiguredMouseSpeed?()
                }
            } header: {
                Text("Speed Settings")
            }
            footer: {
                Text("Applies the configured gaming speed immediately through HIDSystem without writing a persistent mouse preference.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!configStore.config.mouse.isEnabled)

            Section {
                Toggle(
                    "Enable mouse boost automatically when Game Mode activates",
                    isOn: $configStore.config.mouse.isMouseBoostEnabled
                )

                if let baseline = configStore.sessionMouseBaselineSpeed {
                    Text("Last detected baseline speed: \(String(format: "%.1f", baseline))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Baseline speed is detected automatically when mouse boost turns on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Mouse boost can only become active while Game Mode is active. The app always detects your current mouse speed right before applying boost.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!configStore.config.mouse.isEnabled)
        }
        .formStyle(.grouped)
    }
}
