//
//  SettingsManager.swift
//  GameMode
//
//  Created by Nikita Moshyn on 13/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.hidsystem

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
///   - **Function keys** — temporary, verified HID mode changes; leaves the
///     user's saved keyboard preferences alone.
///   - **Gesture preferences** — uses CoreFoundation `CFPreferences` directly.
///   - **System shortcuts** — blocks configured symbolic hotkeys with a
///     process-owned event tap instead of rewriting system shortcut files.
///   - **Apply** — avoids `cfprefsd` signals and private `activateSettings`
///     calls in the toggle path.
///   - **Mouse** — applies instantly via IOKit HIDSystem (no daemon restart).
///
/// No admin privileges required.
class SettingsManager {

    private let legacyMouseScalingPreferenceKey = "com.apple.mouse.scaling" as CFString
    private let functionKeys: FunctionKeyAccess
    private let shortcutBlocker: SystemShortcutBlocker

    init(shortcutBlocker: SystemShortcutBlocker = SystemShortcutBlocker(), functionKeys: FunctionKeyAccess = .live) {
        self.shortcutBlocker = shortcutBlocker
        self.functionKeys = functionKeys
    }

    /// Release process-owned effects after an explicit recovery reset, without writing preferences.
    func stopOwnedEffects() {
        shortcutBlocker.stopBlocking()
    }

    // MARK: - Function Keys

    /// A saved fnState preference can disagree with the active keyboard mode.
    /// A failed HID read must never become an invented "media keys" baseline.
    func readFunctionKeysEnabled() -> Bool? {
        functionKeys.read()
    }

    /// Apply immediately without persisting a gaming preference across logins.
    /// Success requires both a successful HID setter and matching live readback.
    @discardableResult
    func writeFunctionKeys(enabled: Bool) -> Bool {
        guard functionKeys.apply(enabled) else {
            Log.error("IOKit failed to set function-key mode", category: "FnKeys")
            return false
        }
        guard verifyFunctionKeysEnabled(enabled) else { return false }
        Log.info("Fn keys set to \(enabled ? "standard" : "media") mode via IOKit", category: "FnKeys")
        return true
    }

    /// Verify the active HID mode, not a cached or stored preference.
    func verifyFunctionKeysEnabled(_ enabled: Bool, timeout: TimeInterval = 1.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if readFunctionKeysEnabled() == enabled {
                Log.debug("[FnKeys:verify] Verified: standard=\(enabled)", category: "FnKeys")
                return true
            }
            guard Date() < deadline else { break }
            usleep(100_000)
        } while Date() < deadline

