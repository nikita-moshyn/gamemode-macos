//
//  HotkeyManager.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit

/// Manages system-wide keyboard shortcut monitoring for GameMode actions.
///
/// Uses `NSEvent.addGlobalMonitorForEvents` (when app is not focused) and
/// `NSEvent.addLocalMonitorForEvents` (when app is focused) to catch
/// key combos system-wide. Requires Accessibility permission.
class HotkeyManager {

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hotkeys: [AppHotkey] = []
    private var handlers: [String: () -> Void] = [:]

    // MARK: - Registration

    /// Register hotkeys with their action handlers.
    /// Re-installs event monitors each time.
    func register(hotkeys: [AppHotkey], handlers: [String: () -> Void]) {
        self.hotkeys = hotkeys.filter { $0.isEnabled && $0.keyCode != nil }
        self.handlers = handlers
        unregisterAll()

        guard !self.hotkeys.isEmpty else { return }

        // Global monitor — fires when the app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // Local monitor — fires when the app IS focused (e.g. settings window open)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil  // consume the event
            }
            return event
        }

        print("[Hotkeys] Registered \(self.hotkeys.count) hotkey(s)")
    }

    /// Remove all event monitors.
    func unregisterAll() {
        if let g = globalMonitor {
            NSEvent.removeMonitor(g)
            globalMonitor = nil
        }
        if let l = localMonitor {
            NSEvent.removeMonitor(l)
            localMonitor = nil
        }
    }

    // MARK: - Event Handling

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        for hotkey in hotkeys {
            guard let code = hotkey.keyCode else { continue }
            let hotkeyMods = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
                .intersection(.deviceIndependentFlagsMask)

            if event.keyCode == code && eventMods == hotkeyMods {
                DispatchQueue.main.async {
                    self.handlers[hotkey.id]?()
                }
                return true
            }
        }
        return false
    }

    // MARK: - Accessibility Check

    /// Returns true if the app has Accessibility permission (required for global hotkeys).
    static var isAccessibilityGranted: Bool {
        return AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility permission.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
