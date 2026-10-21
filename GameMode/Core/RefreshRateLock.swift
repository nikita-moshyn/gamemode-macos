//
//  RefreshRateLock.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import ColorSync
import QuartzCore

enum DisplayRefreshMethod: String {
    case none
    case exactMode
    case overlayFallback
}

/// Separate a connected display's identity from the vendor/model key used by
/// older configurations. Incomplete EDIDs must never merge two live displays.
struct DisplayIdentity {
    let displayID: CGDirectDisplayID
    let uuid: String?
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    var legacyID: String {
        if vendor != 0 || model != 0 || serial != 0 { return "\(vendor)-\(model)-\(serial)" }
        return "display-\(displayID)"
    }

    private var preferredID: String {
        guard let uuid, !uuid.isEmpty else { return legacyID }
        return "uuid-\(uuid.lowercased())"
    }

    static func resolvedIDs(_ displays: [DisplayIdentity]) -> [CGDirectDisplayID: String] {
        let groups = Dictionary(grouping: displays, by: \.preferredID)
        return Dictionary(uniqueKeysWithValues: displays.map { display in
            let base = display.preferredID
            // When hardware also repeats its UUID, the connection is the only
            // available disambiguator. Recovery still rejects ambiguous UUIDs.
            let id = groups[base]?.count == 1 ? base : "\(base)-connection-\(display.displayID)"
            return (display.displayID, id)
        })
    }
}

struct DisplaySnapshot: Identifiable, Hashable {
    let id: String
    let legacyID: String
    let name: String
    let isBuiltIn: Bool
    let supportsProMotion: Bool
    let maximumSupportedRefreshRate: Double
    let currentRefreshRate: Double
    let currentModeIsVariable: Bool
    let highestExactRefreshRate: Double
    let canSwitchToHigherRefreshRate: Bool
    let isLowPowerModeBlocked: Bool
    let recommendedMethod: DisplayRefreshMethod

    var supportsManagement: Bool {
        if isBuiltIn {
            return supportsProMotion
        }
        return maximumSupportedRefreshRate > 60.0 || highestExactRefreshRate > 60.0
    }

    func shouldManage(config: DisplayConfig) -> Bool {
        guard config.isRefreshRateLockEnabled, config.isDisplayEnabled(id: id, legacyID: legacyID) else { return false }
        if isBuiltIn { return config.manageBuiltInProMotionDisplay && supportsProMotion }
        return config.manageExternalDisplays && supportsManagement
    }

    func preferredMethod(config: DisplayConfig) -> DisplayRefreshMethod {
        guard shouldManage(config: config), !(isBuiltIn && isLowPowerModeBlocked) else { return .none }
        // External displays have no overlay fallback, so enabling their management
        // must select an available higher fixed mode without an advanced opt-in.
        if canSwitchToHigherRefreshRate && (!isBuiltIn || config.preferExactModeSwitching) { return .exactMode }
        if isBuiltIn && supportsProMotion && config.allowOverlayFallback { return .overlayFallback }
        return .none
    }

    var roleDescription: String {
        isBuiltIn ? "Built-in" : "External"
    }

    var currentRefreshDescription: String {
        Self.format(refreshRate: currentRefreshRate, isVariable: currentModeIsVariable)
    }

    var maximumRefreshDescription: String {
        Self.format(refreshRate: maximumSupportedRefreshRate, isVariable: false)
    }

    var highestExactRefreshDescription: String {
        highestExactRefreshRate > 0.1
            ? Self.format(refreshRate: highestExactRefreshRate, isVariable: false)
            : "No fixed mode"
    }

    var methodDescription: String {
        switch recommendedMethod {
        case .exactMode:
            return "Switch to the highest fixed refresh mode"
        case .overlayFallback:
            return "Use the hidden overlay fallback"
        case .none:
            return "Leave system refresh settings unchanged"
        }
    }

