//
//  KeyCodeMap.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

/// Maps macOS virtual key codes to human-readable names.
enum KeyCodeMap {

    static func name(for keyCode: UInt16) -> String {
        return map[keyCode] ?? "Key\(keyCode)"
    }

    /// Returns the single-character string NSMenuItem.keyEquivalent expects,
    /// or nil if the key code has no simple menu equivalent (e.g. F-keys, arrows).
    static func menuKeyEquivalent(for keyCode: UInt16) -> String? {
        guard let name = menuEquivMap[keyCode] else { return nil }
        return name
    }

    /// Lowercase single-char strings for letter/number/symbol keys that NSMenu can display.
    private static let menuEquivMap: [UInt16: String] = [
        // Letters
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h",
        5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 31: "o", 32: "u", 34: "i",
        35: "p", 37: "l", 38: "j", 40: "k", 45: "n",
        46: "m",
        // Numbers
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        // Symbols
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'",
        41: ";", 42: "\\", 43: ",", 44: "/", 47: ".",
        50: "`",
    ]

    private static let map: [UInt16: String] = [
        // Letters
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H",
        5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3",
        21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
        31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 50: "`",

        // Special keys
        36: "Return", 48: "Tab", 49: "Space",
        51: "Delete", 53: "Escape",
        71: "Clear", 76: "Enter",

        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16",
        64: "F17", 79: "F18", 80: "F19", 90: "F20",

        // Arrow keys
        123: "←", 124: "→", 125: "↓", 126: "↑",

        // Navigation
        115: "Home", 119: "End",
        116: "Page Up", 121: "Page Down",
        117: "Forward Delete",

        // Numpad
        65: "Numpad .", 67: "Numpad *", 69: "Numpad +",
        75: "Numpad /", 78: "Numpad -", 81: "Numpad =",
        82: "Numpad 0", 83: "Numpad 1", 84: "Numpad 2",
        85: "Numpad 3", 86: "Numpad 4", 87: "Numpad 5",
        88: "Numpad 6", 89: "Numpad 7", 91: "Numpad 8",
        92: "Numpad 9",
    ]
}
