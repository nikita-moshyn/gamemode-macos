//
//  DisplayConfig.swift
//  GameMode
//
//  Created by Nikita Moshyn on 08/04/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

// MARK: - Display

struct DisplayConfig: Codable {
    /// Master switch — when true, refresh rate lock is available for per-app activation.
    var isRefreshRateLockEnabled: Bool = false

    /// Automatically disable Low Power Mode when gaming mode activates
    /// and battery level is above the threshold.
    var autoDisableLowPowerMode: Bool = false

    /// Battery percentage threshold above which Low Power Mode will be auto-disabled.
    /// Range: 10–100. Only used when `autoDisableLowPowerMode` is true.
    var lowPowerModeBatteryThreshold: Int = 50

    init(isRefreshRateLockEnabled: Bool = false,
         autoDisableLowPowerMode: Bool = false,
         lowPowerModeBatteryThreshold: Int = 50) {
        self.isRefreshRateLockEnabled = isRefreshRateLockEnabled
        self.autoDisableLowPowerMode = autoDisableLowPowerMode
        self.lowPowerModeBatteryThreshold = lowPowerModeBatteryThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isRefreshRateLockEnabled = try container.decodeIfPresent(Bool.self, forKey: .isRefreshRateLockEnabled) ?? false
        autoDisableLowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .autoDisableLowPowerMode) ?? false
        lowPowerModeBatteryThreshold = try container.decodeIfPresent(Int.self, forKey: .lowPowerModeBatteryThreshold) ?? 50
    }
}
