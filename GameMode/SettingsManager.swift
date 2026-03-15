//
//  SettingsManager.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation
import IOKit

// MARK: - IOKit HIDSystem bridging
// ──────────────────────────────────────────────────────────
// IOKit/hidsystem/IOHIDLib.h isn't auto-bridged to Swift.
// We use @_silgen_name to call IOHIDSetAccelerationWithKey
// directly — this sets mouse acceleration *instantly* via the
// HID driver, with zero cfprefsd restarts and zero system lag.
// ──────────────────────────────────────────────────────────

/// IOHIDSystem connection type for parameter access.
private let kIOHIDParamConnectType: UInt32 = 1

/// Sets mouse acceleration in the HID driver immediately.
/// `acceleration` uses the same 0.0–3.0 scale as `com.apple.mouse.scaling`.
@_silgen_name("IOHIDSetAccelerationWithKey")
private func _IOHIDSetAccelerationWithKey(
    _ handle: io_connect_t,
    _ key: CFString,
    _ acceleration: Double
) -> kern_return_t

// ──────────────────────────────────────────────────────────

/// Handles macOS system settings changes.
///
/// Architecture:
///   • **Keyboard** (function keys, Spotlight) — writes preferences, then applies
///     with a single `cfprefsd` restart + `activateSettings -u`.
///   • **Mouse** — writes preferences for persistence, then applies *instantly*
///     via IOKit HIDSystem (no daemon restart, no freeze).
///
/// No admin privileges required — all writes target the current user's preferences.
class SettingsManager {

    // MARK: - Configuration
    // ──────────────────────────────────────────────────────────
    // Customize these values for your setup.
    //
    // To find your normal mouse speed, run in Terminal:
    //   defaults read -g com.apple.mouse.scaling
    //
    // System Settings slider goes 0.0 → 3.0.
    // Values above 3.0 work but aren't exposed in the UI.
    // ──────────────────────────────────────────────────────────

    /// Your everyday mouse speed (run `defaults read -g com.apple.mouse.scaling` to find it).
    private let normalMouseSpeed: Double = 0.5

    /// Mouse speed for gaming. 3.0 = System Settings max. Try 5.0–7.0 for even faster.
    private let gamingMouseSpeed: Double = 3.0

    enum MouseMode {
        case gaming
        case normal
    }

    // MARK: - Executable Paths

    private let defaultsBin   = "/usr/bin/defaults"
    private let killallBin    = "/usr/bin/killall"
    private let plistBuddyBin = "/usr/libexec/PlistBuddy"
    private let activateSettingsBin =
        "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"

    // MARK: - Keyboard Settings (write-only, call applyKeyboardChanges() after)

    /// Write "Use F1, F2, etc. keys as standard function keys" preference.
    ///
    /// Does NOT apply — call `applyKeyboardChanges()` once after all keyboard writes.
    ///
    /// - Parameter enabled: `true` = F1–F12 act as function keys (gaming).
    ///                      `false` = F1–F12 control brightness/volume/etc (normal).
    func writeFunctionKeys(enabled: Bool) {
        let value = enabled ? "true" : "false"

        shell(defaultsBin, "write", "NSGlobalDomain",
              "com.apple.keyboard.fnState", "-bool", value)

        print("[SettingsManager] Wrote function keys pref → standard mode: \(enabled)")
    }

    /// Toggle the Spotlight shortcut on/off without changing the key combination.
    ///
    /// Only flips `:AppleSymbolicHotKeys:64:enabled` — leaves the `value` dict
    /// (which stores the actual key combo like ⌃Space or ⌘Space) untouched.
    ///
    /// Does NOT apply — call `applyKeyboardChanges()` once after all keyboard writes.
    ///
    /// - Parameter enabled: `true` = Spotlight shortcut active. `false` = disabled.
    func writeSpotlightShortcut(enabled: Bool) {
        let plistPath = "\(NSHomeDirectory())/Library/Preferences/com.apple.symbolichotkeys.plist"
        let enabledStr = enabled ? "true" : "false"

        // Only update the enabled flag — preserve the user's key combination.
        // PlistBuddy "Set" modifies an existing key in-place without touching siblings.
        let result = shell(
            plistBuddyBin,
            "-c", "Set :AppleSymbolicHotKeys:64:enabled \(enabledStr)",
            plistPath
        )

        // If key 64 doesn't exist yet (fresh macOS install), create the full
        // structure with macOS defaults (⌘Space). This only runs on first use.
        if result.exitCode != 0 {
            print("[SettingsManager] Key 64 missing, creating with default ⌘Space binding")
            shell(
                plistBuddyBin,
                "-c", "Add :AppleSymbolicHotKeys:64 dict",
                "-c", "Add :AppleSymbolicHotKeys:64:enabled bool \(enabledStr)",
                "-c", "Add :AppleSymbolicHotKeys:64:value dict",
                "-c", "Add :AppleSymbolicHotKeys:64:value:type string standard",
                "-c", "Add :AppleSymbolicHotKeys:64:value:parameters array",
                "-c", "Add :AppleSymbolicHotKeys:64:value:parameters: integer 32",
                "-c", "Add :AppleSymbolicHotKeys:64:value:parameters: integer 49",
                "-c", "Add :AppleSymbolicHotKeys:64:value:parameters: integer 1048576",
                plistPath
            )
        }

        print("[SettingsManager] Wrote Spotlight shortcut pref → enabled: \(enabled)")
    }

