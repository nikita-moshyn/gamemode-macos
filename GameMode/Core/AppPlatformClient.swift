//
//  AppPlatformClient.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import ComposableArchitecture
import Carbon
import UserNotifications

struct AppPlatformClient: Sendable {
    enum Event: Equatable, Sendable {
        case launched(String), terminated(String), hotkey(String), powerOff
    }
    enum Command: Equatable, Sendable {
        case start, resetUpdateCycle, checkForUpdates, showSettings, showAbout, reopenWindow
        case replyToTermination, toggleInputSource, requestAccessibility, accessibilitySettings, loginSettings, console
        case notifyMode(Bool)
    }
    var events: @MainActor @Sendable () -> AsyncStream<Event>
    var runningBundleIDs: @MainActor @Sendable () -> [String]
    var accessibilityGranted: @MainActor @Sendable () -> Bool
    var configureHotkeys: @MainActor @Sendable ([AppHotkey]) -> Void
    var command: @MainActor @Sendable (Command) -> Void
    var configureLogging: @Sendable (GameModeConfig) -> Void
}

extension AppPlatformClient: TestDependencyKey {
    static let testValue = Self(events: unimplemented("AppPlatformClient.events", placeholder: .finished), runningBundleIDs: unimplemented("AppPlatformClient.runningBundleIDs", placeholder: []), accessibilityGranted: unimplemented("AppPlatformClient.accessibilityGranted", placeholder: false), configureHotkeys: unimplemented("AppPlatformClient.configureHotkeys"), command: unimplemented("AppPlatformClient.command"), configureLogging: { _ in })
}
extension DependencyValues {
    var appPlatform: AppPlatformClient {
        get { self[AppPlatformClient.self] }
        set { self[AppPlatformClient.self] = newValue }
    }
}

/// NSWorkspace/Carbon resources. Counts and activation decisions live in the reducer.
@MainActor
final class AppPlatformAdapter {
    private let hotkeys = HotkeyManager()
    private var continuation: AsyncStream<AppPlatformClient.Event>.Continuation?
    private var observers: [NSObjectProtocol] = []

    func client(command: @escaping @MainActor @Sendable (AppPlatformClient.Command) -> Void) -> AppPlatformClient {
        AppPlatformClient(events: { [self] in
            let stream = AsyncStream<AppPlatformClient.Event>.makeStream()
            continuation?.finish()
            continuation = stream.continuation
            let center = NSWorkspace.shared.notificationCenter
            for observer in observers { center.removeObserver(observer) }
            observers = [
                center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
                    if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let id = app.bundleIdentifier { stream.continuation.yield(.launched(id)) }
                },
                center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
                    if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let id = app.bundleIdentifier { stream.continuation.yield(.terminated(id)) }
                },
                center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in stream.continuation.yield(.powerOff) }
            ]
            stream.continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            return stream.stream
        }, runningBundleIDs: { NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) }, accessibilityGranted: { HotkeyManager.isAccessibilityGranted }, configureHotkeys: { [self] values in
            hotkeys.register(hotkeys: values, handlers: Dictionary(values.map { hotkey in
                (hotkey.id, { [weak self] in self?.continuation?.yield(.hotkey(hotkey.id)); return () })
            }, uniquingKeysWith: { first, _ in first }))
        }, command: command, configureLogging: { Log.configure($0) })
    }

    private func stop() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        hotkeys.unregisterAll()
        continuation = nil
    }

    static func perform(_ command: AppPlatformClient.Command) {
        switch command {
        case .requestAccessibility: HotkeyManager.requestAccessibilityPermission()
        case .accessibilitySettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        case .loginSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        case .console: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
        case .notifyMode(let enabled):
            let content = UNMutableNotificationContent()
            content.title = enabled ? "Game Mode — Enabled" : "Game Mode — Disabled"
            content.body = enabled ? "Your gaming settings are active." : "Your original settings were restored."
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        case .toggleInputSource: toggleInputSource()
        case .replyToTermination: NSApp.reply(toApplicationShouldTerminate: true)
        case .start:
            ProcessInfo.processInfo.disableSuddenTermination()
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        default: break
        }
    }

    private static func toggleInputSource() {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        let selectable = sources.filter { source in
            guard let category = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory),
                  Unmanaged<CFString>.fromOpaque(category).takeUnretainedValue() == kTISCategoryKeyboardInputSource,
                  let capability = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable) else { return false }
            return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(capability).takeUnretainedValue())
        }
        guard selectable.count > 1 else { return }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        func identifier(_ source: TISInputSource) -> String? {
            guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
            return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
        }
        let index = selectable.firstIndex { identifier($0) == identifier(current) } ?? -1
        TISSelectInputSource(selectable[(index + 1) % selectable.count])
    }
}