    private static func format(refreshRate: Double, isVariable: Bool) -> String {
        if isVariable || refreshRate <= 0.1 {
            return "Variable"
        }
        return "\(Int(refreshRate.rounded()))Hz"
    }
}

struct DisplayRefreshActivationResult {
    var switchedDisplays: [String] = []
    var overlayDisplays: [String] = []
    var blockedDisplays: [String] = []
    var failedDisplays: [String] = []

    var didApplyAnything: Bool {
        !switchedDisplays.isEmpty || !overlayDisplays.isEmpty
    }

    var summary: String {
        var components: [String] = []
        if !switchedDisplays.isEmpty {
            components.append("mode switch: \(switchedDisplays.joined(separator: ", "))")
        }
        if !overlayDisplays.isEmpty {
            components.append("overlay: \(overlayDisplays.joined(separator: ", "))")
        }
        if !blockedDisplays.isEmpty {
            components.append("blocked by Low Power Mode: \(blockedDisplays.joined(separator: ", "))")
        }
        if !failedDisplays.isEmpty {
            components.append("failed: \(failedDisplays.joined(separator: ", "))")
        }
        return components.isEmpty ? "no display refresh changes applied" : components.joined(separator: "; ")
    }
}

struct DisplayRefreshRestoreResult {
    var restoredDisplays: [String] = []
    var failedDisplays: [String] = []

    var didRestoreAnything: Bool {
        !restoredDisplays.isEmpty
    }

    var summary: String {
        var components: [String] = []
        if !restoredDisplays.isEmpty {
            components.append("restored: \(restoredDisplays.joined(separator: ", "))")
        }
        if !failedDisplays.isEmpty {
            components.append("failed: \(failedDisplays.joined(separator: ", "))")
        }
        return components.isEmpty ? "no display restore required" : components.joined(separator: "; ")
    }
}

/// Manages display refresh behavior during game mode.
///
/// Strategy:
/// - Prefer explicit display mode switching when macOS exposes a fixed high-refresh mode
/// - Fall back to a tiny invisible overlay for built-in ProMotion displays
/// - Restore previous display modes when game mode stops
///
/// Limitations:
/// - Low Power Mode can still cap built-in ProMotion panels at 60Hz
/// - The overlay path remains best-effort; macOS still owns the final refresh decision
/// - External displays can only be forced when a concrete higher-refresh desktop mode exists
final class RefreshRateLock {

    private struct ResolvedDisplay {
        let snapshot: DisplaySnapshot
        let displayID: CGDirectDisplayID
        let currentMode: CGDisplayMode
        let highestExactMode: CGDisplayMode?
        let frame: NSRect
    }

    private var overlayWindows: [NSWindow] = []
    private var overlayDisplayIDs = Set<String>()
    private var displayModeRestores: [DisplayRecoveryRecord] = []
    private var pendingDisplayRestoreIDs = Set<String>()
    private var conflictingDisplayRestoreIDs = Set<String>()
    private var isRestoringDisplayModes = false
    private(set) var automaticRecoveryPaused = false
    private var displayLink: CVDisplayLink?
    private var flipLayers: [CALayer] = []
    private var screenObserver: NSObjectProtocol?
    private var isFlipState = false
    private let displayLinkStateLock = NSLock()
    private var isDisplayLinkActive = false
    private var isFlipScheduled = false

    private(set) var isActive = false

    /// Both callbacks must finish their durable journal updates before returning.
    var willChangeDisplay: ((DisplayRecoveryRecord) throws -> Void)?
    var didRestoreDisplay: ((String) throws -> Void)?

    private static let highRefreshThreshold = 60.0

    static var isProMotionAvailable: Bool {
        displaySnapshots().contains { $0.isBuiltIn && $0.supportsProMotion }
    }

    static var maxRefreshRate: Int {
        Int((displaySnapshots()
            .filter { $0.isBuiltIn && $0.supportsProMotion }
            .map(\.maximumSupportedRefreshRate)
            .max() ?? 60.0).rounded())
    }

