//
//  PowerManager.swift
//  GameMode
//
//  Created by Nikita Moshyn on 08/04/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation
import IOKit.ps

/// Manages Low Power Mode detection and toggling, plus battery level reading.
///
/// Low Power Mode is toggled via `pmset` with administrator privileges.
/// The standard macOS password dialog is shown on first invocation per session.
class PowerManager {

    // MARK: - Low Power Mode Detection

    /// Whether Low Power Mode is currently enabled.
    static var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Current battery level as a percentage (0–100), or nil if no battery.
    static var batteryLevel: Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first else { return nil }

        guard let description = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any],
              let capacity = description[kIOPSCurrentCapacityKey] as? Int else { return nil }

        return capacity
    }

    /// Whether the device is currently plugged in.
    static var isPluggedIn: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first else { return false }

        guard let description = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any],
              let powerSource = description[kIOPSPowerSourceStateKey] as? String else { return false }

        return powerSource == kIOPSACPowerValue
    }

    // MARK: - Low Power Mode Control

    /// Attempt to disable Low Power Mode via pmset.
    /// Uses AppleScript `with administrator privileges` which shows the standard macOS password dialog.
    /// Returns true if the command succeeded.
    /// Attempt to disable Low Power Mode via pmset.
    /// Uses AppleScript `with administrator privileges` which shows the standard macOS password dialog.
    /// Must execute on the main thread (AppleScript admin dialog requires AppKit UI).
    /// Returns true if the command succeeded.
    @discardableResult
    static func setLowPowerMode(enabled: Bool) -> Bool {
        let value = enabled ? "1" : "0"
        let script = """
        do shell script "pmset -a lowpowermode \(value)" with administrator privileges
        """

        let execute: () -> Bool = {
            guard let appleScript = NSAppleScript(source: script) else {
                Log.error("Failed to create AppleScript for pmset", category: "Power")
                return false
            }

            var errorDict: NSDictionary?
            appleScript.executeAndReturnError(&errorDict)

            if let error = errorDict {
                let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "unknown"
                Log.warning("pmset failed: \(errorMessage)", category: "Power")
                return false
            }

            Log.info("Low Power Mode set to \(enabled ? "enabled" : "disabled") via pmset", category: "Power")
            return true
        }

        if Thread.isMainThread {
            return execute()
        } else {
            return DispatchQueue.main.sync { execute() }
        }
    }

    /// Check if battery level is above the given threshold percentage.
    static func isBatteryAboveThreshold(_ threshold: Int) -> Bool {
        guard let level = batteryLevel else { return true }
        return level >= threshold
    }
}
