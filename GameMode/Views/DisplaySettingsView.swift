//
//  DisplaySettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import SwiftUI
import Combine

#if FEATURE_DISPLAYS
struct DisplaySettingsView: View {
    @Bindable var store: StoreOf<AppSettings>

    private var displays: [DisplaySnapshot] { store.displayStatus.displays }
    private var lowPowerModeEnabled: Bool { store.displayStatus.lowPowerModeEnabled }
    private var batteryLevel: Int? { store.displayStatus.batteryLevel }

    private var manageableDisplays: [DisplaySnapshot] {
        displays.filter(\.supportsManagement)
    }

    private var hasBuiltInProMotionDisplay: Bool {
        displays.contains { $0.isBuiltIn && $0.supportsProMotion }
    }

    private var hasManageableExternalDisplay: Bool {
        displays.contains { !$0.isBuiltIn && $0.supportsManagement }
    }

    var body: some View {
        Form {
            displayStatusSection
            displayManagementSection
            managedDisplaysSection
            refreshRateApplicationsSection
            lowPowerModeSection
        }
        .formStyle(.grouped)
        .task { await store.send(.displayStatusRequested).finish() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).debounce(for: .milliseconds(200), scheduler: RunLoop.main)) { _ in store.send(.displayStatusRequested) }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in store.send(.displayStatusRequested) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.send(.displayStatusRequested) }
        .onChange(of: store.runtime.isTransitioning) { _, transitioning in
            if !transitioning { store.send(.displayStatusRequested) }
        }
        .onChange(of: store.runtime.isGamingMode) { _, _ in store.send(.displayStatusRequested) }
    }

    // MARK: - Status

    private var displayStatusSection: some View {
        Section("Connected Displays") {
            if displays.isEmpty {
                Text("No active displays detected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displays) { display in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor(for: display))
                                .frame(width: 8, height: 8)

                            Text(display.name)
                                .fontWeight(.medium)

                            Spacer()

                            Text(display.roleDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("Current: \(display.currentRefreshDescription) · Max: \(display.maximumRefreshDescription)")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        if display.highestExactRefreshRate > 0.1 {
                            Text("Highest fixed mode at current resolution: \(display.highestExactRefreshDescription)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(display.methodDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if display.isLowPowerModeBlocked {
                            Text("Low Power Mode is capping this built-in ProMotion display to 60Hz.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Display Refresh Management

    private var displayManagementSection: some View {
        Section {
            Toggle(
                "Use maximum refresh rate during Game Mode",
                isOn: $store.config.display.isRefreshRateLockEnabled
            )

            Toggle(
                "Manage built-in ProMotion display",
                isOn: $store.config.display.manageBuiltInProMotionDisplay
            )
            .disabled(!hasBuiltInProMotionDisplay || !store.config.display.isRefreshRateLockEnabled)

            Toggle(
                "Manage external high-refresh displays",
                isOn: $store.config.display.manageExternalDisplays
            )
            .disabled(!hasManageableExternalDisplay || !store.config.display.isRefreshRateLockEnabled)

        } header: {
            Text("Max Refresh Rate")
        } footer: {
            Text("Use the highest supported refresh rate at your current resolution while Game Mode is enabled. Display compatibility options are in System → Advanced.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Per-Display Selection

    private var managedDisplaysSection: some View {
        Section {
            if manageableDisplays.isEmpty {
                Text("No ProMotion or high-refresh displays are currently available.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manageableDisplays) { display in
                    Toggle(isOn: managedDisplayBinding(for: display)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(display.name)

                            Text("\(display.roleDescription) · Current \(display.currentRefreshDescription) · Max \(display.maximumRefreshDescription)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isDisplayToggleDisabled(display))
                }
            }
        } header: {
            Text("Managed Displays")
        } footer: {
            Text("Use this list to exclude specific displays from GameMode. Displays default to enabled when first detected.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Per-App Selection

    var refreshRateApps: [MonitoredApp] { store.config.monitoredApps.filter(\.isEnabled) }

    private var refreshRateApplicationsSection: some View {
        Section {
            if refreshRateApps.isEmpty {
                Text("Enable applications in Auto-Activation to choose which ones use Max Refresh Rate.")
                    .foregroundStyle(.secondary)
            }
            ForEach(refreshRateApps) { app in
                Toggle(isOn: refreshRateBinding(for: app.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        Text(app.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Applications")
        } footer: {
            Text("Use Max Refresh Rate while any selected application is running. Manage the application list in Auto-Activation.")
        }
        .disabled(!store.config.display.isRefreshRateLockEnabled)
    }

    func refreshRateBinding(for appID: UUID) -> Binding<Bool> {
        Binding(get: {
            store.config.monitoredApps.first { $0.id == appID }?.lockRefreshRate ?? false
        }, set: { enabled in
            store.send(.appRefreshRateLockChanged(appID, enabled))
        })
    }

    // MARK: - Low Power Mode

    private var lowPowerModeSection: some View {
        Section {
            HStack(spacing: 8) {
                Circle()
                    .fill(lowPowerModeEnabled ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)

                Text(lowPowerModeEnabled
                     ? "Low Power Mode — Enabled"
                     : "Low Power Mode — Disabled")
            }

            if lowPowerModeEnabled {
                Text("Low Power Mode caps the built-in ProMotion display at 60Hz. External display mode switching can still work if the monitor exposes a fixed high-refresh desktop mode.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Toggle(
                "Auto-disable Low Power Mode when gaming",
                isOn: $store.config.display.autoDisableLowPowerMode
            )

            if store.config.display.autoDisableLowPowerMode {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Battery threshold")
                        Spacer()
                        Text("\(store.config.display.lowPowerModeBatteryThreshold)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: batteryThresholdBinding, in: 10...100, step: 5)
                        .accessibilityLabel("Minimum battery level for disabling Low Power Mode")
                        .accessibilityValue("\(store.config.display.lowPowerModeBatteryThreshold) percent")
                }

                if let level = batteryLevel {
                    Text("Current battery: \(level)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Low Power Mode")
        } footer: {
            Text("When enabled, Low Power Mode will be disabled during gaming if the battery is above the threshold and restored when gaming mode stops. This affects built-in ProMotion behavior and requires administrator approval on first use.")
                .foregroundStyle(.secondary)
        }
    }

    private func statusColor(for display: DisplaySnapshot) -> Color {
        if display.isLowPowerModeBlocked {
            return .orange
        }
        return display.supportsManagement ? .green : .secondary
    }

    private func isDisplayToggleDisabled(_ display: DisplaySnapshot) -> Bool {
        if !store.config.display.isRefreshRateLockEnabled {
            return true
        }

        if display.isBuiltIn {
            return !store.config.display.manageBuiltInProMotionDisplay
        }

        return !store.config.display.manageExternalDisplays
    }

    private func managedDisplayBinding(for display: DisplaySnapshot) -> Binding<Bool> {
        Binding<Bool>(
            get: {
                store.config.display.isDisplayEnabled(id: display.id, legacyID: display.legacyID)
            },
            set: { isEnabled in
                store.send(.managedDisplayChanged(id: display.id, name: display.name, isEnabled: isEnabled))
            }
        )
    }

    private var batteryThresholdBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(store.config.display.lowPowerModeBatteryThreshold) },
            set: { store.send(.binding(.set(\.config.display.lowPowerModeBatteryThreshold, Int($0)))) }
        )
    }
}

#endif
