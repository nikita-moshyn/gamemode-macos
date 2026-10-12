//
//  ShortcutRecorderView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 10/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI
import AppKit

/// Owns the single local event monitor shared by all shortcut recorders.
final class ShortcutRecordingSession: ObservableObject {
    static let shared = ShortcutRecordingSession()
    @Published private(set) var activeID: UUID?
    private var monitor: Any?
    private let addMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    private let removeMonitor: (Any) -> Void

    init(addMonitor: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = { NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: $0) }, removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }) {
        self.addMonitor = addMonitor
        self.removeMonitor = removeMonitor
    }

    func start(id: UUID, onRecord: @escaping (UInt16, UInt) -> Void) {
        stop()
        activeID = id
        monitor = addMonitor { [weak self] event in
            guard let self, self.activeID == id else { return event }
            if event.keyCode == 53 {
                self.stop()
                return nil
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasModifier = !modifiers.intersection([.command, .control, .option, .shift]).isEmpty
            if hasModifier, !event.isARepeat {
                self.stop()
                onRecord(event.keyCode, modifiers.rawValue)
            }
            return nil
        }
        if monitor == nil { activeID = nil }
    }

    func stop(id: UUID? = nil) {
        guard id == nil || activeID == id else { return }
        if let monitor {
            removeMonitor(monitor)
            self.monitor = nil
        }
        activeID = nil
    }

    deinit {
        if let monitor { removeMonitor(monitor) }
    }
}

struct ShortcutRecorderView: View {
    @Binding var keyCode: UInt16?
    @Binding var modifiers: UInt
    var onChange: (() -> Void)?
    var label = "Keyboard shortcut"
    @State private var recorderID = UUID()
    @ObservedObject private var recordingSession = ShortcutRecordingSession.shared

    private var isRecording: Bool { recordingSession.activeID == recorderID }

    var body: some View {
        HStack(spacing: 6) {
            Button(isRecording ? "Press shortcut…" : displayString) {
                if isRecording {
                    recordingSession.stop(id: recorderID)
                } else {
                    recordingSession.start(id: recorderID) { recordedKey, recordedModifiers in
                        keyCode = recordedKey
                        modifiers = recordedModifiers
                        onChange?()
                    }
                }
            }
            .monospaced()
            .frame(minWidth: 132)
            .accessibilityLabel(label)
            .accessibilityValue(isRecording ? "Recording" : displayString)
            .help(isRecording ? "Press a shortcut with a modifier key, or Escape to cancel." : "Record a keyboard shortcut")

            if keyCode != nil {
                Button {
                    recordingSession.stop(id: recorderID)
                    keyCode = nil
                    modifiers = 0
                    onChange?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear \(label)")
                .help("Clear shortcut")
            }
        }
        .onDisappear { recordingSession.stop(id: recorderID) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            recordingSession.stop(id: recorderID)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            recordingSession.stop(id: recorderID)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            recordingSession.stop(id: recorderID)
        }
    }

    private var displayString: String {
        guard let keyCode else { return "Record Shortcut" }
        let shortcut = AppHotkey(id: "recorder", name: label, keyCode: keyCode, modifiers: modifiers, isEnabled: true)
        return shortcut.displayString
    }
}
