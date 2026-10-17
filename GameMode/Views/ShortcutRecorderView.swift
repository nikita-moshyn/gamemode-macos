//
//  ShortcutRecorderView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI
import ComposableArchitecture
import AppKit

struct ShortcutRecorderView: View {
    let store: StoreOf<AppSettings>
    let hotkey: AppHotkey
    private var isRecording: Bool { store.recordingHotkeyID == hotkey.id }
    private var displayString: String { hotkey.keyCode == nil ? "Record Shortcut" : hotkey.displayString }

    var body: some View {
        HStack(spacing: 6) {
            Button { store.send(.recordHotkey(hotkey.id)) } label: {
                Text(isRecording ? "Press shortcut…" : displayString)
                    .monospaced()
                    .frame(minWidth: 132)
            }
            .accessibilityLabel("Record \(hotkey.displayName)")
            .accessibilityValue(isRecording ? "Recording" : displayString)
            .help(isRecording ? "Press a shortcut with a modifier key, or Escape to cancel." : "Record a keyboard shortcut")
            if hotkey.keyCode != nil {
                Button {
                    store.send(.stopRecording)
                    store.send(.updateHotkey(id: hotkey.id, keyCode: nil, modifiers: 0))
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear \(hotkey.displayName)")
                .help("Clear shortcut")
            }
        }
        .onDisappear { if isRecording { store.send(.stopRecording) } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in if isRecording { store.send(.stopRecording) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in if isRecording { store.send(.stopRecording) } }
    }
}
