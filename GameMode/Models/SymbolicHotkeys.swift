//
//  SymbolicHotkeys.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

/// Maps macOS symbolic hotkey IDs to human-readable names.
///
/// Source: `~/Library/Preferences/com.apple.symbolichotkeys.plist`
/// Key IDs are undocumented by Apple — this mapping is community-sourced.
enum SymbolicHotkeys {

    struct Entry {
        let id: Int
        let name: String
        let category: String
    }

    /// All known symbolic hotkey IDs grouped by category.
    static let all: [Entry] = [
        // Spotlight
        Entry(id: 64, name: "Show Spotlight Search", category: "Spotlight"),
        Entry(id: 65, name: "Show Finder Search Window", category: "Spotlight"),

        // Input Sources
        Entry(id: 60, name: "Select Previous Input Source", category: "Input Sources"),
        Entry(id: 61, name: "Select Next Input Source", category: "Input Sources"),

        // Mission Control
        Entry(id: 32, name: "Mission Control", category: "Mission Control"),
        Entry(id: 33, name: "Application Windows", category: "Mission Control"),
        Entry(id: 34, name: "Mission Control (secondary)", category: "Mission Control"),
        Entry(id: 35, name: "Application Windows (secondary)", category: "Mission Control"),
        Entry(id: 36, name: "Show Desktop", category: "Mission Control"),
        Entry(id: 37, name: "Show Desktop (secondary)", category: "Mission Control"),
        Entry(id: 79, name: "Move Left a Space", category: "Mission Control"),
        Entry(id: 80, name: "Move Left a Space (secondary)", category: "Mission Control"),
        Entry(id: 81, name: "Move Right a Space", category: "Mission Control"),
        Entry(id: 82, name: "Move Right a Space (secondary)", category: "Mission Control"),

        // Screenshots
        Entry(id: 28, name: "Screenshot (⌘⇧3)", category: "Screenshots"),
        Entry(id: 29, name: "Screenshot of Selection (⌘⇧4)", category: "Screenshots"),
        Entry(id: 30, name: "Screenshot to Clipboard (⌃⌘⇧3)", category: "Screenshots"),
        Entry(id: 31, name: "Screenshot of Selection to Clipboard (⌃⌘⇧4)", category: "Screenshots"),
        Entry(id: 184, name: "Screenshot and Recording Options (⌘⇧5)", category: "Screenshots"),

        // Accessibility
        Entry(id: 59, name: "Turn VoiceOver On/Off", category: "Accessibility"),
        Entry(id: 162, name: "Show Accessibility Controls", category: "Accessibility"),

        // Display
        Entry(id: 53, name: "Decrease Display Brightness", category: "Display"),
        Entry(id: 54, name: "Increase Display Brightness", category: "Display"),
        Entry(id: 55, name: "Decrease Display Brightness (dedicated key)", category: "Display"),
        Entry(id: 56, name: "Increase Display Brightness (dedicated key)", category: "Display"),

        // Dock
        Entry(id: 52, name: "Turn Dock Hiding On/Off", category: "Dock"),

        // Launchpad & Siri
        Entry(id: 160, name: "Show Launchpad", category: "Launchpad"),
        Entry(id: 175, name: "Siri", category: "Siri"),

        // Other
        Entry(id: 70, name: "Look Up in Dictionary", category: "Other"),
        Entry(id: 190, name: "Toggle Focus", category: "Other"),
    ]

    /// All distinct categories in display order.
    static let categories: [String] = {
        var seen = Set<String>()
        var result: [String] = []
        for entry in all {
            if seen.insert(entry.category).inserted {
                result.append(entry.category)
            }
        }
        return result
    }()

    /// Entries for a given category.
    static func entries(for category: String) -> [Entry] {
        all.filter { $0.category == category }
    }

    /// Look up a name by ID.
    static func name(for id: Int) -> String? {
        all.first(where: { $0.id == id })?.name
    }
}