    static func displaySnapshots() -> [DisplaySnapshot] {
        resolvedDisplays().map(\.snapshot)
    }

    #if FEATURE_DISPLAYS
    @discardableResult
    func start(config: DisplayConfig) -> DisplayRefreshActivationResult {
        performOnMain {
            startOnMain(config: config)
        }
    }
    #endif

    @discardableResult
    func stop() -> DisplayRefreshRestoreResult {
        performOnMain {
            stopOnMain()
        }
    }

    /// Forget recovery only after the user explicitly accepts current settings as normal.
    /// Removes process-owned overlays without changing any display mode.
    func abandonCurrentSession() {
        performOnMain {
            displayModeRestores.removeAll()
            pendingDisplayRestoreIDs.removeAll()
            conflictingDisplayRestoreIDs.removeAll()
            automaticRecoveryPaused = false
            _ = stopCurrentSession(restoreModes: false)
        }
    }

    /// Pause reconnect-triggered setters before the user accepts their current settings.
    func pauseAutomaticRecovery() {
        performOnMain { automaticRecoveryPaused = true }
    }

    func resumeAutomaticRecovery() {
        performOnMain {
            automaticRecoveryPaused = false
            if !pendingDisplayRestoreIDs.isEmpty { installScreenObserver() }
        }
    }

    /// Retain unavailable displays so a later retry can use their original modes.
    func captureRecoverySettings() -> [DisplayRecoveryRecord] {
        performOnMain { Self.resolvedDisplays().compactMap { self.recoveryRecord(for: $0) } }
    }

    func restorePersistedDisplayModes(_ records: [DisplayRecoveryRecord]) -> [String] {
        performOnMain {
            var conflicts: [String] = []
            for record in records {
                if let existing = displayModeRestores.first(where: { $0.displayUUID == record.displayUUID }) {
                    if existing != record {
                        conflicts.append("\(record.displayName) (conflicting original display mode)")
                        conflictingDisplayRestoreIDs.insert(record.displayUUID)
                    }
                } else {
                    displayModeRestores.append(record)
                }
                pendingDisplayRestoreIDs.insert(record.displayUUID)
            }
            let result = restoreDisplayModes(only: pendingDisplayRestoreIDs)
            isActive = !displayModeRestores.isEmpty || !flipLayers.isEmpty
            if !pendingDisplayRestoreIDs.isEmpty { installScreenObserver() }
            return conflicts + result.failedDisplays
        }
    }

    // MARK: - Start / Stop

