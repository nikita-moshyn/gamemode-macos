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
        print("[FnKeys:\(tag)] ━━━ START ━━━")

        // 1. Read current state from CFPreferences (ByHost)
        let cfBefore = readFunctionKeysEnabled()
        print("[FnKeys:\(tag)] CFPreferences read BEFORE: \(cfBefore)")

        // 2. Read raw plist file on disk to compare
        let diskBefore = readFnStateFromDisk()
        print("[FnKeys:\(tag)] Disk plist BEFORE: \(diskBefore ?? "nil (key missing)")")

        // 3. Read via defaults command for cross-check
        let defaultsBefore = readFnStateViaDefaults()
        print("[FnKeys:\(tag)] defaults read BEFORE: \(defaultsBefore ?? "nil (failed)")")

        // 4. Write
        print("[FnKeys:\(tag)] Writing \(enabled ? "kCFBooleanTrue" : "kCFBooleanFalse") to \(functionKeysPreferenceKey)...")
        CFPreferencesSetValue(
            functionKeysPreferenceKey,
            enabled ? kCFBooleanTrue : kCFBooleanFalse,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )

        // 5. Read back BEFORE sync
        let cfAfterWrite = readFunctionKeysEnabled()
        print("[FnKeys:\(tag)] CFPreferences read AFTER write (before sync): \(cfAfterWrite)")

        // 6. Synchronize
        let synced = CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        print("[FnKeys:\(tag)] CFPreferencesSynchronize returned: \(synced)")

        // 7. Read back AFTER sync
        let cfAfterSync = readFunctionKeysEnabled()
        print("[FnKeys:\(tag)] CFPreferences read AFTER sync: \(cfAfterSync)")

        // 8. Read disk AFTER sync
        let diskAfter = readFnStateFromDisk()
        print("[FnKeys:\(tag)] Disk plist AFTER sync: \(diskAfter ?? "nil (key missing)")")

        // 9. Cross-check with defaults
        let defaultsAfter = readFnStateViaDefaults()
        print("[FnKeys:\(tag)] defaults read AFTER sync: \(defaultsAfter ?? "nil (failed)")")

        // 10. Summary
        let success = cfAfterSync == enabled
        print("[FnKeys:\(tag)] ━━━ \(success ? "OK" : "FAILED") ━━━  requested=\(enabled) cfResult=\(cfAfterSync) disk=\(diskAfter ?? "nil")")
    }

    /// Read fnState directly from the ByHost plist file on disk.
    private func readFnStateFromDisk() -> String? {
        let byHostDir = NSHomeDirectory() + "/Library/Preferences/ByHost"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: byHostDir) else {
            return "ERROR: cannot list ByHost dir"
        }
        let globalFiles = files.filter { $0.hasPrefix(".GlobalPreferences.") && $0.hasSuffix(".plist") }
        print("[FnKeys:disk] ByHost plist files: \(globalFiles)")

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
                print("[FnKeys:verify] Verified: standard=\(enabled)")
                return true
            }
            usleep(100_000)
        } while Date() < deadline

        print("[FnKeys:verify] FAILED to verify: standard=\(enabled), actual=\(readFunctionKeysEnabled())")
        let diskVal = readFnStateFromDisk()
        let defaultsVal = readFnStateViaDefaults()
        print("[FnKeys:verify] disk=\(diskVal ?? "nil"), defaults=\(defaultsVal ?? "nil")")
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
        return states
    }

    /// Toggle a list of symbolic hotkey IDs.
    /// Only flips the `enabled` flag — never touches the key binding.
    /// Reads/writes the plist directly — no PlistBuddy subprocess.
    func writeShortcuts(ids: [Int], enabled: Bool) {
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
            print("[Settings] Cannot read symbolic hotkeys plist")
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

        print("[Settings] Wrote \(states.count) shortcut state(s)")
    }

    /// Apply all pending keyboard/shortcut changes in one shot.
    /// Signals cfprefsd to reload (SIGHUP, not kill) and schedules activateSettings
    /// at background priority after a short delay to avoid system stalls.
    func applyKeyboardChanges() {
        let fnBefore = readFunctionKeysEnabled()
        print("[Apply] fnState BEFORE signalPreferencesDaemon: \(fnBefore)")

        signalPreferencesDaemon()

        // Check if SIGHUP changed anything
        usleep(50_000) // 50ms for cfprefsd to process signal
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        let fnAfterSignal = readFunctionKeysEnabled()
        print("[Apply] fnState AFTER signalPreferencesDaemon: \(fnAfterSignal)")
        if fnBefore != fnAfterSignal {
            print("[Apply] ⚠️ WARNING: signalPreferencesDaemon CHANGED fnState from \(fnBefore) to \(fnAfterSignal)!")
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
            print("[Apply] fnState BEFORE activateSettings: \(fnBeforeActivate?.boolValue ?? false)")

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
                print("[Apply] activateSettings exit=\(task.terminationStatus) stderr=\(errStr.isEmpty ? "(empty)" : errStr)")
            } catch {
                print("[Apply] activateSettings FAILED: \(error)")
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
            print("[Apply] fnState AFTER activateSettings: \(fnAfterActivate?.boolValue ?? false)")
            if fnBeforeActivate?.boolValue != fnAfterActivate?.boolValue {
                print("[Apply] ⚠️ WARNING: activateSettings CHANGED fnState from \(fnBeforeActivate?.boolValue ?? false) to \(fnAfterActivate?.boolValue ?? false)!")
            }
        }
        print("[Apply] keyboard changes dispatched")
    }

    // MARK: - Mouse Speed

    /// Read current mouse speed from HIDSystem without touching preferences.
    func readCurrentMouseSpeed() -> Double? {
        withHIDSystemConnection { connection in
            var speed = 0.0
            let result = _IOHIDGetAccelerationWithKey(connection, mouseAccelerationKey, &speed)
            guard result == kIOReturnSuccess else { return nil }
            return speed
        }
    }

    /// Change mouse speed immediately via IOKit HIDSystem.
    @discardableResult
    func applyMouseSpeed(_ speed: Double) -> Bool {
        let applied = applyMouseSpeedViaIOKit(speed)
        if applied {
            print("[Settings] Mouse speed: \(speed) via IOKit")
        } else {
            print("[Settings] IOKit failed for mouse speed")
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
        print("[Settings] Captured \(captured.count) gesture value(s)")
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
        print("[Settings] Wrote \(entries.count) gesture(s) = \(value)")
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
        print("[Settings] Restored \(capturedValues.count) gesture(s)")
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

        print("[Keyboard] Captured: fnKeys=\(previousFnKeys as Any), shortcuts=\(previousShortcuts.count), gestures=\(previousGestures?.count ?? 0)")

        // 2. Apply gaming-mode changes
        if functionKeysEnabled {
            print("[Keyboard] Activating fn keys: \(previousFnKeys ?? false) → true")
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
            print("[Keyboard] Restoring fn keys → \(restoreTo)")
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

        print("[Keyboard] Restore complete (changed=\(didChange))")
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

        for i in 0..<actualCount {
            let name = withUnsafePointer(to: procs[i].kp_proc.p_comm) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            if name == "cfprefsd" {
                kill(procs[i].kp_proc.p_pid, SIGHUP)
            }
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
