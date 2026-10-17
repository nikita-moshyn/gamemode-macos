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
                Toggle("Enable Mouse Preset", isOn: $store.config.mouse.isEnabled)
            } footer: {
                Text("Use a different tracking speed during Game Mode. This preset applies to all mice connected to your Mac.")
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
                if store.config.mouse.isEnabled && !store.runtime.isGamingMode {
                    Text("Turn on Game Mode to apply this preset.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Preset Settings")
            } footer: {
                Text("Your normal tracking speed is saved before applying the preset and restored when the preset or Game Mode turns off.")
            }
            .disabled(!store.config.mouse.isEnabled)

            Section {
                Toggle("Apply automatically with Game Mode", isOn: $store.config.mouse.isMouseBoostEnabled)
                LabeledContent("Currently applied", value: store.runtime.isMouseBoostApplied ? "Yes" : "No")
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
