//
//  SettingsManager.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Darwin
import Foundation
import IOKit

// MARK: - IOKit HIDSystem bridging

private let kIOHIDParamConnectType: UInt32 = 1

@_silgen_name("IOHIDSetAccelerationWithKey")
private func _IOHIDSetAccelerationWithKey(_ handle: io_connect_t, _ key: CFString, _ acceleration: Double) -> kern_return_t

@_silgen_name("IOHIDGetAccelerationWithKey")
private func _IOHIDGetAccelerationWithKey(_ handle: io_connect_t, _ key: CFString, _ acceleration: UnsafeMutablePointer<Double>) -> kern_return_t

// MARK: - SettingsManager

/// Handles macOS system settings changes.
///
/// Architecture:
///   - **Preferences** — uses CoreFoundation `CFPreferences` API directly
///     (in-process, no subprocess spawning).
///   - **Symbolic hotkeys** — reads/writes plist files directly via
///     `PropertyListSerialization` (no PlistBuddy subprocess).
///   - **Apply** — sends SIGHUP to cfprefsd (no kill+restart) and runs
///     `activateSettings -u` fire-and-forget.
///   - **Mouse** — applies instantly via IOKit HIDSystem (no daemon restart).
///
/// No admin privileges required.
class SettingsManager {

    private let activateSettingsBin = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
    private let functionKeysPreferenceKey = "com.apple.keyboard.fnState" as CFString
    private let legacyMouseScalingPreferenceKey = "com.apple.mouse.scaling" as CFString

    // MARK: - Function Keys

