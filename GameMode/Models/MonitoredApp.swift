//
//  MonitoredApp.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2025 Nikita Moshyn. All rights reserved.
//

import Foundation

struct MonitoredApp: Codable, Identifiable, Hashable {
    let id: UUID
    var bundleID: String
    var name: String
    var isEnabled: Bool
    var source: AppSource

    enum AppSource: String, Codable {
        case preset     // built-in (GeForce Now, Steam pattern, etc.)
        case detected   // found by scanning /Applications + category check
        case manual     // user-added
    }

    /// Whether this entry uses prefix matching (bundle ID ends with `.*`).
    var usesPrefixMatch: Bool {
        bundleID.hasSuffix(".*")
    }

    /// Check if a running app's bundle ID matches this entry.
    func matches(bundleID candidate: String) -> Bool {
        if usesPrefixMatch {
            let prefix = String(bundleID.dropLast(2))
            return candidate.hasPrefix(prefix)
        }
        return candidate == bundleID
    }
}

// MARK: - Presets

extension MonitoredApp {
    static let presets: [MonitoredApp] = [
        MonitoredApp(
            id: UUID(uuidString: "00000000-0001-0000-0000-000000000001")!,
            bundleID: "com.nvidia.gfnpc.mall",
            name: "GeForce Now",
            isEnabled: true,
            source: .preset
        ),
        MonitoredApp(
            id: UUID(uuidString: "00000000-0001-0000-0000-000000000002")!,
            bundleID: "com.valvesoftware.steam.app.*",
            name: "Steam Games",
            isEnabled: true,
            source: .preset
        ),
        MonitoredApp(
            id: UUID(uuidString: "00000000-0001-0000-0000-000000000003")!,
            bundleID: "com.epicgames.EpicGamesLauncher",
            name: "Epic Games",
            isEnabled: false,
            source: .preset
        ),
        MonitoredApp(
            id: UUID(uuidString: "00000000-0001-0000-0000-000000000004")!,
            bundleID: "com.gog.galaxy",
            name: "GOG Galaxy",
            isEnabled: false,
            source: .preset
        ),
        MonitoredApp(
            id: UUID(uuidString: "00000000-0001-0000-0000-000000000005")!,
            bundleID: "net.battle.app",
            name: "Battle.net",
            isEnabled: false,
            source: .preset
        ),
        MonitoredApp(
            id: UUID(uuidString: "00000000-0001-0000-0000-000000000006")!,
            bundleID: "com.codeweavers.CrossOver",
            name: "CrossOver",
            isEnabled: false,
            source: .preset
        ),
        MonitoredApp(
            id: UUID(uuidString: "00000000-0001-0000-0000-000000000007")!,
            bundleID: "com.libretro.RetroArch",
            name: "RetroArch",
            isEnabled: false,
            source: .preset
        ),
        MonitoredApp(
            id: UUID(uuidString: "00000000-0001-0000-0000-000000000008")!,
            bundleID: "org.openemu.OpenEmu",
            name: "OpenEmu",
            isEnabled: false,
            source: .preset
        ),
    ]
}