    #if FEATURE_DISPLAYS
    private func startOnMain(config: DisplayConfig) -> DisplayRefreshActivationResult {
        let restoreResult = stopCurrentSession(restoreModes: true)
        guard restoreResult.failedDisplays.isEmpty, displayModeRestores.isEmpty else {
            var result = DisplayRefreshActivationResult()
            result.failedDisplays = restoreResult.failedDisplays.isEmpty
                ? displayModeRestores.map { "\($0.displayName) (original mode is awaiting recovery)" }
                : restoreResult.failedDisplays
            return result
        }

        guard config.isRefreshRateLockEnabled else {
            Log.info("Display refresh management disabled in config", category: "Display")
            return DisplayRefreshActivationResult()
        }

        var result = DisplayRefreshActivationResult()
        let displays = Self.resolvedDisplays()

        for display in displays where display.snapshot.shouldManage(config: config) {
            if display.snapshot.isBuiltIn && display.snapshot.isLowPowerModeBlocked {
                result.blockedDisplays.append(display.snapshot.name)
                continue
            }

            var appliedExactMode = false

            if display.snapshot.preferredMethod(config: config) == .exactMode,
               let targetMode = display.highestExactMode,
               needsExactModeSwitch(from: display.currentMode, to: targetMode) {
                if let record = recoveryRecord(for: display),
                   !displayModeRestores.contains(where: { $0.displayUUID == record.displayUUID }),
                   let willChangeDisplay {
                    do {
                        try willChangeDisplay(record)
                        displayModeRestores.append(record)
                        let error = CGDisplaySetDisplayMode(display.displayID, targetMode, nil)
                        if error == .success {
                            result.switchedDisplays.append(display.snapshot.name)
                            appliedExactMode = true
                            Log.info("Display mode switched to \(Int(targetMode.refreshRate.rounded()))Hz for \(display.snapshot.name)", category: "Display")
                        } else {
                            pendingDisplayRestoreIDs.insert(record.displayUUID)
                            result.failedDisplays.append("\(display.snapshot.name) (mode switch error \(error.rawValue))")
                            Log.warning("Failed to switch display mode for \(display.snapshot.name): \(error.rawValue)", category: "Display")
                        }
                    } catch {
                        result.failedDisplays.append("\(display.snapshot.name) (original mode could not be saved)")
                        Log.error("Display checkpoint failed: \(error)", category: "Display")
                    }
                } else {
                    result.failedDisplays.append("\(display.snapshot.name) (original mode unavailable or awaiting recovery)")
                }
            }

            if !appliedExactMode,
               display.snapshot.isBuiltIn,
               display.snapshot.supportsProMotion,
               config.allowOverlayFallback {
                let window = createOverlayWindow(for: display)
                guard let layer = window.contentView?.layer?.sublayers?.first else {
                    window.orderOut(nil)
                    result.failedDisplays.append("\(display.snapshot.name) (overlay setup failed)")
                    continue
                }

                overlayWindows.append(window)
                overlayDisplayIDs.insert(display.snapshot.id)
                flipLayers.append(layer)
                result.overlayDisplays.append(display.snapshot.name)
            }
        }

        if !flipLayers.isEmpty || !pendingDisplayRestoreIDs.isEmpty {
            installScreenObserver()
            if !flipLayers.isEmpty { startDisplayLink() }
        } else {
            removeScreenObserver()
        }

        isActive = !displayModeRestores.isEmpty || !flipLayers.isEmpty
        Log.info("Display refresh management apply result: \(result.summary)", category: "Display")
        return result
    }

    #endif

    private func stopOnMain() -> DisplayRefreshRestoreResult {
        let result = stopCurrentSession(restoreModes: true)
        Log.info("Display refresh management restore result: \(result.summary)", category: "Display")
        return result
    }

    private func stopCurrentSession(restoreModes: Bool) -> DisplayRefreshRestoreResult {
        stopDisplayLink()
        removeScreenObserver()
        clearOverlays()

        let restoreResult = restoreModes ? restoreDisplayModes() : DisplayRefreshRestoreResult()
        overlayDisplayIDs.removeAll()
        flipLayers.removeAll()
        isFlipState = false
        isActive = !displayModeRestores.isEmpty
        if !pendingDisplayRestoreIDs.isEmpty { installScreenObserver() }

        return restoreResult
    }

    // MARK: - Overlay

