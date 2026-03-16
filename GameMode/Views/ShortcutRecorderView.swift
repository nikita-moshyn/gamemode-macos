//
//  ShortcutRecorderView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI
import AppKit

/// A view that lets the user record a keyboard shortcut by pressing keys.
struct ShortcutRecorderView: View {
    @Binding var keyCode: UInt16?
    @Binding var modifiers: UInt
    var onChange: (() -> Void)?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }) {
                Text(isRecording ? "Press shortcut..." : displayString)
                    .font(.system(.body, design: .rounded))
                    .frame(minWidth: 130)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isRecording
                                  ? Color.accentColor.opacity(0.15)
                                  : Color.secondary.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            if keyCode != nil {
                Button(action: { clear() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
    }

    // MARK: - Display

    private var displayString: String {
        guard let kc = keyCode else { return "Click to record" }
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(KeyCodeMap.name(for: kc))
        return parts.joined()
    }

    // MARK: - Recording

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Escape cancels recording
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            // Require at least one modifier key
            let hasModifier = mods.contains(.command) || mods.contains(.control)
                || mods.contains(.option) || mods.contains(.shift)

            if hasModifier {
                keyCode = event.keyCode
                modifiers = mods.rawValue
                stopRecording()
                onChange?()
            }

            return nil  // consume the event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func clear() {
        keyCode = nil
        modifiers = 0
        onChange?()
    }
}
