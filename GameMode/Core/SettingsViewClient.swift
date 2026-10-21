//
//  SettingsViewClient.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import ComposableArchitecture
import ConcurrencyExtras
import ServiceManagement

struct SettingsDisplayStatus: Equatable, Sendable {
    var displays: [DisplaySnapshot] = []
    var lowPowerModeEnabled = false
    var batteryLevel: Int?
}

enum LoginItemStatus: Equatable, Sendable {
    case enabled, requiresApproval, notRegistered, notFound
}

struct ApplicationCandidate: Equatable, Identifiable, Sendable {
    var bundleID: String
    var name: String
    var url: URL?
    var id: String { bundleID }
}

/// Platform reads and native panels stay outside reducers. Preview/test clients
/// never scan the computer, display a panel, or register a login item.
struct SettingsViewClient: Sendable {
    enum Failure: LocalizedError {
        case missingBundleIdentifier
        var errorDescription: String? { "The selected application does not have a bundle identifier." }
    }

    var scanGames: @Sendable () async -> [MonitoredApp]
    var runningApplications: @MainActor @Sendable () -> [ApplicationCandidate]
    var browseApplication: @MainActor @Sendable () async throws -> ApplicationCandidate?
    var displayStatus: @MainActor @Sendable () -> SettingsDisplayStatus
    var loginStatus: @MainActor @Sendable () -> LoginItemStatus
    var setLaunchAtLogin: @MainActor @Sendable (Bool) throws -> LoginItemStatus

    var recoveryStatus: @Sendable () -> RecoveryStatus = { .init() }
    var openRecoverySettings: @MainActor @Sendable () -> Void = {}
    var chooseRecoveryKitDestination: @MainActor @Sendable () async -> URL? = { nil }
    var chooseRecoveryFile: @MainActor @Sendable () async -> URL? = { nil }
    var readRecoveryFile: @Sendable (URL) throws -> RecoveryBackup = { try RecoveryBackup.read(from: $0) }

    static let liveValue = Self(scanGames: {
        await Task.detached(priority: .userInitiated) { AppDetector.scanForGames() }.value
    }, runningApplications: {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, app.activationPolicy == .regular,
                  bundleID != Bundle.main.bundleIdentifier, seen.insert(bundleID).inserted else { return nil }
            return ApplicationCandidate(bundleID: bundleID, name: app.localizedName ?? bundleID, url: app.bundleURL)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }, browseApplication: {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add Application"
        let response = await withTaskCancellationHandler {
            guard !Task.isCancelled else { return NSApplication.ModalResponse.cancel }
            return await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            throw Failure.missingBundleIdentifier
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return ApplicationCandidate(bundleID: bundleID, name: name, url: url)
    }, displayStatus: {
        SettingsDisplayStatus(displays: RefreshRateLock.displaySnapshots(), lowPowerModeEnabled: PowerManager.isLowPowerModeEnabled, batteryLevel: PowerManager.batteryLevel)
    }, loginStatus: { currentLoginStatus() }, setLaunchAtLogin: { enabled in
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
        return currentLoginStatus()
    }, recoveryStatus: {
        var status = RecoveryStatus()
        switch SMAppService.agent(plistName: RecoveryAgentFiles.serviceName + ".plist").status {
        case .enabled: status.protection = RecoveryAgentFiles.live.isRunning ? .ready : .waiting
        case .requiresApproval: status.protection = .approval
        case .notRegistered: status.protection = .disabled
        case .notFound: status.protection = .unavailable
        @unknown default: status.protection = .unavailable
        }
        return status
    }, openRecoverySettings: {
        SMAppService.openSystemSettingsLoginItems()
    }, chooseRecoveryKitDestination: { await RecoveryFilePanels.save() },
        chooseRecoveryFile: { await RecoveryFilePanels.open() })

    static var previewValue: Self {
        let status = LockIsolated(LoginItemStatus.notRegistered)
        return Self(scanGames: { [] }, runningApplications: { [] }, browseApplication: { nil }, displayStatus: { .init() }, loginStatus: { status.value }, setLaunchAtLogin: {
            status.setValue($0 ? .enabled : .notRegistered)
            return status.value
        })
    }

    @MainActor
    private static func currentLoginStatus() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notRegistered
        }
    }
}

extension SettingsViewClient: TestDependencyKey {
    static let testValue = Self(scanGames: unimplemented("SettingsViewClient.scanGames", placeholder: []), runningApplications: unimplemented("SettingsViewClient.runningApplications", placeholder: []), browseApplication: unimplemented("SettingsViewClient.browseApplication", placeholder: nil), displayStatus: unimplemented("SettingsViewClient.displayStatus", placeholder: .init()), loginStatus: unimplemented("SettingsViewClient.loginStatus", placeholder: .notRegistered), setLaunchAtLogin: unimplemented("SettingsViewClient.setLaunchAtLogin", placeholder: .notRegistered))
}

extension DependencyValues {
    var settingsViewClient: SettingsViewClient {
        get { self[SettingsViewClient.self] }
        set { self[SettingsViewClient.self] = newValue }
    }
}
