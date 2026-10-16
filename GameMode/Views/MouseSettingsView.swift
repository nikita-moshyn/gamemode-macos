//
//  MouseSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import SwiftUI

struct MouseSettingsView: View {
    @Bindable var store: StoreOf<AppSettings>

    private var canApplyProfile: Bool {
        store.config.mouse.isEnabled && store.runtime.isGamingMode
            && !store.runtime.isTransitioning && !store.runtime.recoveryRequired
            && store.configurationLoadError == nil
    }

    var body: some View {
        Form {
            Section {
                Toggle("Mouse Preset", isOn: $store.config.mouse.isEnabled)
            } footer: {
                Text("Use a different tracking speed while gaming, with the same mouse or a separate gaming mouse. This preset changes the system mouse speed; it is not tied to a particular device.")
            }

            Section {
                LabeledContent("Tracking speed") {
                    Text(store.config.mouse.gamingSpeed, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $store.config.mouse.gamingSpeed, in: 0...5, step: 0.1) {
                    Text("Gaming tracking speed")
                } minimumValueLabel: {
                    Text("Slow")
                } maximumValueLabel: {
                    Text("Fast")
                }
                .accessibilityValue(String(format: "%.1f", store.config.mouse.gamingSpeed))

                Button("Apply Preset") { store.send(.applyMouse) }
                    .disabled(!canApplyProfile)
            } header: {
                Text("Preset Settings")
            } footer: {
                Text("Apply the configured speed while Game Mode is enabled. Your previous speed is saved before the preset is first applied and restored when you turn it off.")
            }
            .disabled(!store.config.mouse.isEnabled)

            Section {
                Toggle("Apply automatically with Game Mode", isOn: $store.config.mouse.isMouseBoostEnabled)
                LabeledContent("Preset status", value: store.runtime.isMouseBoostApplied ? "Enabled" : "Disabled")
                if let baseline = store.runtime.sessionMouseBaselineSpeed {
                    LabeledContent("Saved normal speed", value: String(format: "%.1f", baseline))
                }
            } header: {
                Text("Activation")
            } footer: {
                Text("You can also switch the Mouse Preset on or off from the menu bar while Game Mode is enabled.")
            }
            .disabled(!store.config.mouse.isEnabled)
        }
        .formStyle(.grouped)
    }
}
