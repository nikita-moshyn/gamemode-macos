//
//  MouseSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 10/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct MouseSettingsView: View {
    @ObservedObject var configStore: ConfigStore
    var onApplyConfiguredMouseSpeed: (() -> Void)?

    private var canApplyProfile: Bool {
        configStore.config.mouse.isEnabled && configStore.isGamingMode
            && !configStore.isTransitioning && !configStore.recoveryRequired
            && configStore.configurationLoadError == nil
    }

    var body: some View {
        Form {
            Section {
                Toggle("Mouse Preset", isOn: $configStore.config.mouse.isEnabled)
            } footer: {
                Text("Use a different tracking speed while gaming, with the same mouse or a separate gaming mouse. This preset changes the system mouse speed; it is not tied to a particular device.")
            }

            Section {
                LabeledContent("Tracking speed") {
                    Text(configStore.config.mouse.gamingSpeed, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $configStore.config.mouse.gamingSpeed, in: 0...5, step: 0.1) {
                    Text("Gaming tracking speed")
                } minimumValueLabel: {
                    Text("Slow")
                } maximumValueLabel: {
                    Text("Fast")
                }
                .accessibilityValue(String(format: "%.1f", configStore.config.mouse.gamingSpeed))

                Button("Apply Preset") { onApplyConfiguredMouseSpeed?() }
                    .disabled(!canApplyProfile)
            } header: {
                Text("Preset Settings")
            } footer: {
                Text("Apply the configured speed while Game Mode is enabled. Your previous speed is saved before the preset is first applied and restored when you turn it off.")
            }
            .disabled(!configStore.config.mouse.isEnabled)

            Section {
                Toggle("Apply automatically with Game Mode", isOn: $configStore.config.mouse.isMouseBoostEnabled)
                LabeledContent("Preset status", value: configStore.isMouseBoostApplied ? "Enabled" : "Disabled")
                if let baseline = configStore.sessionMouseBaselineSpeed {
                    LabeledContent("Saved normal speed", value: String(format: "%.1f", baseline))
                }
            } header: {
                Text("Activation")
            } footer: {
                Text("You can also switch the Mouse Preset on or off from the menu bar while Game Mode is enabled.")
            }
            .disabled(!configStore.config.mouse.isEnabled)
        }
        .formStyle(.grouped)
    }
}
