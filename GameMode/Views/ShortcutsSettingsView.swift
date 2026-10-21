//
//  ShortcutsSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import SwiftUI

struct ShortcutsSettingsView: View {
    @Bindable var store: StoreOf<AppSettings>

    var body: some View {
        Form {
            Section {
                Toggle("Input Guard", isOn: $store.config.isInputGuardEnabled)
            } footer: {
                Text("Choose function-key behavior and block selected shortcuts and gestures during Game Mode.")
            }

            Section {
                Picker("Function Keys", selection: $store.config.functionKeyBehavior) {
                    ForEach(FunctionKeyBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .disabled(!store.config.isInputGuardEnabled || !store.canEdit)
            }

            Group {
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
            .disabled(!store.config.isInputGuardEnabled)
        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcut Row

    private func shortcutRow(_ entry: ShortcutEntry) -> some View {
        let binding = Binding<Bool>(
            get: {
                store.config.shortcuts.first(where: { $0.id == entry.id })?
                    .disableInGamingMode ?? false
            },
            set: { store.send(.shortcutSelectionChanged(entry.id, $0)) }
        )
        return Toggle("Block “\(entry.name)”", isOn: binding)
    }

    // MARK: - Gesture Row

    private func gestureRow(_ entry: GestureEntry) -> some View {
        let binding = Binding<Bool>(
            get: {
                store.config.gestures.first(where: { $0.id == entry.id })?
                    .disableInGamingMode ?? false
            },
            set: { store.send(.gestureSelectionChanged(entry.id, $0)) }
        )
        return Toggle("Block “\(entry.name)”", isOn: binding)
    }

    // MARK: - Grouping

    private struct CategoryGroup {
        let category: String
        let entries: [ShortcutEntry]
    }

    private var groupedCategories: [CategoryGroup] {
        var seen = Set<String>()
        var result: [CategoryGroup] = []
        for shortcut in store.config.shortcuts {
            if seen.insert(shortcut.category).inserted {
                let entries = store.config.shortcuts
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
        for gesture in store.config.gestures {
            if seen.insert(gesture.category).inserted {
                let entries = store.config.gestures
                    .filter { $0.category == gesture.category }
                result.append(GestureCategoryGroup(category: gesture.category, entries: entries))
            }
        }
        return result
    }
}
