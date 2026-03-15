//
//  AppMonitor.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit

/// Watches for GeForce Now launch/termination via NSWorkspace notifications.
class AppMonitor {

    // MARK: - Bundle ID

    /// GeForce Now bundle identifier.
    /// Verify yours with:
    ///   mdls -name kMDItemCFBundleIdentifier /Applications/GeForce\ NOW.app
    /// Common values:
    ///   "com.nvidia.gfnpc.mall"   (most installs)
    ///   "com.nvidia.GeForceNOW"   (older versions)
    static let geforceNowBundleID = "com.nvidia.gfnpc.mall"

    private let onLaunched: () -> Void
    private let onTerminated: () -> Void

    // MARK: - Init

    init(onGeForceNowLaunched: @escaping () -> Void,
         onGeForceNowTerminated: @escaping () -> Void) {

        self.onLaunched = onGeForceNowLaunched
        self.onTerminated = onGeForceNowTerminated

        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Observers

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              app.bundleIdentifier == Self.geforceNowBundleID
        else { return }

        print("[GameMode] GeForce Now launched — activating gaming mode")
        DispatchQueue.main.async { self.onLaunched() }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              app.bundleIdentifier == Self.geforceNowBundleID
        else { return }

        print("[GameMode] GeForce Now terminated — restoring normal mode")
        DispatchQueue.main.async { self.onTerminated() }
    }
}
