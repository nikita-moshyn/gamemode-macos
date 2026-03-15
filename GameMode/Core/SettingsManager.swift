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

private let kIOHIDParamConnectType: UInt32 = 1

@_silgen_name("IOHIDSetAccelerationWithKey")
private func _IOHIDSetAccelerationWithKey(
    _ handle: io_connect_t,
    _ key: CFString,
    _ acceleration: Double
) -> kern_return_t

// MARK: - SettingsManager

/// Handles macOS system settings changes.
///
/// Architecture:
///   - **Keyboard** — writes preferences, then applies with a single
///     `cfprefsd` restart + `activateSettings -u`.
///   - **Mouse** — writes preferences for persistence, then applies instantly
///     via IOKit HIDSystem (no daemon restart, no freeze).
///
/// No admin privileges required.
class SettingsManager {

    // MARK: - Executable Paths

    private let defaultsBin   = "/usr/bin/defaults"
    private let killallBin    = "/usr/bin/killall"
    private let plistBuddyBin = "/usr/libexec/PlistBuddy"
    private let activateSettingsBin =
        "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"

    // MARK: - Function Keys

    /// Write "Use F1, F2, etc. keys as standard function keys" preference.
    /// Does NOT apply — call `applyKeyboardChanges()` after.
    func writeFunctionKeys(enabled: Bool) {
        shell(defaultsBin, "write", "NSGlobalDomain",
              "com.apple.keyboard.fnState", "-bool", enabled ? "true" : "false")
        print("[Settings] Wrote function keys: standard=\(enabled)")
    }

    // MARK: - Keyboard Shortcuts

    /// Toggle a list of symbolic hotkey IDs.
    /// Only flips the `enabled` flag — never touches the key binding.
    /// Skips IDs that don't exist in the user's plist.
    func writeShortcuts(ids: [Int], enabled: Bool) {
        guard !ids.isEmpty else { return }

        let plistPath = "\(NSHomeDirectory())/Library/Preferences/com.apple.symbolichotkeys.plist"
        let value = enabled ? "true" : "false"

        for id in ids {
            let result = shell(
                plistBuddyBin,
                "-c", "Set :AppleSymbolicHotKeys:\(id):enabled \(value)",
                plistPath
            )
            if result.exitCode != 0 {
                print("[Settings] Shortcut \(id) not in plist — skipped")
            }
        }
        print("[Settings] Wrote \(ids.count) shortcuts: enabled=\(enabled)")
    }

    /// Apply all pending keyboard/shortcut changes in one shot.
    /// This is the ONLY place cfprefsd gets restarted.
    func applyKeyboardChanges() {
        restartPreferencesDaemon()
        shell(activateSettingsBin, "-u")
        print("[Settings] Applied keyboard changes")
    }

    // MARK: - Mouse Speed

    /// Read current mouse speed from system preferences.
    func readCurrentMouseSpeed() -> Double? {
        let result = shell(defaultsBin, "read", "-g", "com.apple.mouse.scaling")
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(trimmed)
    }

    /// Save mouse speed preference only (does not change live speed).
    func persistMouseSpeed(_ speed: Double) {
        shell(defaultsBin, "write", "-g",
              "com.apple.mouse.scaling", "-float", String(speed))
        print("[Settings] Persisted mouse speed: \(speed)")
    }

    /// Change mouse speed immediately via IOKit HIDSystem.
    /// Writes the preference for persistence, then applies via IOKit.
    /// Falls back to cfprefsd restart only if IOKit fails.
    func applyMouseSpeed(_ speed: Double) {
        shell(defaultsBin, "write", "-g",
              "com.apple.mouse.scaling", "-float", String(speed))

        if applyMouseSpeedViaIOKit(speed) {
            print("[Settings] Mouse speed: \(speed) via IOKit")
        } else {
            print("[Settings] IOKit failed, using cfprefsd fallback")
            restartPreferencesDaemon()
        }
    }

    // MARK: - IOKit Mouse

    private func applyMouseSpeedViaIOKit(_ speed: Double) -> Bool {
        guard let matching = IOServiceMatching("IOHIDSystem") else { return false }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        let openResult = IOServiceOpen(
            service, mach_task_self_, kIOHIDParamConnectType, &connect
        )
        guard openResult == kIOReturnSuccess else { return false }
        defer { IOServiceClose(connect) }

        let key = "HIDMouseAcceleration" as CFString
        return _IOHIDSetAccelerationWithKey(connect, key, speed) == kIOReturnSuccess
    }

    // MARK: - Helpers

    private func restartPreferencesDaemon() {
        shell(killallBin, "-u", NSUserName(), "cfprefsd")
    }

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
            print("[Settings] Failed to run \(args[0]): \(error)")
            return ("", -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            print("[Settings] Exit \(process.terminationStatus): "
                  + "\(args.joined(separator: " "))")
        }

        return (output, process.terminationStatus)
    }
}
