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
                VStack(alignment: .leading, spacing: 0) {
                    Text("To change a shortcut, double-click the key combination, then type the new keys.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                    Divider()
                    ShortcutRecorderView(hotkeys: store.config.hotkeys, recordingHotkeyID: store.recordingHotkeyID, isEnabled: store.canEdit, onEnable: { id, enabled in
                        store.send(.hotkeyEnabledChanged(id, enabled))
                    }, onRecord: { store.send(.recordHotkey($0)) }, onClear: { id in
                        store.send(.stopRecording)
                        store.send(.updateHotkey(id: id, keyCode: nil, modifiers: 0))
                    }, onStopRecording: { store.send(.stopRecording) })
                        .frame(height: CGFloat(store.config.hotkeys.count) * 24)
                }
                .padding(-10)
            } footer: {
                Text("These shortcuts control GameMode from any application. Include Command, Control, Option, or Shift. Press Escape to cancel, or Delete to clear.")
            }
        }
        .formStyle(.grouped)
        .onDisappear { store.send(.stopRecording) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in store.send(.stopRecording) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in store.send(.stopRecording) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Restore Defaults") { store.send(.restoreDefaultHotkeys) }
                    .disabled(!store.canEdit)
                Spacer()
            }
            .padding(20)
            .background(.bar)
        }
    }
}
