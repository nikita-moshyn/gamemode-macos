//
//  ShortcutsSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 11/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct ShortcutsSettingsView: View {
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        Form {
            Section {
                Toggle("Input Guard", isOn: $configStore.config.isInputGuardEnabled)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Choose which shortcuts and gestures to block, and whether to use standard function keys, while Game Mode is enabled.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Group {
                Section {
                    Toggle("Use F1, F2, etc. as standard function keys", isOn: $configStore.config.functionKeysInGamingMode)
                } header: {
                    Text("Function Keys")
                } footer: {
                    Text("Use F1–F12 directly instead of brightness, volume, and other media controls.")
                }

                ForEach(groupedCategories, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.entries, id: \.id) { entry in
                            shortcutRow(entry)
                        }
                    }
                }

                ForEach(gestureCategories, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.entries, id: \.id) { entry in
                            gestureRow(entry)
                        }
                    }
                }
            }
            .disabled(!configStore.config.isInputGuardEnabled)
        }
        .formStyle(.grouped)
        .onAppear { configStore.refreshDetectedShortcuts() }
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
