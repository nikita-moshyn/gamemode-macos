//
//  SettingsSection.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    // Retain persisted identifiers while presenting the new names and order.
    case general, shortcuts, mouse, display, applications, hotkeys, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Input Guard"
        case .hotkeys: return "Hotkeys"
        case .applications: return "Auto-Activation"
        case .mouse: return "Mouse"
        case .display: return "Displays"
        case .system: return "System"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "hand.raised"
        case .hotkeys: return "command.square"
        case .applications: return "app.dashed"
        case .mouse: return "computermouse"
        case .display: return "display"
        case .system: return "wrench.and.screwdriver"
        }
    }

    static func resolve(_ identifier: String) -> SettingsSection? {
        identifier == "logs" ? .system : SettingsSection(rawValue: identifier)
    }
}

