//
//  DisplaySettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 08/04/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct DisplaySettingsView: View {
    @ObservedObject var configStore: ConfigStore

    private var hasProMotion: Bool {
        RefreshRateLock.isProMotionAvailable
    }

    private var maxRate: Int {
        RefreshRateLock.maxRefreshRate
    }

    var body: some View {
        Form {
            proMotionStatusSection
            refreshRateLockSection
            perAppRefreshRateLockSection
            lowPowerModeSection
        }
        .formStyle(.grouped)
    }

    // MARK: - ProMotion Status

    private var proMotionStatusSection: some View {
        Section("Display") {
            HStack(spacing: 8) {
                Circle()
                    .fill(hasProMotion ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(hasProMotion
                     ? "ProMotion (\(maxRate)Hz) — Supported"
                     : "ProMotion — Not Available")
                    .foregroundStyle(hasProMotion ? .primary : .secondary)
            }

            if !hasProMotion {
                Text("The current main display does not support ProMotion. Display settings are visible but will not activate until a ProMotion display is connected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Refresh Rate Lock

    private var refreshRateLockSection: some View {
        Section {
            Toggle("Lock refresh rate to \(maxRate)Hz during gaming",
                   isOn: $configStore.config.display.isRefreshRateLockEnabled)
        } header: {
            Text("Refresh Rate Lock")
        } footer: {
            Text("Prevents macOS from reducing the display refresh rate when streaming games (e.g. GeForce NOW). Uses a tiny invisible overlay that submits frames at \(maxRate)fps to keep the panel at full speed. Enable per-app below to choose which games need this.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Per-App Refresh Rate Lock

    private var perAppRefreshRateLockSection: some View {
        Section {
            let apps = configStore.config.monitoredApps.filter { $0.isEnabled }
            if apps.isEmpty {
                Text("No enabled monitored apps. Add apps in the Applications tab.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(apps) { app in
                    let binding = Binding<Bool>(
                        get: {
                            configStore.config.monitoredApps
                                .first(where: { $0.id == app.id })?.lockRefreshRate ?? false
                        },
                        set: { _ in
                            configStore.toggleAppRefreshRateLock(id: app.id)
                        }
                    )
                    Toggle(isOn: binding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text(app.bundleID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Per-App Refresh Rate Lock")
        } footer: {
            Text("Choose which apps should trigger the refresh rate lock. Typically needed for streaming apps like GeForce NOW, but not for native games.")
                .foregroundStyle(.secondary)
        }
        .disabled(!configStore.config.display.isRefreshRateLockEnabled)
    }

    // MARK: - Low Power Mode

    private var lowPowerModeSection: some View {
        Section {
            HStack(spacing: 8) {
                Circle()
                    .fill(PowerManager.isLowPowerModeEnabled ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(PowerManager.isLowPowerModeEnabled
                     ? "Low Power Mode — Enabled"
                     : "Low Power Mode — Disabled")
            }

            if PowerManager.isLowPowerModeEnabled {
                Text("Low Power Mode caps the display at 60Hz regardless of settings. The refresh rate lock will not work while it is active.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Toggle("Auto-disable Low Power Mode when gaming",
                   isOn: $configStore.config.display.autoDisableLowPowerMode)

            if configStore.config.display.autoDisableLowPowerMode {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Battery threshold")
                        Spacer()
                        Text("\(configStore.config.display.lowPowerModeBatteryThreshold)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: batteryThresholdBinding,
                        in: 10...100,
                        step: 5
                    )
                }

                if let level = PowerManager.batteryLevel {
                    Text("Current battery: \(level)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Low Power Mode")
        } footer: {
            Text("When enabled, Low Power Mode will be automatically disabled during gaming if the battery is above the threshold. It will be restored when gaming mode deactivates. Requires administrator password on first use.")
                .foregroundStyle(.secondary)
        }
    }

    private var batteryThresholdBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(configStore.config.display.lowPowerModeBatteryThreshold) },
            set: { configStore.config.display.lowPowerModeBatteryThreshold = Int($0) }
        )
    }
}
