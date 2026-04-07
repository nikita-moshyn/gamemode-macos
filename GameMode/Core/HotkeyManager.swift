//
//  HotkeyManager.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import Carbon

/// Manages system-wide keyboard shortcut monitoring for GameMode actions.
///
/// Uses Carbon `RegisterEventHotKey` to register exclusive system-wide hotkeys.
/// Unlike NSEvent global monitors, Carbon hotkeys actually **consume** the key
/// event so it doesn't reach the foreground app.
class HotkeyManager {

    private var registeredHotkeys: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    fileprivate static var sharedInstance: HotkeyManager?

    // MARK: - Registration

    /// Register hotkeys with their action handlers.
    /// Re-installs Carbon hotkey registrations each time.
    func register(hotkeys: [AppHotkey], handlers: [String: () -> Void]) {
        unregisterAll()

        let activeHotkeys = hotkeys.filter { $0.isEnabled && $0.keyCode != nil }
        guard !activeHotkeys.isEmpty else { return }

        // Store self for the C callback
        HotkeyManager.sharedInstance = self

        // Install the Carbon event handler (once)
        if eventHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                carbonHotkeyCallback,
                1,
                &eventType,
                nil,
                &eventHandler
            )
            if status != noErr {
                Log.error("Failed to install Carbon event handler: \(status)", category: "Hotkeys")
                return
            }
        }

        // Register each hotkey
        for (index, hotkey) in activeHotkeys.enumerated() {
            guard let keyCode = hotkey.keyCode else { continue }

            let carbonMods = carbonModifiers(from: NSEvent.ModifierFlags(rawValue: hotkey.modifiers))
            let hotkeyID = EventHotKeyID(signature: fourCharCode("GMOD"), id: UInt32(index))

            var hotkeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                carbonMods,
                hotkeyID,
                GetApplicationEventTarget(),
                0,
                &hotkeyRef
            )

            if status == noErr, let ref = hotkeyRef {
                registeredHotkeys.append(ref)
                self.handlers[UInt32(index)] = handlers[hotkey.id]
            } else {
                Log.error("Failed to register hotkey \(hotkey.name): \(status)", category: "Hotkeys")
            }
        }

        Log.info("Registered \(registeredHotkeys.count) hotkey(s) via Carbon", category: "Hotkeys")
    }

    /// Remove all registered hotkeys.
    func unregisterAll() {
        if !registeredHotkeys.isEmpty {
            Log.debug("Unregistered \(registeredHotkeys.count) hotkey(s)", category: "Hotkeys")
        }
        for ref in registeredHotkeys {
            UnregisterEventHotKey(ref)
        }
        registeredHotkeys.removeAll()
        handlers.removeAll()
    }

    // MARK: - Carbon Event Handling

    fileprivate func handleHotKeyEvent(_ event: EventRef) {
        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )
        guard status == noErr else { return }

        if let handler = handlers[hotkeyID.id] {
            Log.debug("Hotkey triggered: id=\(hotkeyID.id)", category: "Hotkeys")
            DispatchQueue.main.async {
                handler()
            }
        }
    }

    // MARK: - Helpers

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return mods
    }

    private func fourCharCode(_ string: String) -> OSType {
        var result: OSType = 0
        for char in string.utf8.prefix(4) {
            result = (result << 8) | OSType(char)
        }
        return result
    }

    // MARK: - Accessibility Check

    /// Returns true if the app has Accessibility permission (required for global hotkeys).
    static var isAccessibilityGranted: Bool {
        return AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility permission.
    static func requestAccessibilityPermission() {
        Log.info("Requesting accessibility permission", category: "Hotkeys")
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    deinit {
        unregisterAll()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
        if HotkeyManager.sharedInstance === self {
            HotkeyManager.sharedInstance = nil
        }
    }
}

// MARK: - Carbon Callback (C function pointer)

private func carbonHotkeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event else { return OSStatus(eventNotHandledErr) }
    HotkeyManager.sharedInstance?.handleHotKeyEvent(event)
    return noErr
}
