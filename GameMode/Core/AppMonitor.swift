//
//  AppMonitor.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2025 Nikita Moshyn. All rights reserved.
//

import AppKit

/// Watches for monitored app launches/terminations via NSWorkspace notifications.
///
/// Supports multiple simultaneous games — gaming mode stays active until
/// ALL monitored apps have closed.
class AppMonitor {

    private let configStore: ConfigStore
    private let onActivate: () -> Void
    private let onDeactivate: () -> Void

    /// Number of monitored apps currently running.
    /// Gaming mode activates at 1, deactivates at 0.
    private(set) var activeGameCount = 0

    // MARK: - Init

    init(configStore: ConfigStore,
         onActivate: @escaping () -> Void,
         onDeactivate: @escaping () -> Void) {

        self.configStore = configStore
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate

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

    // MARK: - Initial Check

    /// Count how many monitored apps are already running.
    /// Call this on launch to handle the case where games started before us.
    func checkRunningApps() {
        activeGameCount = 0
        for app in NSWorkspace.shared.runningApplications {
            if shouldMonitor(app) {
                activeGameCount += 1
            }
        }
        if activeGameCount > 0 {
            print("[AppMonitor] \(activeGameCount) monitored app(s) already running")
            DispatchQueue.main.async { self.onActivate() }
        }
    }

    // MARK: - Observers

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              shouldMonitor(app)
        else { return }

        activeGameCount += 1
        print("[AppMonitor] Monitored app launched: \(app.bundleIdentifier ?? "?") "
              + "(active count: \(activeGameCount))")

        if activeGameCount == 1 {
            DispatchQueue.main.async { self.onActivate() }
        }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              shouldMonitor(app)
        else { return }

        activeGameCount = max(0, activeGameCount - 1)
        print("[AppMonitor] Monitored app terminated: \(app.bundleIdentifier ?? "?") "
              + "(active count: \(activeGameCount))")

        if activeGameCount == 0 {
            DispatchQueue.main.async { self.onDeactivate() }
        }
    }

    // MARK: - Matching

    private func shouldMonitor(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }

        return configStore.config.monitoredApps.contains { entry in
            guard entry.isEnabled else { return false }
            return entry.matches(bundleID: bundleID)
        }
    }
}
