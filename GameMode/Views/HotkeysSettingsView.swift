//
//  HotkeysSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import SwiftUI

struct HotkeysSettingsView: View {
    @Bindable var store: StoreOf<AppSettings>

    var body: some View {
        Form {
            if !store.runtime.isAccessibilityGranted {
                Section {
                    Label("Accessibility Permission Required", systemImage: "lock.shield")
                        .fontWeight(.medium)
                    Text("Allow GameMode to use keyboard shortcuts while other apps are focused.")
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        store.send(.command(.accessibilitySettings))
                    }
                    Button("Request Permission") {
                        store.send(.command(.requestAccessibility))
                    }
                }
            }

            Section {
                ForEach(store.config.hotkeys) { hotkey in
                    hotkeyRow(hotkey)
                }
            } header: {
                Text("Control GameMode")
            } footer: {
                Text("These hotkeys control GameMode from any application. Click Record Shortcut, then press a key with Command, Control, Option, or Shift. Press Escape to cancel.")
            }
        }
        .formStyle(.grouped)
    }

    private func hotkeyRow(_ hotkey: AppHotkey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(hotkey.displayName, isOn: Binding(
                get: { currentHotkey(hotkey.id)?.isEnabled ?? false },
                set: { newValue in
                    store.send(.hotkeyEnabledChanged(hotkey.id, newValue))
                }
            ))
            .toggleStyle(.switch)

            ShortcutRecorderView(store: store, hotkey: hotkey)
        }
        .padding(.vertical, 4)
    }

    private func currentHotkey(_ id: String) -> AppHotkey? {
        store.config.hotkeys.first { $0.id == id }
    }
}
