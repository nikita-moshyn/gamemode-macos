//
//  DisplayConfig.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

// MARK: - Display

struct ManagedDisplayPreference: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var isEnabled: Bool
}

struct DisplayConfig: Codable, Equatable {
    /// Master switch for all display refresh management during game mode.
    var isRefreshRateLockEnabled: Bool = false

    /// When true, built-in ProMotion displays are managed during game mode.
    var manageBuiltInProMotionDisplay: Bool = true

    /// When true, external high-refresh displays are managed during game mode.
    var manageExternalDisplays: Bool = false

    /// Prefer a fixed mode over the overlay on built-in displays. Managed external
    /// displays always use an available higher fixed mode.
    var preferExactModeSwitching: Bool = false

    /// Use the hidden overlay fallback for ProMotion displays when exact mode switching
    /// is not available or not sufficient.
    var allowOverlayFallback: Bool = true

    /// Per-display enable/disable overrides. Displays default to enabled.
    var managedDisplays: [ManagedDisplayPreference] = []

    /// Automatically disable Low Power Mode when gaming mode activates
    /// and battery level is above the threshold.
    var autoDisableLowPowerMode: Bool = false

    /// Battery percentage threshold above which Low Power Mode will be auto-disabled.
    /// Range: 10–100. Only used when `autoDisableLowPowerMode` is true.
    var lowPowerModeBatteryThreshold: Int = 50

    init(isRefreshRateLockEnabled: Bool = false, manageBuiltInProMotionDisplay: Bool = true, manageExternalDisplays: Bool = false, preferExactModeSwitching: Bool = false, allowOverlayFallback: Bool = true, managedDisplays: [ManagedDisplayPreference] = [], autoDisableLowPowerMode: Bool = false, lowPowerModeBatteryThreshold: Int = 50) {
        self.isRefreshRateLockEnabled = isRefreshRateLockEnabled
        self.manageBuiltInProMotionDisplay = manageBuiltInProMotionDisplay
        self.manageExternalDisplays = manageExternalDisplays
        self.preferExactModeSwitching = preferExactModeSwitching
        self.allowOverlayFallback = allowOverlayFallback
        self.managedDisplays = managedDisplays
        self.autoDisableLowPowerMode = autoDisableLowPowerMode
        self.lowPowerModeBatteryThreshold = lowPowerModeBatteryThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isRefreshRateLockEnabled = try container.decodeIfPresent(Bool.self, forKey: .isRefreshRateLockEnabled) ?? false
        manageBuiltInProMotionDisplay = try container.decodeIfPresent(Bool.self, forKey: .manageBuiltInProMotionDisplay) ?? true
        manageExternalDisplays = try container.decodeIfPresent(Bool.self, forKey: .manageExternalDisplays) ?? false
        preferExactModeSwitching = try container.decodeIfPresent(Bool.self, forKey: .preferExactModeSwitching) ?? false
        allowOverlayFallback = try container.decodeIfPresent(Bool.self, forKey: .allowOverlayFallback) ?? true
        managedDisplays = try container.decodeIfPresent([ManagedDisplayPreference].self, forKey: .managedDisplays) ?? []
        autoDisableLowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .autoDisableLowPowerMode) ?? false
        lowPowerModeBatteryThreshold = try container.decodeIfPresent(Int.self, forKey: .lowPowerModeBatteryThreshold) ?? 50
    }

    func isDisplayEnabled(id: String, legacyID: String? = nil) -> Bool {
        if let preference = managedDisplays.first(where: { $0.id == id }) { return preference.isEnabled }
        // Keep earlier selections as fallbacks. A new per-display override does
        // not change the inherited choice for another formerly identical display.
        if let legacyID, let preference = managedDisplays.first(where: { $0.id == legacyID }) { return preference.isEnabled }
        return true
    }

    mutating func setDisplayEnabled(_ isEnabled: Bool, id: String, name: String) {
        if let index = managedDisplays.firstIndex(where: { $0.id == id }) {
            managedDisplays[index].isEnabled = isEnabled
            managedDisplays[index].name = name
            return
        }

        managedDisplays.append(
            ManagedDisplayPreference(
                id: id,
                name: name,
                isEnabled: isEnabled
            )
        )
    }
}
