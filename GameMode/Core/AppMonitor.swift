//
//  AppMonitor.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
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
    private let onMonitoredAppLaunched: ((MonitoredApp) -> Void)?
    private let onMonitoredAppTerminated: ((MonitoredApp) -> Void)?

    /// Number of monitored apps currently running.
    /// Gaming mode activates at 1, deactivates at 0.
    private(set) var activeGameCount = 0

    /// Bundle IDs of monitored apps currently running.
    private(set) var activeAppBundleIDs = Set<String>()

    // MARK: - Init

    init(configStore: ConfigStore,
         onActivate: @escaping () -> Void,
         onDeactivate: @escaping () -> Void,
         onMonitoredAppLaunched: ((MonitoredApp) -> Void)? = nil,
         onMonitoredAppTerminated: ((MonitoredApp) -> Void)? = nil) {

        self.configStore = configStore
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
        self.onMonitoredAppLaunched = onMonitoredAppLaunched
        self.onMonitoredAppTerminated = onMonitoredAppTerminated

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
        activeAppBundleIDs.removeAll()
        for app in NSWorkspace.shared.runningApplications {
            if shouldMonitor(app) {
                activeGameCount += 1
                if let bundleID = app.bundleIdentifier {
                    activeAppBundleIDs.insert(bundleID)
                }
            }
        }
        if activeGameCount > 0 {
            Log.info("\(activeGameCount) monitored app(s) already running", category: "AppMonitor")
            DispatchQueue.main.async { self.onActivate() }
        } else {
            Log.debug("No monitored apps currently running", category: "AppMonitor")
        }
    }

    // MARK: - Observers

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              let matchedEntry = matchingMonitoredApp(bundleID: bundleID)
        else { return }

        activeGameCount += 1
        activeAppBundleIDs.insert(bundleID)
        Log.info("Monitored app launched: \(bundleID) (active count: \(activeGameCount))", category: "AppMonitor")

        if activeGameCount == 1 {
            DispatchQueue.main.async { self.onActivate() }
        }

        DispatchQueue.main.async { self.onMonitoredAppLaunched?(matchedEntry) }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              let matchedEntry = matchingMonitoredApp(bundleID: bundleID)
        else { return }

        activeGameCount = max(0, activeGameCount - 1)
        activeAppBundleIDs.remove(bundleID)
        Log.info("Monitored app terminated: \(bundleID) (active count: \(activeGameCount))", category: "AppMonitor")

        if activeGameCount == 0 {
            DispatchQueue.main.async { self.onDeactivate() }
        }

        DispatchQueue.main.async { self.onMonitoredAppTerminated?(matchedEntry) }
    }

    // MARK: - Matching

    private func shouldMonitor(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        return matchingMonitoredApp(bundleID: bundleID) != nil
    }

    private func matchingMonitoredApp(bundleID: String) -> MonitoredApp? {
        configStore.config.monitoredApps.first { entry in
            guard entry.isEnabled else { return false }
            return entry.matches(bundleID: bundleID)
        }
    }

    /// Check if any currently active monitored app requires refresh rate lock.
    func anyActiveAppNeedsRefreshRateLock() -> Bool {
        for bundleID in activeAppBundleIDs {
            if let entry = matchingMonitoredApp(bundleID: bundleID), entry.lockRefreshRate {
                return true
            }
        }
        return false
    }
}
