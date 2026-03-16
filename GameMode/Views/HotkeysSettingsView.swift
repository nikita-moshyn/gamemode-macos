//
//  HotkeysSettingsView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(.red)
                                .font(.title3)
                            Text("Accessibility Permission Required")
                                .fontWeight(.semibold)
                        }

                        Text("GameMode needs Accessibility permission to capture keyboard shortcuts while other apps are in focus.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button("Request Permission") {
                                HotkeyManager.requestAccessibilityPermission()
                            }

                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }

            Section {
                ForEach(configStore.config.hotkeys.indices, id: \.self) { index in
                    hotkeyRow(index: index)
                }
            } header: {
                Text("Global Hotkeys")
            } footer: {
                Text("These shortcuts work system-wide, even when GameMode is not focused.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Row

    private func hotkeyRow(index: Int) -> some View {
        let hotkey = configStore.config.hotkeys[index]

        return HStack {
            Toggle("", isOn: Binding(
                get: { configStore.config.hotkeys[index].isEnabled },
                set: { newValue in
                    configStore.config.hotkeys[index].isEnabled = newValue
                    onHotkeysChanged?()
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            Text(hotkey.name)
                .frame(maxWidth: .infinity, alignment: .leading)

            ShortcutRecorderView(
                keyCode: Binding(
                    get: { configStore.config.hotkeys[index].keyCode },
                    set: { configStore.config.hotkeys[index].keyCode = $0 }
                ),
                modifiers: Binding(
                    get: { configStore.config.hotkeys[index].modifiers },
                    set: { configStore.config.hotkeys[index].modifiers = $0 }
                ),
                onChange: { onHotkeysChanged?() }
            )
        }
    }
}