    private func createOverlayWindow(for display: ResolvedDisplay) -> NSWindow {
        let window = NSWindow(
            contentRect: overlayRect(for: display.frame),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.level = .screenSaver + 1
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = overlayCollectionBehavior()
        window.hasShadow = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        contentView.wantsLayer = true

        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        layer.backgroundColor = NSColor.black.cgColor

        contentView.layer?.addSublayer(layer)
        window.contentView = contentView
        window.orderFrontRegardless()

        return window
    }

    private func overlayRect(for frame: NSRect) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - 1, width: 1, height: 1)
    }

    private func overlayCollectionBehavior() -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        if #available(macOS 15.0, *) {
            behavior.insert(.canJoinAllApplications)
        }

        return behavior
    }

    private func clearOverlays() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
    }

    private func installScreenObserver() {
        guard screenObserver == nil else { return }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenConfigurationChange()
        }
    }

    private func removeScreenObserver() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
    }

    private func handleScreenConfigurationChange() {
        if !automaticRecoveryPaused && !pendingDisplayRestoreIDs.isEmpty {
            let result = restoreDisplayModes(only: pendingDisplayRestoreIDs)
            Log.info("Display recovery retry: \(result.summary)", category: "Display")
            isActive = !displayModeRestores.isEmpty || !flipLayers.isEmpty
        }
        guard !overlayDisplayIDs.isEmpty else { return }

        stopDisplayLink()
        clearOverlays()
        flipLayers.removeAll()

        let displays = Self.resolvedDisplays()
        for display in displays where overlayDisplayIDs.contains(display.snapshot.id) {
            let window = createOverlayWindow(for: display)
            guard let layer = window.contentView?.layer?.sublayers?.first else {
                window.orderOut(nil)
                continue
            }

            overlayWindows.append(window)
            flipLayers.append(layer)
        }

        if !flipLayers.isEmpty {
            startDisplayLink()
        }
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard !flipLayers.isEmpty else { return }

        stopDisplayLink()

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)

        guard let displayLink = link else {
            Log.error("Failed to create CVDisplayLink", category: "Display")
            return
        }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo else { return kCVReturnSuccess }
            let engine = Unmanaged<RefreshRateLock>.fromOpaque(userInfo).takeUnretainedValue()
            engine.scheduleFlipPixel()
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, callback, Unmanaged.passUnretained(self).toOpaque())
        self.displayLink = displayLink
        isFlipState = false

        displayLinkStateLock.lock()
        isDisplayLinkActive = true
        isFlipScheduled = false
        displayLinkStateLock.unlock()

        CVDisplayLinkStart(displayLink)
    }

    private func stopDisplayLink() {
        displayLinkStateLock.lock()
        isDisplayLinkActive = false
        isFlipScheduled = false
        displayLinkStateLock.unlock()

        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
    }

    private func scheduleFlipPixel() {
        displayLinkStateLock.lock()
        let shouldSchedule = isDisplayLinkActive && !isFlipScheduled
        if shouldSchedule {
            isFlipScheduled = true
        }
        displayLinkStateLock.unlock()

        guard shouldSchedule else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.displayLinkStateLock.lock()
            let shouldFlip = self.isDisplayLinkActive
            self.isFlipScheduled = false
            self.displayLinkStateLock.unlock()

            guard shouldFlip else { return }
            self.flipPixelOnMain()
        }
    }

    private func flipPixelOnMain() {
        guard !flipLayers.isEmpty else { return }

        isFlipState.toggle()
        let color = isFlipState
            ? CGColor(gray: 0.01, alpha: 1.0)
            : CGColor(gray: 0.0, alpha: 1.0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in flipLayers {
            layer.backgroundColor = color
        }
        CATransaction.commit()
    }

    // MARK: - Restore

    private func restoreDisplayModes(only requestedIDs: Set<String>? = nil) -> DisplayRefreshRestoreResult {
        guard !displayModeRestores.isEmpty, !isRestoringDisplayModes else { return DisplayRefreshRestoreResult() }
        isRestoringDisplayModes = true
        defer { isRestoringDisplayModes = false }

        let displaysByUUID = Dictionary(grouping: Self.activeDisplayIDs(), by: { Self.displayUUID(for: $0) })
        var result = DisplayRefreshRestoreResult()
        var completed = Set<String>()

        for restore in displayModeRestores {
            if let requestedIDs, !requestedIDs.contains(restore.displayUUID) { continue }
            pendingDisplayRestoreIDs.insert(restore.displayUUID)
            guard !conflictingDisplayRestoreIDs.contains(restore.displayUUID) else {
                result.failedDisplays.append("\(restore.displayName) (conflicting original display mode)")
                continue
            }
            guard let displayIDs = displaysByUUID[restore.displayUUID], displayIDs.count == 1,
                  let displayID = displayIDs.first else {
                result.failedDisplays.append("\(restore.displayName) (display unavailable or ambiguous)")
                continue
            }

            guard let mode = Self.findMode(matching: restore.mode, on: displayID) else {
                result.failedDisplays.append("\(restore.displayName) (previous mode missing)")
                continue
            }

            let alreadyRestored = CGDisplayCopyDisplayMode(displayID).map { Self.modeMatches($0, signature: restore.mode) } ?? false
            let error = alreadyRestored ? CGError.success : CGDisplaySetDisplayMode(displayID, mode, nil)
            guard error == .success else {
                result.failedDisplays.append("\(restore.displayName) (restore error \(error.rawValue))")
                continue
            }
            guard let currentMode = CGDisplayCopyDisplayMode(displayID), Self.modeMatches(currentMode, signature: restore.mode) else {
                result.failedDisplays.append("\(restore.displayName) (restored mode could not be verified)")
                continue
            }
            guard let didRestoreDisplay else {
                result.failedDisplays.append("\(restore.displayName) (recovery checkpoint unavailable)")
                continue
            }
            do {
                try didRestoreDisplay(restore.displayUUID)
                completed.insert(restore.displayUUID)
                result.restoredDisplays.append(restore.displayName)
            } catch {
                result.failedDisplays.append("\(restore.displayName) (recovery completion could not be saved)")
                Log.error("Display recovery checkpoint failed: \(error)", category: "Display")
            }
        }
        displayModeRestores.removeAll { completed.contains($0.displayUUID) }
        pendingDisplayRestoreIDs.subtract(completed)
        return result
    }

    // MARK: - Display Discovery

    private func needsExactModeSwitch(from currentMode: CGDisplayMode, to targetMode: CGDisplayMode) -> Bool {
        if currentMode.ioDisplayModeID == targetMode.ioDisplayModeID,
           currentMode.ioFlags == targetMode.ioFlags {
            return false
        }

        if currentMode.refreshRate <= 0.1 {
            return true
        }

        return targetMode.refreshRate > currentMode.refreshRate + 0.5
    }

    private func modeSignature(for mode: CGDisplayMode) -> RecoveryDisplayMode {
        RecoveryDisplayMode(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate,
            ioFlags: mode.ioFlags,
            modeID: mode.ioDisplayModeID
        )
    }

    private func recoveryRecord(for display: ResolvedDisplay) -> DisplayRecoveryRecord? {
        guard let uuid = Self.displayUUID(for: display.displayID),
              Self.activeDisplayIDs().filter({ Self.displayUUID(for: $0) == uuid }).count == 1 else { return nil }
        return DisplayRecoveryRecord(displayUUID: uuid, displayName: display.snapshot.name, mode: modeSignature(for: display.currentMode))
    }

    private static func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let value = CFUUIDCreateString(kCFAllocatorDefault, uuid) else { return nil }
        return value as String
    }

    private static func findMode(matching signature: RecoveryDisplayMode, on displayID: CGDirectDisplayID) -> CGDisplayMode? {
        let modes = (CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode]) ?? []
        let candidates = modes.filter { modeMatches($0, signature: signature) }
        if let exact = candidates.first(where: { $0.ioDisplayModeID == signature.modeID }) { return exact }
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func modeMatches(_ mode: CGDisplayMode, signature: RecoveryDisplayMode) -> Bool {
        mode.width == signature.width && mode.height == signature.height &&
        mode.pixelWidth == signature.pixelWidth && mode.pixelHeight == signature.pixelHeight &&
        mode.ioFlags == signature.ioFlags && abs(mode.refreshRate - signature.refreshRate) <= 0.5
    }

    private static func resolvedDisplays() -> [ResolvedDisplay] {
        let screenMap = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (CGDirectDisplayID(number.uint32Value), screen)
        })

        let identities = activeDisplayIDs().map { displayID in
            DisplayIdentity(displayID: displayID, uuid: displayUUID(for: displayID), vendor: CGDisplayVendorNumber(displayID), model: CGDisplayModelNumber(displayID), serial: CGDisplaySerialNumber(displayID))
        }
        let resolvedIDs = DisplayIdentity.resolvedIDs(identities)
        return identities.compactMap { identity -> ResolvedDisplay? in
            let displayID = identity.displayID
            guard let currentMode = CGDisplayCopyDisplayMode(displayID) else {
                return nil
            }

            let screen = screenMap[displayID]
            let name = screen?.localizedName ?? defaultDisplayName(for: displayID)
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let currentRefreshRate = currentMode.refreshRate
            let currentModeIsVariable = currentRefreshRate <= 0.1

            let exactModes = ((CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode]) ?? [])
                .filter { $0.isUsableForDesktopGUI() }
                .filter { mode in
                    mode.width == currentMode.width &&
                    mode.height == currentMode.height &&
                    mode.pixelWidth == currentMode.pixelWidth &&
                    mode.pixelHeight == currentMode.pixelHeight &&
                    mode.refreshRate > 0.1
                }

            let highestExactMode = exactModes.max { lhs, rhs in
                lhs.refreshRate < rhs.refreshRate
            }

            let highestExactRefreshRate = highestExactMode?.refreshRate ?? 0.0
            let maximumFramesPerSecond = Double(screen?.maximumFramesPerSecond ?? 0)
            let minimumRefreshInterval = screen?.minimumRefreshInterval ?? 1.0
            let supportsProMotion = isBuiltIn && (
                maximumFramesPerSecond > highRefreshThreshold ||
                minimumRefreshInterval <= 0.00834
            )
            let maximumSupportedRefreshRate = max(maximumFramesPerSecond, highestExactRefreshRate, currentRefreshRate)
            let canSwitchToHigherRefreshRate = highestExactMode.map { mode in
                currentMode.refreshRate <= 0.1 || mode.refreshRate > currentMode.refreshRate + 0.5
            } ?? false
            let isLowPowerModeBlocked = isBuiltIn && supportsProMotion && PowerManager.isLowPowerModeEnabled

            let recommendedMethod: DisplayRefreshMethod
            if canSwitchToHigherRefreshRate {
                recommendedMethod = .exactMode
            } else if supportsProMotion && !isLowPowerModeBlocked {
                recommendedMethod = .overlayFallback
            } else {
                recommendedMethod = .none
            }

            let snapshot = DisplaySnapshot(
                id: resolvedIDs[displayID]!,
                legacyID: identity.legacyID,
                name: name,
                isBuiltIn: isBuiltIn,
                supportsProMotion: supportsProMotion,
                maximumSupportedRefreshRate: maximumSupportedRefreshRate,
                currentRefreshRate: currentRefreshRate,
                currentModeIsVariable: currentModeIsVariable,
                highestExactRefreshRate: highestExactRefreshRate,
                canSwitchToHigherRefreshRate: canSwitchToHigherRefreshRate,
                isLowPowerModeBlocked: isLowPowerModeBlocked,
                recommendedMethod: recommendedMethod
            )

            let displayBounds = CGDisplayBounds(displayID)
            let frame = screen?.frame ?? NSRect(
                x: displayBounds.origin.x,
                y: displayBounds.origin.y,
                width: displayBounds.size.width,
                height: displayBounds.size.height
            )
            return ResolvedDisplay(
                snapshot: snapshot,
                displayID: displayID,
                currentMode: currentMode,
                highestExactMode: highestExactMode,
                frame: frame
            )
        }
    }

    private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return []
        }

        return Array(displays.prefix(Int(count)))
    }

    private static func defaultDisplayName(for displayID: CGDirectDisplayID) -> String {
        CGDisplayIsBuiltin(displayID) != 0 ? "Built-in Display" : "Display \(displayID)"
    }

    private func performOnMain<T>(_ block: () -> T) -> T {
        if Thread.isMainThread {
            return block()
        }
        return DispatchQueue.main.sync(execute: block)
    }

    deinit {
        stopDisplayLink()
        removeScreenObserver()
    }
}
