//
//  AppWindowPresentation.swift
//  GameMode
//
//  Created by Nikita Moshyn on 10/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit

/// A window stays open when hidden or minimized. Only closing the last tracked
/// window returns the app to menu-bar-only operation.
final class AppWindowPresentation: NSObject, NSWindowDelegate {
    private var openWindows: [NSWindow] = []
    private var activationPolicy: NSApplication.ActivationPolicy = .accessory
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    private let activate: () -> Void

    init(setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }, activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.setActivationPolicy = setActivationPolicy
        self.activate = activate
        super.init()
    }

    func show(_ window: NSWindow) {
        openWindows.removeAll { $0 === window }
        openWindows.append(window)
        window.delegate = self
        updateActivationPolicy()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        activate()
    }

    @discardableResult
    func reopenLastWindow() -> Bool {
        guard let window = openWindows.last else { return false }
        show(window)
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, openWindows.contains(where: { $0 === window }) else { return }
        openWindows.removeAll { $0 === window }
        openWindows.append(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, openWindows.contains(where: { $0 === window }) else { return }
        openWindows.removeAll { $0 === window }
        // Finish AppKit's close operation before changing the app's activation
        // policy. Recheck the collection in case another window opens meanwhile.
        RunLoop.main.perform(inModes: [.common, .eventTracking]) { [weak self] in
            self?.updateActivationPolicy()
        }
    }

    private func updateActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = openWindows.isEmpty ? .accessory : .regular
        guard policy != activationPolicy else { return }
        activationPolicy = policy
        setActivationPolicy(policy)
    }
}