        Log.warning("[FnKeys:verify] FAILED to verify: standard=\(enabled), actual=\(String(describing: readFunctionKeysEnabled()))", category: "FnKeys")
        return false
    }

    /// Injectable at the system boundary so regression tests never touch a keyboard.
    struct FunctionKeyAccess {
        var read: () -> Bool?
        var apply: (Bool) -> Bool
        var restoreLegacyPreference: (Bool) -> Bool

        static var live: Self {
            Self(read: {
                SettingsManager.withHIDSystemConnection { connection in
                    var value: Unmanaged<CFTypeRef>?
                    let result = IOHIDCopyCFTypeParameter(connection, kIOHIDFKeyModeKey as CFString, &value)
                    let parameter = value?.takeRetainedValue()
                    guard result == kIOReturnSuccess, let number = parameter as? NSNumber,
                          number.intValue == 0 || number.intValue == 1 else { return nil }
                    return number.boolValue
                }
            }, apply: { enabled in
                SettingsManager.withHIDSystemConnection { connection in
                    IOHIDSetCFTypeParameter(connection, kIOHIDFKeyModeKey as CFString, NSNumber(value: enabled ? 1 : 0)) == kIOReturnSuccess
                } ?? false
            }, restoreLegacyPreference: { enabled in
                // Releases through beta.3 persisted this host-specific preference.
                // Only their pending recovery records authorize writing it back.
                let key = "com.apple.keyboard.fnState" as CFString
                CFPreferencesSetValue(key, enabled ? kCFBooleanTrue : kCFBooleanFalse,
                                      kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
                guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) else { return false }
                return (CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? NSNumber)?.boolValue == enabled
            })
        }
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

    /// Apply all pending keyboard/shortcut changes in one shot.
    /// Intentionally avoids `cfprefsd` signals and private `activateSettings -u`.
    func applyKeyboardChanges() {
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        Log.debug("Keyboard preferences synchronized without daemon reload", category: "Settings")
    }

    // MARK: - Mouse Speed

    /// Read current mouse speed from HIDSystem without touching preferences.
    func readCurrentMouseSpeed() -> Double? {
        let speed = Self.withHIDSystemConnection { connection -> Double? in
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
        Self.withHIDSystemConnection { connection in
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
                    domainValues.updateValue(nil, forKey: domain)
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
    @discardableResult
    func restoreGestures(capturedValues: GesturePreferenceValues) -> Bool {
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
        let synchronized = synchronizePreferences(domains: updatedDomains)
        Log.info("Restored \(capturedValues.count) gesture(s)", category: "Settings")
        return synchronized
    }

    // MARK: - Unified Keyboard Settings (fn keys + shortcuts + gestures)

    /// Snapshot of all keyboard-related state before gaming mode changes.
    struct KeyboardSnapshot {
        var functionKeysChanged: Bool
        var previousFunctionKeysEnabled: Bool?
        var previousShortcutStates: [Int: Bool]?
        var shortcutIDsToDisable: [Int]
        var previousGestureValues: GesturePreferenceValues?
        var gesturesToDisable: [GestureEntry]
    }

    /// Capture baselines without modifying system settings. Persist this before applying it.
    func captureKeyboardSettings(functionKeysEnabled: Bool, shortcutIDs: [Int], gestures: [GestureEntry]) throws -> KeyboardSnapshot {
        let previousFnKeys = functionKeysEnabled ? readFunctionKeysEnabled() : nil
        guard !functionKeysEnabled || previousFnKeys != nil else {
            throw RecoveryController.Failure.message("The current function-key mode could not be read. Keyboard settings were not changed.")
        }
        let previousShortcuts = captureShortcutStates(ids: shortcutIDs)
        let shortcutIDsToDisable = previousShortcuts.filter(\.value).map(\.key)
        let previousGestures = gestures.isEmpty ? nil : captureGestureValues(entries: gestures)
        let shouldChangeFunctionKeys = functionKeysEnabled && previousFnKeys != true

        Log.debug("Captured: fnKeys=\(previousFnKeys as Any), shortcuts=\(previousShortcuts.count), gestures=\(previousGestures?.count ?? 0)", category: "Keyboard")

        return KeyboardSnapshot(functionKeysChanged: shouldChangeFunctionKeys,
                                previousFunctionKeysEnabled: previousFnKeys,
                                previousShortcutStates: previousShortcuts.isEmpty ? nil : previousShortcuts,
                                shortcutIDsToDisable: shortcutIDsToDisable,
                                previousGestureValues: previousGestures,
                                gesturesToDisable: gestures)
    }

    /// Apply a durably checkpointed snapshot using the existing system-write order.
    func applyKeyboardSettings(_ snapshot: KeyboardSnapshot) throws {
        if snapshot.functionKeysChanged {
            Log.info("Activating fn keys: \(snapshot.previousFunctionKeysEnabled ?? false) → true", category: "Keyboard")
            guard writeFunctionKeys(enabled: true) else {
                throw RecoveryController.Failure.message("Function-key mode could not be applied and verified. Its original setting is saved for recovery.")
            }
        }
        if !snapshot.shortcutIDsToDisable.isEmpty {
            try shortcutBlocker.startBlocking(shortcutIDs: snapshot.shortcutIDsToDisable)
        }
        if !snapshot.gesturesToDisable.isEmpty {
            writeGestures(entries: snapshot.gesturesToDisable, value: 0)
        }

        if !snapshot.gesturesToDisable.isEmpty {
            applyKeyboardChanges()
        }
    }

    /// Restore all keyboard settings from a journal's AppliedChanges.
    @discardableResult
    func restoreKeyboardSettings(from changes: AppliedChanges) -> [String] {
        var didChange = false
        var failures: [String] = []

        // 1. Restore fn keys
        if changes.functionKeysChanged {
            if let restoreTo = changes.previousFunctionKeysEnabled {
                Log.info("Restoring fn keys → \(restoreTo)", category: "Keyboard")
                if changes.functionKeysWerePersisted, !functionKeys.restoreLegacyPreference(restoreTo) {
                    failures.append("Original function-key preference could not be saved")
                }
                if !writeFunctionKeys(enabled: restoreTo) {
                    failures.append("Original function-key mode could not be applied and verified")
                }
            } else {
                failures.append("Original function-key setting is missing")
            }
        }

        // 2. Stop process-owned shortcut blocking. System shortcut preferences were never changed.
        if changes.previousShortcutStates != nil || !changes.disabledShortcutIDs.isEmpty {
            shortcutBlocker.stopBlocking()
        }
        if changes.shortcutsWerePersisted {
            if let states = changes.previousShortcutStates {
                failures.append(contentsOf: restorePersistedShortcutStates(states))
            } else if !changes.disabledShortcutIDs.isEmpty {
                failures.append("Original system shortcut settings are missing")
            }
        }

        // 3. Restore gestures
        if changes.gesturesChanged {
            if let previousValues = changes.previousGestureValues, !previousValues.isEmpty {
                var resolvedValues = previousValues
                for (gestureID, domains) in previousValues where domains.isEmpty {
                    failures.append("Original preference domains are missing for \(gestureID)")
                    resolvedValues.removeValue(forKey: gestureID)
                }
                for (gestureID, domains) in previousValues where domains.keys.contains("legacy") {
                    guard let entry = GestureEntry.defaults.first(where: { $0.id == gestureID }),
                          let original = domains["legacy"] else {
                        failures.append("Original preference domains are missing for \(gestureID)")
                        resolvedValues.removeValue(forKey: gestureID)
                        continue
                    }
                    resolvedValues[gestureID] = Dictionary(uniqueKeysWithValues: entry.domains.map { ($0, original) })
                }
                if !restoreGestures(capturedValues: resolvedValues) {
                    failures.append("Gesture preferences could not be saved")
                }
                failures.append(contentsOf: verifyGestureValues(resolvedValues))
                didChange = true
            } else {
                failures.append("Original gesture settings are missing")
            }
        }

        // 4. Flush to system
        if didChange {
            applyKeyboardChanges()
        }

        Log.info("Keyboard restore complete (changed=\(didChange || changes.functionKeysChanged), failures=\(failures.count))", category: "Keyboard")
        return failures
    }

    private func verifyGestureValues(_ values: GesturePreferenceValues) -> [String] {
        var failures: [String] = []
        for (gestureID, domains) in values {
            for (domain, expected) in domains {
                let value = CFPreferencesCopyValue(gestureID as CFString, domain as CFString,
                                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
                let matches = expected.map { (value as? NSNumber)?.intValue == $0 } ?? (value == nil)
                if !matches {
                    failures.append("Gesture \(gestureID) could not be verified in \(domain)")
                }
            }
        }
        return failures
    }

    /// Older releases persisted shortcut flags; current releases only own an event tap.
    private func restorePersistedShortcutStates(_ states: [Int: Bool]) -> [String] {
        guard !states.isEmpty else { return [] }
        guard var hotkeys = loadSymbolicHotkeysPlist() else {
            return ["System shortcut preferences could not be read"]
        }
        var failures: [String] = []
        for (id, enabled) in states {
            guard var entry = hotkeys[String(id)] as? [String: Any] else {
                failures.append("System shortcut \(id) is unavailable")
                continue
            }
            entry["enabled"] = enabled
            hotkeys[String(id)] = entry
        }
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesSetValue("AppleSymbolicHotKeys" as CFString, hotkeys as CFDictionary,
                              domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return failures + ["System shortcut preferences could not be saved"]
        }
        let restored = captureShortcutStates(ids: Array(states.keys))
        for (id, expected) in states where restored[id] != expected {
            failures.append("System shortcut \(id) could not be verified")
        }
        return failures
    }

    // MARK: - Helpers

    private let mouseAccelerationKey = "HIDMouseAcceleration" as CFString

    private static func withHIDSystemConnection<T>(_ body: (io_connect_t) -> T?) -> T? {
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

    @discardableResult
    private func synchronizePreferences(domains: Set<String>) -> Bool {
        var succeeded = true
        for domain in domains {
            if !CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) {
                succeeded = false
            }
        }
        return succeeded
    }
}

final class SystemShortcutBlocker {
    struct BlockedShortcut: Hashable {
        let keyCode: Int64
        let modifierMask: UInt64
    }

    struct EventTap {
        var setEnabled: (Bool) -> Void
        var invalidate: () -> Void
    }

    enum Failure: LocalizedError {
        case eventTapUnavailable

        var errorDescription: String? {
            "Input Guard could not start shortcut blocking. Allow Accessibility access for GameMode in System Settings, then retry recovery before enabling Game Mode again."
        }
    }

    typealias EventHandler = (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private final class CallbackContext {
        let handler: EventHandler
        init(handler: @escaping EventHandler) { self.handler = handler }
    }

    private static let shortcutModifierMask = CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskCommand.rawValue
    private let readShortcuts: ([Int]) -> Set<BlockedShortcut>
    private let installTap: (@escaping EventHandler) -> EventTap?
    // The tap callback, its lifetime, and the lookup set all belong to the main run loop.
    private var eventTap: EventTap?
    private var blockedShortcuts = Set<BlockedShortcut>()

    init(readShortcuts: @escaping ([Int]) -> Set<BlockedShortcut> = SystemShortcutBlocker.loadShortcuts, installTap: @escaping (@escaping EventHandler) -> EventTap? = SystemShortcutBlocker.installEventTap) {
        self.readShortcuts = readShortcuts
        self.installTap = installTap
    }

    func startBlocking(shortcutIDs: [Int]) throws {
        try performOnMain { try startBlockingOnMain(shortcutIDs: shortcutIDs) }
    }

    func stopBlocking() {
        performOnMain { stopBlockingOnMain() }
    }

    private func startBlockingOnMain(shortcutIDs: [Int]) throws {
        let shortcuts = readShortcuts(shortcutIDs)
        guard !shortcuts.isEmpty else {
            stopBlockingOnMain()
            return
        }

        blockedShortcuts = shortcuts
        if let eventTap {
            eventTap.setEnabled(true)
            Log.info("Updated shortcut blocker with \(shortcuts.count) shortcut(s)", category: "Settings")
            return
        }

        guard let tap = installTap({ [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            return self.handleEvent(type: type, event: event)
        }) else {
            blockedShortcuts.removeAll()
            throw Failure.eventTapUnavailable
        }
        eventTap = tap
        tap.setEnabled(true)
        Log.info("Started shortcut blocker with \(shortcuts.count) shortcut(s)", category: "Settings")
    }

    private static func installEventTap(handler: @escaping EventHandler) -> EventTap? {
        let context = CallbackContext(handler: handler)
        let events = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            return Unmanaged<CallbackContext>.fromOpaque(userInfo).takeUnretainedValue().handler(type, event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(events),
            callback: callback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else { return nil }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return EventTap(setEnabled: { CGEvent.tapEnable(tap: tap, enable: $0) }, invalidate: {
            // Keep userInfo alive until the main run loop can no longer call it.
            withExtendedLifetime(context) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                CFMachPortInvalidate(tap)
            }
        })
    }

    private func stopBlockingOnMain() {
        eventTap?.setEnabled(false)
        eventTap?.invalidate()
        eventTap = nil
        blockedShortcuts.removeAll()
        Log.info("Stopped shortcut blocker", category: "Settings")
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        precondition(Thread.isMainThread)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            eventTap?.setEnabled(true)
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = event.flags.rawValue & Self.shortcutModifierMask
        let shortcut = BlockedShortcut(keyCode: keyCode, modifierMask: modifiers)
        guard blockedShortcuts.contains(shortcut) else {
            return Unmanaged.passUnretained(event)
        }

        Log.debug("Blocked system shortcut keyCode=\(keyCode) modifiers=\(modifiers)", category: "Settings")
        return nil
    }

    private static func loadShortcuts(ids: [Int]) -> Set<BlockedShortcut> {
        guard !ids.isEmpty,
              let hotkeys = loadSymbolicHotkeysPlist() else { return [] }

        var shortcuts = Set<BlockedShortcut>()
        for id in ids {
            guard let entry = hotkeys[String(id)] as? [String: Any],
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any],
                  parameters.count >= 3,
                  let keyCode = parameters[1] as? Int,
                  let modifiers = parameters[2] as? Int,
                  keyCode != 65_535 else { continue }
            shortcuts.insert(
                BlockedShortcut(
                    keyCode: Int64(keyCode),
                    modifierMask: UInt64(modifiers) & shortcutModifierMask
                )
            )
        }
        return shortcuts
    }

    private static func loadSymbolicHotkeysPlist() -> [String: Any]? {
        let plistURL = URL(
            fileURLWithPath: "\(NSHomeDirectory())/Library/Preferences/com.apple.symbolichotkeys.plist"
        )

        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: .mutableContainersAndLeaves,
                  format: nil
              ) as? [String: Any] else {
            return nil
        }

        return plist["AppleSymbolicHotKeys"] as? [String: Any]
    }

    private func performOnMain<T>(_ action: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try action() }
        return try DispatchQueue.main.sync(execute: action)
    }

    deinit {
        let tap = eventTap
        if Thread.isMainThread { tap?.invalidate() }
        else { DispatchQueue.main.sync { tap?.invalidate() } }
    }
}
