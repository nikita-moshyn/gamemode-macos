//
//  SettingsSection.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

enum SettingsDestination: Hashable {
    case recovery
    case addApplications

    var title: String {
        switch self {
        case .recovery: "Recovery"
        case .addApplications: "Add Applications"
        }
    }
}

/// Navigation history stores locations, never file contents or unfinished edits.
enum SettingsLocation: Equatable {
    case section(SettingsSection)
    case recovery
    case addApplications

    var section: SettingsSection {
        switch self {
        case .section(let section): section
        case .recovery: .system
        case .addApplications: .applications
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    // Retain persisted identifiers while presenting the new names and order.
    case general, shortcuts, mouse, display, applications, hotkeys, system

    static var availableCases: [SettingsSection] {
        #if FEATURE_DISPLAYS
        allCases
        #else
        allCases.filter { $0 != .display }
        #endif
    }

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
        let section: SettingsSection?
        switch identifier {
        case "logs": section = .system
        case "functionKeys": section = .shortcuts
        default: section = SettingsSection(rawValue: identifier)
        }
        guard let section, availableCases.contains(section) else { return nil }
        return section
    }
}

