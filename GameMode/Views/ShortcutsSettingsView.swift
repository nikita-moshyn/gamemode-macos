//
//  ShortcutsSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct ShortcutsSettingsView: View {
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Use F1, F2, etc. as standard function keys",
                       isOn: $configStore.config.functionKeysInGamingMode)

                Divider()

                Text("Shortcuts to disable in game mode")
                    .font(.headline)

                Text("Checked shortcuts will be disabled when gaming mode activates.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(groupedCategories, id: \.category) { group in
                    Section {
                        ForEach(group.entries, id: \.id) { entry in
                            shortcutRow(entry)
                        }
                    } header: {
                        Text(group.category)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }

                HStack {
                    Button("Detect System Shortcuts") {
                        let detected = AppDetector.detectAvailableShortcuts()
                        configStore.mergeDetectedShortcuts(detected)
                    }
                    Text("Scans your system for available keyboard shortcuts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)

                Divider()

                // MARK: - Gestures

                Text("Gestures to disable in game mode")
                    .font(.headline)

                Text("Checked gestures will be disabled when gaming mode activates. Useful when playing with a trackpad.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(gestureCategories, id: \.category) { group in
                    Section {
                        ForEach(group.entries, id: \.id) { entry in
                            gestureRow(entry)
                        }
                    } header: {
                        Text(group.category)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Shortcut Row

    private func shortcutRow(_ entry: ShortcutEntry) -> some View {
        let binding = Binding<Bool>(
            get: {
                configStore.config.shortcuts.first(where: { $0.id == entry.id })?
                    .disableInGamingMode ?? false
            },
            set: { _ in
                configStore.toggleShortcut(id: entry.id)
            }
        )
        return Toggle(entry.name, isOn: binding)
    }

    // MARK: - Gesture Row

    private func gestureRow(_ entry: GestureEntry) -> some View {
        let binding = Binding<Bool>(
            get: {
                configStore.config.gestures.first(where: { $0.id == entry.id })?
                    .disableInGamingMode ?? false
            },
            set: { _ in
                configStore.toggleGesture(id: entry.id)
            }
        )
        return Toggle(entry.name, isOn: binding)
    }

    // MARK: - Grouping

    private struct CategoryGroup {
        let category: String
        let entries: [ShortcutEntry]
    }

    private var groupedCategories: [CategoryGroup] {
        var seen = Set<String>()
        var result: [CategoryGroup] = []
        for shortcut in configStore.config.shortcuts {
            if seen.insert(shortcut.category).inserted {
                let entries = configStore.config.shortcuts
                    .filter { $0.category == shortcut.category }
                result.append(CategoryGroup(category: shortcut.category, entries: entries))
            }
        }
        return result
    }

    private struct GestureCategoryGroup {
        let category: String
        let entries: [GestureEntry]
    }

    private var gestureCategories: [GestureCategoryGroup] {
        var seen = Set<String>()
        var result: [GestureCategoryGroup] = []
        for gesture in configStore.config.gestures {
            if seen.insert(gesture.category).inserted {
                let entries = configStore.config.gestures
                    .filter { $0.category == gesture.category }
                result.append(GestureCategoryGroup(category: gesture.category, entries: entries))
            }
        }
        return result
    }
}
