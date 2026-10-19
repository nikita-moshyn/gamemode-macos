//
//  AppDetector.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit

/// Scans the filesystem for installed game applications.
///
/// Detection strategy:
/// 1. Scan `/Applications` and `~/Applications` for `.app` bundles
/// 2. Read each app's `Info.plist` for `LSApplicationCategoryType`
/// 3. Any app whose category contains "game" is flagged as a detected game
class AppDetector {

    /// Game-related UTI category prefixes.
    private static let gameCategories: Set<String> = [
        "public.app-category.action-games",
        "public.app-category.adventure-games",
        "public.app-category.arcade-games",
        "public.app-category.board-games",
        "public.app-category.card-games",
        "public.app-category.casino-games",
        "public.app-category.dice-games",
        "public.app-category.educational-games",
        "public.app-category.family-games",
        "public.app-category.kids-games",
        "public.app-category.music-games",
        "public.app-category.puzzle-games",
        "public.app-category.racing-games",
        "public.app-category.role-playing-games",
        "public.app-category.simulation-games",
        "public.app-category.sports-games",
        "public.app-category.strategy-games",
        "public.app-category.trivia-games",
        "public.app-category.word-games",
        "public.app-category.games",
    ]

    /// Bundle IDs of preset apps (skip these during scanning to avoid duplicates).
    private static let presetBundleIDs: Set<String> = Set(
        MonitoredApp.presets.map { $0.bundleID }
    )

    // MARK: - Scan

    /// Scan common directories for game apps. Returns new `MonitoredApp` entries.
    static func scanForGames() -> [MonitoredApp] {
        var results: [MonitoredApp] = []
        var seenBundleIDs = Set<String>()

        let searchPaths = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
        ]

        for searchPath in searchPaths {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                atPath: searchPath
            ) else { continue }

            for item in contents where item.hasSuffix(".app") {
                let appPath = searchPath + "/" + item

                guard let bundle = Bundle(path: appPath),
                      let bundleID = bundle.bundleIdentifier,
                      !seenBundleIDs.contains(bundleID),
                      !isPreset(bundleID: bundleID)
                else { continue }

                if isGameApp(bundle: bundle) {
                    let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? item.replacingOccurrences(of: ".app", with: "")

                    results.append(MonitoredApp(
                        id: UUID(),
                        bundleID: bundleID,
                        name: name,
                        isEnabled: false,  // detected games default to disabled
                        source: .detected
                    ))
                    seenBundleIDs.insert(bundleID)
                }
            }
        }

        Log.info("Found \(results.count) game(s)", category: "AppDetector")
        return results
    }

    // MARK: - Helpers

    /// Check if a bundle's category indicates it's a game.
    private static func isGameApp(bundle: Bundle) -> Bool {
        guard let category = bundle.object(
            forInfoDictionaryKey: "LSApplicationCategoryType"
        ) as? String else {
            return false
        }
        return gameCategories.contains(category)
    }

    /// Check if a bundle ID matches a preset (exact or prefix).
    private static func isPreset(bundleID: String) -> Bool {
        for preset in MonitoredApp.presets {
            if preset.matches(bundleID: bundleID) { return true }
        }
        return false
    }

    /// Read available shortcuts from the user's symbolichotkeys plist.
    /// Returns entries for all hotkeys that exist in the user's plist,
    /// cross-referenced with our known ID map.
    static func detectAvailableShortcuts() -> [ShortcutEntry] {
        let plistPath = NSHomeDirectory()
            + "/Library/Preferences/com.apple.symbolichotkeys.plist"

        guard let plistData = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData, format: nil
              ) as? [String: Any],
              let hotkeys = plist["AppleSymbolicHotKeys"] as? [String: Any]
        else {
            Log.error("Could not read symbolichotkeys plist", category: "AppDetector")
            return ShortcutEntry.defaults
        }

        var result: [ShortcutEntry] = []
        for entry in SymbolicHotkeys.all {
            if hotkeys[String(entry.id)] != nil {
                result.append(ShortcutEntry(
                    id: entry.id,
                    name: entry.name,
                    category: entry.category,
                    disableInGamingMode: false
                ))
            }
        }

        Log.info("Found \(result.count) keyboard shortcuts in plist", category: "AppDetector")
        return result
    }
}
