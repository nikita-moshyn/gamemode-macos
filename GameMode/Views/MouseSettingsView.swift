//
//  MouseSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2025 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct MouseSettingsView: View {
    @ObservedObject var configStore: ConfigStore

    private let settingsManager = SettingsManager()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Enable mouse sensitivity management", isOn: $configStore.config.mouse.isEnabled)

                Text("When disabled, GameMode will never touch your mouse settings. The menu bar toggle is also hidden.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Group {
                    Text("Speed Settings")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Gaming Speed")
                            Spacer()
                            Text(String(format: "%.1f", configStore.config.mouse.gamingSpeed))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $configStore.config.mouse.gamingSpeed, in: 0...5, step: 0.1)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Normal Speed")
                            Spacer()
                            Text(String(format: "%.1f", configStore.config.mouse.normalSpeed))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $configStore.config.mouse.normalSpeed, in: 0...5, step: 0.1)
                    }

                    Divider()

                    Toggle("Auto-capture current speed before gaming", isOn: $configStore.config.mouse.autoCapture)

                    Text("Reads your live mouse speed each time gaming mode activates and restores that exact value when it deactivates.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        if let captured = configStore.config.mouse.capturedSystemSpeed {
                            Text("Last captured speed: \(String(format: "%.1f", captured))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Read Current Speed") {
                            if let speed = settingsManager.readCurrentMouseSpeed() {
                                configStore.config.mouse.capturedSystemSpeed = speed
                                configStore.config.mouse.normalSpeed = speed
                            }
                        }
                    }
                }
                .disabled(!configStore.config.mouse.isEnabled)
                .opacity(configStore.config.mouse.isEnabled ? 1.0 : 0.5)
            }
            .padding()
        }
    }
}
