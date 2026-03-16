//
//  AppHotkey.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit

/// A global keyboard shortcut bound to a GameMode action.
struct AppHotkey: Codable, Identifiable, Hashable {
    /// Stable action identifier (e.g. "toggleGameMode").
    let id: String
    /// Human-readable name for the UI.
    var name: String
    /// macOS virtual key code, or nil if unbound.
    var keyCode: UInt16?
    /// Raw value of NSEvent.ModifierFlags (device-independent).
    var modifiers: UInt
    /// Whether this hotkey is active.
    var isEnabled: Bool

    /// Human-readable shortcut string (e.g. "⌘⇧G").
    var displayString: String {
        guard let kc = keyCode else { return "Not Set" }
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(KeyCodeMap.name(for: kc))
        return parts.joined()
    }

    // MARK: - Defaults

    static let defaults: [AppHotkey] = [
        AppHotkey(
            id: "toggleGameMode",
            name: "Toggle Gaming Mode",
            keyCode: 5,        // G
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            isEnabled: true
        ),
        AppHotkey(
            id: "toggleMouseBoost",
            name: "Toggle Mouse Boost",
            keyCode: nil,
            modifiers: 0,
            isEnabled: false
        ),
        AppHotkey(
            id: "toggleInputSource",
            name: "Toggle Input Source",
            keyCode: nil,
            modifiers: 0,
            isEnabled: false
        ),
    ]
}