    /// Apply all pending keyboard/shortcut changes in one shot.
    ///
    /// This is the ONLY place cfprefsd gets restarted — called once per mode switch
    /// instead of once per setting, cutting system lag from ~15 seconds to ~3 seconds.
    func applyKeyboardChanges() {
        // One cfprefsd restart for function-key preference pickup
        restartPreferencesDaemon()

        // activateSettings re-binds symbolic hotkeys (Spotlight) from the plist
        shell(activateSettingsBin, "-u")

        print("[SettingsManager] Applied all keyboard changes")
    }

    // MARK: - Mouse Speed

    /// Save mouse speed preference only (for when game mode is off).
    ///
    /// Writes `com.apple.mouse.scaling` so the value is persisted for next apply,
    /// but does NOT change the live mouse speed.
    func persistMouseSpeed(_ mode: MouseMode) {
        let speed = speedFor(mode)

        shell(defaultsBin, "write", "-g",
              "com.apple.mouse.scaling", "-float", String(speed))

        print("[SettingsManager] Persisted mouse speed → \(speed) (\(mode)), not applied")
    }

    /// Change mouse speed immediately via IOKit HIDSystem.
    ///
    /// 1. Writes the preference (so it survives reboots).
    /// 2. Calls IOKit to change the HID driver's acceleration — takes effect
    ///    on the very next mouse movement, zero system lag.
    /// 3. Falls back to cfprefsd restart only if IOKit fails.
    func applyMouseSpeed(_ mode: MouseMode) {
        let speed = speedFor(mode)

        // Persist for reboots
        shell(defaultsBin, "write", "-g",
              "com.apple.mouse.scaling", "-float", String(speed))

        // Apply instantly via IOKit (no daemon restart!)
        if applyMouseSpeedViaIOKit(speed) {
            print("[SettingsManager] Mouse speed → \(speed) (\(mode)) via IOKit ✓")
        } else {
            // IOKit failed — fall back to cfprefsd restart (may cause brief lag)
            print("[SettingsManager] IOKit failed, falling back to cfprefsd restart")
            restartPreferencesDaemon()
            print("[SettingsManager] Mouse speed → \(speed) (\(mode)) via cfprefsd fallback")
        }
    }

    // MARK: - IOKit Mouse Acceleration

    /// Set mouse acceleration directly in the HID driver.
    /// Returns `true` on success, `false` if IOKit access failed.
    private func applyMouseSpeedViaIOKit(_ speed: Double) -> Bool {
        // Find the IOHIDSystem service
        guard let matching = IOServiceMatching("IOHIDSystem") else {
            print("[SettingsManager] IOServiceMatching returned nil")
            return false
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            print("[SettingsManager] IOHIDSystem service not found")
            return false
        }
        defer { IOObjectRelease(service) }

        // Open a parameter connection to the HID system
        var connect: io_connect_t = 0
        let openResult = IOServiceOpen(
            service, mach_task_self_, kIOHIDParamConnectType, &connect
        )
        guard openResult == kIOReturnSuccess else {
            print("[SettingsManager] IOServiceOpen failed: \(openResult)")
            return false
        }
        defer { IOServiceClose(connect) }

        // Set mouse acceleration — same 0.0–3.0+ scale as the preference
        let key = "HIDMouseAcceleration" as CFString
        let setResult = _IOHIDSetAccelerationWithKey(connect, key, speed)

        if setResult != kIOReturnSuccess {
            print("[SettingsManager] IOHIDSetAccelerationWithKey failed: \(setResult)")
            return false
        }

        return true
    }

    // MARK: - Helpers

    private func speedFor(_ mode: MouseMode) -> Double {
        switch mode {
        case .gaming: return gamingMouseSpeed
        case .normal: return normalMouseSpeed
        }
    }

    /// Kill `cfprefsd` for the current user so macOS re-reads preference plists.
    private func restartPreferencesDaemon() {
        shell(killallBin, "-u", NSUserName(), "cfprefsd")
    }

    // MARK: - Shell Execution

    /// Run an executable with arguments. Logs failures.
    @discardableResult
    private func shell(_ args: String...) -> (output: String, exitCode: Int32) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[SettingsManager] Failed to run \(args[0]): \(error)")
            return ("", -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            print("[SettingsManager] Command exited with \(process.terminationStatus): "
                  + "\(args.joined(separator: " "))")
            if !output.isEmpty { print("  stdout/stderr: \(output)") }
        }

        return (output, process.terminationStatus)
    }

    /// Run an executable and silently swallow errors (used for "delete key that may not exist").
    @discardableResult
    private func shellIgnoringErrors(_ args: String...) -> (output: String, exitCode: Int32) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("", -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }
}
