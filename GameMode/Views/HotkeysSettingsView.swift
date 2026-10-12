//
//  HotkeysSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 10/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct HotkeysSettingsView: View {
    @ObservedObject var configStore: ConfigStore
    var onHotkeysChanged: (() -> Void)?

    var body: some View {
        Form {
            if !configStore.isAccessibilityGranted {
                Section {
                    Label("Accessibility Permission Required", systemImage: "lock.shield")
                        .fontWeight(.medium)
                    Text("Allow GameMode to use keyboard shortcuts while other apps are focused.")
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        guard !configStore.isPreview else { return }
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Request Permission") {
                        guard !configStore.isPreview else { return }
                        HotkeyManager.requestAccessibilityPermission()
                    }
                }
            }

            Section {
                ForEach(configStore.config.hotkeys) { hotkey in
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
                    guard let index = configStore.config.hotkeys.firstIndex(where: { $0.id == hotkey.id }) else { return }
                    configStore.config.hotkeys[index].isEnabled = newValue
                    onHotkeysChanged?()
                }
            ))
            .toggleStyle(.switch)

            ShortcutRecorderView(
                keyCode: Binding(
                    get: { currentHotkey(hotkey.id)?.keyCode },
                    set: { keyCode in
                        guard let index = configStore.config.hotkeys.firstIndex(where: { $0.id == hotkey.id }) else { return }
                        configStore.config.hotkeys[index].keyCode = keyCode
                    }
                ),
                modifiers: Binding(
                    get: { currentHotkey(hotkey.id)?.modifiers ?? 0 },
                    set: { modifiers in
                        guard let index = configStore.config.hotkeys.firstIndex(where: { $0.id == hotkey.id }) else { return }
                        configStore.config.hotkeys[index].modifiers = modifiers
                    }
                ),
                onChange: { onHotkeysChanged?() },
                label: hotkey.displayName
            )
        }
        .padding(.vertical, 4)
    }

    private func currentHotkey(_ id: String) -> AppHotkey? {
        configStore.config.hotkeys.first { $0.id == id }
    }
}
