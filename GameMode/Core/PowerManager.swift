//
//  PowerManager.swift
//  GameMode
//
//  Created by Nikita Moshyn on 10/10/2026.
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

    /// Read every available power-source policy before the existing `pmset -a` write.
    static func captureLowPowerModeSettings() -> [String: Int]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "custom"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
            return parseLowPowerModeSettings(text)
        } catch {
            Log.warning("Could not capture power-source settings: \(error)", category: "Power")
            return nil
        }
    }

    /// Fail closed if any listed power source lacks a valid Low Power Mode value.
    static func parseLowPowerModeSettings(_ output: String) -> [String: Int]? {
        let sourceNames = ["Battery Power:": "b", "AC Power:": "c", "UPS Power:": "u"]
        var sources = Set<String>()
        var settings: [String: Int] = [:]
        var currentSource: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let source = sourceNames[text] {
                guard sources.insert(source).inserted else { return nil }
                currentSource = source
                continue
            }
            if text.hasSuffix(":") { return nil }
            let fields = text.split(whereSeparator: \.isWhitespace)
            guard fields.first == "lowpowermode" else { continue }
            guard let source = currentSource, fields.count == 2, let value = Int(fields[1]),
                  value == 0 || value == 1, settings[source] == nil else { return nil }
            settings[source] = value
        }
        guard !sources.isEmpty, Set(settings.keys) == sources else { return nil }
        return settings
    }

    /// Restore only captured source policies and verify each source independently.
    static func restoreLowPowerModeSettings(_ settings: [String: Int]) -> [String] {
        guard !settings.isEmpty, settings.keys.allSatisfy({ ["b", "c", "u"].contains($0) }),
              settings.values.allSatisfy({ $0 == 0 || $0 == 1 }) else {
            return ["Original Low Power Mode settings are incomplete"]
        }
        guard let current = captureLowPowerModeSettings() else {
            return ["Low Power Mode settings could not be read"]
        }
        var failures: [String] = []
        for source in ["b", "c", "u"] {
            guard let value = settings[source] else { continue }
            guard current[source] != nil else {
                failures.append("Low Power Mode source \(source) is unavailable")
                continue
            }
            if current[source] != value, !executePowerCommand("pmset -\(source) lowpowermode \(value)") {
                failures.append("Low Power Mode could not be restored for source \(source)")
            }
        }
        guard let restored = captureLowPowerModeSettings() else {
            return failures + ["Restored Low Power Mode settings could not be read"]
        }
        for (source, expected) in settings where restored[source] != expected {
            failures.append("Low Power Mode could not be verified for source \(source)")
        }
        return failures
    }

    /// Attempt to disable Low Power Mode via pmset.
    /// Uses AppleScript `with administrator privileges` which shows the standard macOS password dialog.
    /// Must execute on the main thread (AppleScript admin dialog requires AppKit UI).
    /// Returns true if the command succeeded.
    @discardableResult
    static func setLowPowerMode(enabled: Bool) -> Bool {
        let value = enabled ? "1" : "0"
        let succeeded = executePowerCommand("pmset -a lowpowermode \(value)")
        if succeeded {
            Log.info("Low Power Mode set to \(enabled ? "enabled" : "disabled") via pmset", category: "Power")
        }
        return succeeded
    }

    private static func executePowerCommand(_ command: String) -> Bool {
        let script = """
        do shell script "\(command)" with administrator privileges
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