    func readFunctionKeysEnabled() -> Bool {
        let value = CFPreferencesCopyValue(
            functionKeysPreferenceKey,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? NSNumber
        return value?.boolValue ?? false
    }

    /// Write "Use F1, F2, etc. keys as standard function keys" preference.
    /// Does NOT apply — call `applyKeyboardChanges()` after.
    func writeFunctionKeys(enabled: Bool) {
        let tag = enabled ? "ACTIVATE" : "RESTORE"
        Log.debug("[FnKeys:\(tag)] ━━━ START ━━━", category: "FnKeys")

        // 1. Read current state from CFPreferences (ByHost)
        let cfBefore = readFunctionKeysEnabled()
        Log.debug("[FnKeys:\(tag)] CFPreferences read BEFORE: \(cfBefore)", category: "FnKeys")

        // 2. Read raw plist file on disk to compare
        let diskBefore = readFnStateFromDisk()
        Log.debug("[FnKeys:\(tag)] Disk plist BEFORE: \(diskBefore ?? "nil (key missing)")", category: "FnKeys")

        // 3. Read via defaults command for cross-check
        let defaultsBefore = readFnStateViaDefaults()
        Log.debug("[FnKeys:\(tag)] defaults read BEFORE: \(defaultsBefore ?? "nil (failed)")", category: "FnKeys")

        // 4. Write
        Log.debug("[FnKeys:\(tag)] Writing \(enabled ? "kCFBooleanTrue" : "kCFBooleanFalse") to \(functionKeysPreferenceKey)...", category: "FnKeys")
        CFPreferencesSetValue(
            functionKeysPreferenceKey,
            enabled ? kCFBooleanTrue : kCFBooleanFalse,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )

        // 5. Read back BEFORE sync
        let cfAfterWrite = readFunctionKeysEnabled()
        Log.debug("[FnKeys:\(tag)] CFPreferences read AFTER write (before sync): \(cfAfterWrite)", category: "FnKeys")

        // 6. Synchronize
        let synced = CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        Log.debug("[FnKeys:\(tag)] CFPreferencesSynchronize returned: \(synced)", category: "FnKeys")

        // 7. Read back AFTER sync
        let cfAfterSync = readFunctionKeysEnabled()
        Log.debug("[FnKeys:\(tag)] CFPreferences read AFTER sync: \(cfAfterSync)", category: "FnKeys")

        // 8. Read disk AFTER sync
        let diskAfter = readFnStateFromDisk()
        Log.debug("[FnKeys:\(tag)] Disk plist AFTER sync: \(diskAfter ?? "nil (key missing)")", category: "FnKeys")

        // 9. Cross-check with defaults
        let defaultsAfter = readFnStateViaDefaults()
        Log.debug("[FnKeys:\(tag)] defaults read AFTER sync: \(defaultsAfter ?? "nil (failed)")", category: "FnKeys")

        // 10. Summary
        let success = cfAfterSync == enabled
        if success {
            Log.debug("[FnKeys:\(tag)] ━━━ OK ━━━  requested=\(enabled) cfResult=\(cfAfterSync) disk=\(diskAfter ?? "nil")", category: "FnKeys")
        } else {
            Log.warning("[FnKeys:\(tag)] ━━━ FAILED ━━━  requested=\(enabled) cfResult=\(cfAfterSync) disk=\(diskAfter ?? "nil")", category: "FnKeys")
        }
    }

    /// Read fnState directly from the ByHost plist file on disk.
    private func readFnStateFromDisk() -> String? {
        let byHostDir = NSHomeDirectory() + "/Library/Preferences/ByHost"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: byHostDir) else {
            return "ERROR: cannot list ByHost dir"
        }
        let globalFiles = files.filter { $0.hasPrefix(".GlobalPreferences.") && $0.hasSuffix(".plist") }
        Log.debug("[FnKeys:disk] ByHost plist files: \(globalFiles)", category: "FnKeys")

        for file in globalFiles {
            let path = byHostDir + "/" + file
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                continue
            }
            if let val = plist["com.apple.keyboard.fnState"] {
                return "\(val) (in \(file))"
            }
        }
        return nil
    }

    /// Read fnState via `defaults` command for cross-check.
    private func readFnStateViaDefaults() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["-currentHost", "read", "-g", "com.apple.keyboard.fnState"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "ERROR: \(error)"
        }
    }

    /// Best-effort verification that the stored fn-state matches the requested value.
    func verifyFunctionKeysEnabled(_ enabled: Bool, timeout: TimeInterval = 1.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            CFPreferencesSynchronize(
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
            if readFunctionKeysEnabled() == enabled {
                Log.debug("[FnKeys:verify] Verified: standard=\(enabled)", category: "FnKeys")
                return true
            }
            usleep(100_000)
        } while Date() < deadline

        Log.warning("[FnKeys:verify] FAILED to verify: standard=\(enabled), actual=\(readFunctionKeysEnabled())", category: "FnKeys")
        let diskVal = readFnStateFromDisk()
        let defaultsVal = readFnStateViaDefaults()
        Log.warning("[FnKeys:verify] disk=\(diskVal ?? "nil"), defaults=\(defaultsVal ?? "nil")", category: "FnKeys")
        return false
    }

    // MARK: - Keyboard Shortcuts

    func captureShortcutStates(ids: [Int]) -> [Int: Bool] {
        guard !ids.isEmpty,
              let hotkeys = loadSymbolicHotkeysPlist() else { return [:] }

        var states: [Int: Bool] = [:]
        for id in ids {
            guard let entry = hotkeys[String(id)] as? [String: Any],
                  let enabled = entry["enabled"] as? Bool else { continue }
            states[id] = enabled
        }
        Log.debug("Captured \(states.count) shortcut state(s)", category: "Settings")
        return states
    }

    /// Toggle a list of symbolic hotkey IDs.
    /// Only flips the `enabled` flag — never touches the key binding.
    /// Reads/writes the plist directly — no PlistBuddy subprocess.
    func writeShortcuts(ids: [Int], enabled: Bool) {
        Log.info("\(enabled ? "Enabling" : "Disabling") \(ids.count) shortcut(s)", category: "Settings")
        let states = Dictionary(uniqueKeysWithValues: ids.map { ($0, enabled) })
        writeShortcutStates(states)
    }

    /// Restore exact symbolic hotkey enabled states.
    func writeShortcutStates(_ states: [Int: Bool]) {
        guard !states.isEmpty else { return }

        let plistPath = "\(NSHomeDirectory())/Library/Preferences/com.apple.symbolichotkeys.plist"
        let plistURL = URL(fileURLWithPath: plistPath)

        guard let data = try? Data(contentsOf: plistURL),
              var plist = try? PropertyListSerialization.propertyList(
                  from: data, options: .mutableContainersAndLeaves, format: nil
              ) as? [String: Any],
              var hotkeys = plist["AppleSymbolicHotKeys"] as? [String: Any] else {
            Log.error("Cannot read symbolic hotkeys plist", category: "Settings")
            return
        }

        for (id, enabled) in states {
            let key = String(id)
            if var entry = hotkeys[key] as? [String: Any] {
                entry["enabled"] = enabled
                hotkeys[key] = entry
            }
        }

        plist["AppleSymbolicHotKeys"] = hotkeys

        if let outData = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0
        ) {
            try? outData.write(to: plistURL, options: .atomic)
        }

        Log.info("Wrote \(states.count) shortcut state(s)", category: "Settings")
    }

    /// Apply all pending keyboard/shortcut changes in one shot.
    /// Signals cfprefsd to reload (SIGHUP, not kill) and schedules activateSettings
    /// at background priority after a short delay to avoid system stalls.
    func applyKeyboardChanges() {
        let fnBefore = readFunctionKeysEnabled()
        Log.debug("[Apply] fnState BEFORE signalPreferencesDaemon: \(fnBefore)", category: "Settings")

        signalPreferencesDaemon()

        // Check if SIGHUP changed anything
        usleep(50_000) // 50ms for cfprefsd to process signal
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        let fnAfterSignal = readFunctionKeysEnabled()
        Log.debug("[Apply] fnState AFTER signalPreferencesDaemon: \(fnAfterSignal)", category: "Settings")
        if fnBefore != fnAfterSignal {
            Log.warning("[Apply] signalPreferencesDaemon CHANGED fnState from \(fnBefore) to \(fnAfterSignal)", category: "Settings")
        }

        // Schedule activateSettings with post-check
        let bin = activateSettingsBin
        let fnKeyPref = functionKeysPreferenceKey
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.5) {
            let fnBeforeActivate = CFPreferencesCopyValue(
                fnKeyPref,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            ) as? NSNumber
            Log.debug("[Apply] fnState BEFORE activateSettings: \(fnBeforeActivate?.boolValue ?? false)", category: "Settings")

            let task = Process()
            task.executableURL = URL(fileURLWithPath: bin)
            task.arguments = ["-u"]
            let errPipe = Pipe()
            task.standardOutput = FileHandle.nullDevice
            task.standardError = errPipe
            do {
                try task.run()
                task.waitUntilExit()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                Log.debug("[Apply] activateSettings exit=\(task.terminationStatus) stderr=\(errStr.isEmpty ? "(empty)" : errStr)", category: "Settings")
            } catch {
                Log.error("[Apply] activateSettings FAILED: \(error)", category: "Settings")
            }

            // Check if activateSettings changed fnState
            CFPreferencesSynchronize(
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
            let fnAfterActivate = CFPreferencesCopyValue(
                fnKeyPref,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            ) as? NSNumber
            Log.debug("[Apply] fnState AFTER activateSettings: \(fnAfterActivate?.boolValue ?? false)", category: "Settings")
            if fnBeforeActivate?.boolValue != fnAfterActivate?.boolValue {
                Log.warning("[Apply] activateSettings CHANGED fnState from \(fnBeforeActivate?.boolValue ?? false) to \(fnAfterActivate?.boolValue ?? false)", category: "Settings")
            }
        }
        Log.debug("[Apply] keyboard changes dispatched", category: "Settings")
    }

    // MARK: - Mouse Speed

    /// Read current mouse speed from HIDSystem without touching preferences.
    func readCurrentMouseSpeed() -> Double? {
        let speed = withHIDSystemConnection { connection -> Double? in
            var speed = 0.0
            let result = _IOHIDGetAccelerationWithKey(connection, mouseAccelerationKey, &speed)
            guard result == kIOReturnSuccess else { return nil }
            return speed
        }
        if speed == nil {
            Log.error("Failed to read current mouse speed from IOKit", category: "Mouse")
        }
        return speed
    }

    /// Change mouse speed immediately via IOKit HIDSystem.
    @discardableResult
    func applyMouseSpeed(_ speed: Double) -> Bool {
        let applied = applyMouseSpeedViaIOKit(speed)
        if applied {
            Log.info("Mouse speed set to \(speed) via IOKit", category: "Mouse")
        } else {
            Log.error("IOKit failed to set mouse speed", category: "Mouse")
        }
        return applied
    }

    // MARK: - IOKit Mouse

    private func applyMouseSpeedViaIOKit(_ speed: Double) -> Bool {
        withHIDSystemConnection { connection in
            _IOHIDSetAccelerationWithKey(connection, mouseAccelerationKey, speed) == kIOReturnSuccess
        } ?? false
    }

    // MARK: - Gestures

    /// Capture current gesture values before disabling them.
    /// Returns a dictionary of [preferenceKey: [domain: originalValueOrNil]].
    func captureGestureValues(entries: [GestureEntry]) -> GesturePreferenceValues {
        var captured: GesturePreferenceValues = [:]
        for entry in entries {
            var domainValues: [String: Int?] = [:]
            for domain in entry.domains {
                let value = CFPreferencesCopyValue(
                    entry.id as CFString,
                    domain as CFString,
                    kCFPreferencesCurrentUser,
                    kCFPreferencesCurrentHost
                )
                if let number = value as? NSNumber {
                    domainValues[domain] = number.intValue
                } else {
                    domainValues[domain] = nil
                }
            }
            captured[entry.id] = domainValues
        }
        Log.debug("Captured \(captured.count) gesture value(s)", category: "Settings")
        return captured
    }

    /// Write gesture preferences. Pass 0 to disable, or original value to restore.
    /// Writes to ALL domains for each entry.
    func writeGestures(entries: [GestureEntry], value: Int) {
        var updatedDomains = Set<String>()
        for entry in entries {
            for domain in entry.domains {
                CFPreferencesSetValue(
                    entry.id as CFString,
                    NSNumber(value: value),
                    domain as CFString,
                    kCFPreferencesCurrentUser,
                    kCFPreferencesCurrentHost
                )
                updatedDomains.insert(domain)
            }
        }
        synchronizePreferences(domains: updatedDomains)
        Log.info("Wrote \(entries.count) gesture(s) = \(value)", category: "Settings")
    }

    /// Restore gestures from previously captured values.
    func restoreGestures(capturedValues: GesturePreferenceValues) {
        var updatedDomains = Set<String>()
        for (gestureID, domainValues) in capturedValues {
            for (domain, original) in domainValues {
                CFPreferencesSetValue(
                    gestureID as CFString,
                    original.map { NSNumber(value: $0) },
                    domain as CFString,
                    kCFPreferencesCurrentUser,
                    kCFPreferencesCurrentHost
                )
                updatedDomains.insert(domain)
            }
        }
        synchronizePreferences(domains: updatedDomains)
        Log.info("Restored \(capturedValues.count) gesture(s)", category: "Settings")
    }

    // MARK: - Unified Keyboard Settings (fn keys + shortcuts + gestures)

    /// Snapshot of all keyboard-related state before gaming mode changes.
    struct KeyboardSnapshot {
        var previousFunctionKeysEnabled: Bool?
        var previousShortcutStates: [Int: Bool]?
        var shortcutIDsToDisable: [Int]
        var previousGestureValues: GesturePreferenceValues?
        var gesturesToDisable: [GestureEntry]
    }

    /// Capture current keyboard state, apply gaming-mode changes, and return
    /// the snapshot needed for restoration. One call does everything.
    func activateKeyboardSettings(functionKeysEnabled: Bool, shortcutIDs: [Int], gestures: [GestureEntry]) -> KeyboardSnapshot {
        // 1. Capture baselines
        let previousFnKeys = functionKeysEnabled ? readFunctionKeysEnabled() : nil
        let previousShortcuts = captureShortcutStates(ids: shortcutIDs)
        let shortcutIDsToDisable = previousShortcuts.filter(\.value).map(\.key)
        let previousGestures = gestures.isEmpty ? nil : captureGestureValues(entries: gestures)

        Log.debug("Captured: fnKeys=\(previousFnKeys as Any), shortcuts=\(previousShortcuts.count), gestures=\(previousGestures?.count ?? 0)", category: "Keyboard")

        // 2. Apply gaming-mode changes
        if functionKeysEnabled {
            Log.info("Activating fn keys: \(previousFnKeys ?? false) → true", category: "Keyboard")
            writeFunctionKeys(enabled: true)
        }
        if !shortcutIDsToDisable.isEmpty {
            writeShortcuts(ids: shortcutIDsToDisable, enabled: false)
        }
        if !gestures.isEmpty {
            writeGestures(entries: gestures, value: 0)
        }

        // 3. Flush to system
        if functionKeysEnabled || !shortcutIDsToDisable.isEmpty || !gestures.isEmpty {
            applyKeyboardChanges()
        }

        return KeyboardSnapshot(previousFunctionKeysEnabled: previousFnKeys,
                                previousShortcutStates: previousShortcuts.isEmpty ? nil : previousShortcuts,
                                shortcutIDsToDisable: shortcutIDsToDisable,
                                previousGestureValues: previousGestures,
                                gesturesToDisable: gestures)
    }

    /// Restore all keyboard settings from a journal's AppliedChanges.
    func restoreKeyboardSettings(from changes: AppliedChanges) {
        var didChange = false

        // 1. Restore fn keys
        if changes.functionKeysChanged {
            let restoreTo = changes.previousFunctionKeysEnabled ?? false
            Log.info("Restoring fn keys → \(restoreTo)", category: "Keyboard")
            writeFunctionKeys(enabled: restoreTo)
            didChange = true
        }

        // 2. Restore shortcuts
        if let previousStates = changes.previousShortcutStates {
            writeShortcutStates(previousStates)
            didChange = true
        } else if !changes.disabledShortcutIDs.isEmpty {
            writeShortcuts(ids: changes.disabledShortcutIDs, enabled: true)
            didChange = true
        }

        // 3. Restore gestures
        if changes.gesturesChanged, let previousValues = changes.previousGestureValues {
            restoreGestures(capturedValues: previousValues)
            didChange = true
        }

        // 4. Flush to system
        if didChange {
            applyKeyboardChanges()
        }

        Log.info("Keyboard restore complete (changed=\(didChange))", category: "Keyboard")
    }

    // MARK: - Helpers

    private let mouseAccelerationKey = "HIDMouseAcceleration" as CFString

    private func withHIDSystemConnection<T>(_ body: (io_connect_t) -> T?) -> T? {
        guard let matching = IOServiceMatching("IOHIDSystem") else { return nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        let openResult = IOServiceOpen(
            service,
            mach_task_self_,
            kIOHIDParamConnectType,
            &connect
        )
        guard openResult == kIOReturnSuccess else { return nil }
        defer { IOServiceClose(connect) }

        return body(connect)
    }

    private func loadSymbolicHotkeysPlist() -> [String: Any]? {
        let plistPath = "\(NSHomeDirectory())/Library/Preferences/com.apple.symbolichotkeys.plist"
        let plistURL = URL(fileURLWithPath: plistPath)

        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil) as? [String: Any] else {
            return nil
        }

        return plist["AppleSymbolicHotKeys"] as? [String: Any]
    }

    /// Send SIGHUP to cfprefsd to reload preferences without killing it.
    /// Uses sysctl to find the PID — zero subprocess spawning.
    private func signalPreferencesDaemon() {
        let uid = getuid()

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(uid)]
        var bufferSize: Int = 0

        // First call to get size
        guard sysctl(&mib, UInt32(mib.count), nil, &bufferSize, nil, 0) == 0,
              bufferSize > 0 else { return }

        let count = bufferSize / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

        guard sysctl(&mib, UInt32(mib.count), &procs, &bufferSize, nil, 0) == 0 else { return }

        let actualCount = bufferSize / MemoryLayout<kinfo_proc>.stride

        var signaled = false
        for i in 0..<actualCount {
            let name = withUnsafePointer(to: procs[i].kp_proc.p_comm) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            if name == "cfprefsd" {
                kill(procs[i].kp_proc.p_pid, SIGHUP)
                signaled = true
            }
        }
        if signaled {
            Log.debug("Sent SIGHUP to cfprefsd", category: "Settings")
        } else {
            Log.warning("cfprefsd not found for SIGHUP", category: "Settings")
        }
    }

    private func synchronizePreferences(domains: Set<String>) {
        guard !domains.isEmpty else { return }
        for domain in domains {
            CFPreferencesSynchronize(domain as CFString,
                                     kCFPreferencesCurrentUser,
                                     kCFPreferencesCurrentHost)
        }
    }
}
