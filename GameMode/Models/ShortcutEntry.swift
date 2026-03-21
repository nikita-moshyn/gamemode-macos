//
//  ShortcutEntry.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

struct ShortcutEntry: Codable, Identifiable, Hashable {
    /// Symbolic hotkey ID from `com.apple.symbolichotkeys` plist.
    let id: Int
    /// Human-readable name (e.g. "Show Spotlight Search").
    var name: String
    /// Category for grouping in the UI (e.g. "Spotlight", "Input Sources").
    var category: String
    /// If true, this shortcut is disabled when gaming mode activates.
    var disableInGamingMode: Bool
}

// MARK: - Defaults

extension ShortcutEntry {
    /// Default shortcuts to disable in gaming mode.
    /// These are the most common conflicts for gamers.
    static let defaults: [ShortcutEntry] = [
        ShortcutEntry(id: 64, name: "Show Spotlight Search",
                      category: "Spotlight", disableInGamingMode: true),
        ShortcutEntry(id: 60, name: "Select Previous Input Source",
                      category: "Input Sources", disableInGamingMode: true),
    ]
}
