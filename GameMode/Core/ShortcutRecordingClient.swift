//
//  ShortcutRecordingClient.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import ComposableArchitecture

struct ShortcutRecordingClient: Sendable {
    struct Key: Equatable, Sendable { var code: UInt16; var modifiers: UInt }
    var events: @MainActor @Sendable () -> AsyncStream<Key>

    @MainActor
    static func stream(addMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any? = { NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: $0) }, removeMonitor: @escaping @MainActor (Any) -> Void = { NSEvent.removeMonitor($0) }) -> AsyncStream<Key> {
        let pair = AsyncStream<Key>.makeStream()
        let resource = Monitor(remove: removeMonitor)
        resource.token = addMonitor { event in
            if event.keyCode == 53 { resource.stop(); pair.continuation.finish(); return nil }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !modifiers.intersection([.command, .control, .option, .shift]).isEmpty, !event.isARepeat {
                resource.stop()
                pair.continuation.yield(Key(code: event.keyCode, modifiers: modifiers.rawValue))
                pair.continuation.finish()
            }
            return nil
        }
        if resource.token == nil { pair.continuation.finish() }
        pair.continuation.onTermination = { _ in Task { @MainActor in resource.stop() } }
        return pair.stream
    }

    @MainActor
    private final class Monitor {
        var token: Any?
        let remove: @MainActor (Any) -> Void
        init(remove: @escaping @MainActor (Any) -> Void) { self.remove = remove }
        func stop() {
            if let token { remove(token); self.token = nil }
        }
    }
}

extension ShortcutRecordingClient: DependencyKey {
    static let liveValue = Self(events: { stream() })
    static let testValue = Self(events: unimplemented("ShortcutRecordingClient.events", placeholder: .finished))
}
extension DependencyValues {
    var shortcutRecording: ShortcutRecordingClient {
        get { self[ShortcutRecordingClient.self] }
        set { self[ShortcutRecordingClient.self] = newValue }
    }
}
