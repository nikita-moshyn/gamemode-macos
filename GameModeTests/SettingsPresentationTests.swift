//
//  SettingsPresentationTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import Combine
import ComposableArchitecture
import SwiftUI
import ConcurrencyExtras
import XCTest
@testable import GameMode

final class SettingsPresentationTests: XCTestCase {
    override func record(_ issue: XCTIssue) {
        if issue.compactDescription.contains("Publishing changes from within view updates")
            || issue.compactDescription.contains("Modifying state during view update") {
            super.record(XCTIssue(type: .assertionFailure, compactDescription: issue.compactDescription))
        } else {
            super.record(issue)
        }
    }
    @MainActor
    func testDockPresenceLastsUntilBothSettingsAndAboutCloseInEitherOrder() {
        for settingsClosesFirst in [true, false] {
            var policies: [NSApplication.ActivationPolicy] = []
            let presentation = AppWindowPresentation(setActivationPolicy: { policies.append($0) }, activate: {})
            let settings = makePresentationWindow(title: "Settings")
            let about = makePresentationWindow(title: "About")
            presentation.show(settings)
            presentation.show(about)
            presentation.show(settings)
            XCTAssertEqual(policies, [.regular], "Reusing or adding a window must not cycle Dock visibility")

            let first = settingsClosesFirst ? settings : about
            let last = settingsClosesFirst ? about : settings
            first.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(policies, [.regular])
            last.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(policies, [.regular, .accessory])
            XCTAssertFalse(presentation.reopenLastWindow(), "Closed reusable windows must not keep the app in the Dock")
        }
    }

    @MainActor
    func testHiddenWindowKeepsDockPresenceAndDockReopenBringsItBack() {
        var policies: [NSApplication.ActivationPolicy] = []
        var activations = 0
        let presentation = AppWindowPresentation(setActivationPolicy: { policies.append($0) }, activate: { activations += 1 })
        let window = makePresentationWindow(title: "Settings")
        presentation.show(window)
        window.orderOut(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(policies, [.regular])
        XCTAssertTrue(presentation.reopenLastWindow())
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(policies, [.regular])
        window.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(policies, [.regular, .accessory])
    }

    @MainActor
    func testOpeningAnotherWindowDuringCloseDoesNotFlashDockIcon() {
        var policies: [NSApplication.ActivationPolicy] = []
        let presentation = AppWindowPresentation(setActivationPolicy: { policies.append($0) }, activate: {})
        let settings = makePresentationWindow(title: "Settings")
        let about = makePresentationWindow(title: "About")
        presentation.show(settings)
        settings.close()
        presentation.show(about)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(policies, [.regular])
        about.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(policies, [.regular, .accessory])
        presentation.show(settings)
        XCTAssertEqual(policies, [.regular, .accessory, .regular])
        settings.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(policies.last, .accessory)
    }

    @MainActor
    func testAppKitActivationPolicyTracksWindowLifetime() {
        let initialPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(initialPolicy) }
        NSApp.setActivationPolicy(.accessory)
        let presentation = AppWindowPresentation(activate: {})
        let window = makePresentationWindow(title: "Settings")
        presentation.show(window)
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
        window.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
    }

    @MainActor
    private func makePresentationWindow(title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 200), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    func testOpeningAndRevisitingInputGuardRefreshesShortcutsWhileMasterIsOff() throws {
        let suite = "GameMode.ShortcutDiscoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SettingsSection.shortcuts.rawValue, forKey: "GameModeSettingsSection")
        let detected = LockIsolated([ShortcutEntry(id: 999, name: "First shortcut", category: "Test", disableInGamingMode: true)])
        let detections = LockIsolated(0)
        let store = SettingsTestDriver(defaults: defaults, isPreview: true, shortcutDetector: {
            detections.withValue { $0 += 1 }
            return detected.value
        })
        let root = SettingsWindow(store: store.settingsStore)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        waitForUI("Input Guard completes its first shortcut scan") {
            detections.value > 0 && window.contentView.flatMap { self.findOutlineView(in: $0) }?.selectedRow == 1
        }

        XCTAssertGreaterThan(detections.value, 0)
        XCTAssertFalse(store.config.isInputGuardEnabled)
        XCTAssertEqual(store.config.shortcuts.first { $0.id == 999 }?.disableInGamingMode, false)
        store.toggleShortcut(id: 999)
        let outline = try XCTUnwrap(window.contentView.flatMap { self.findOutlineView(in: $0) })
        for shortcutID in 1000...1002 {
            if shortcutID == 1001 { outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            else { store.settingsStore.send(.sectionSelected(.general)) }
            waitForUI("General is selected and its navigation request is consumed") {
                store.settingsStore.selectedSection == .general
                    && defaults.string(forKey: "GameModeSettingsSection") == SettingsSection.general.rawValue
                    && window.contentView.flatMap { self.findOutlineView(in: $0) }?.selectedRow == 0
            }
            XCTAssertEqual(store.settingsStore.selectedSection, .general)
            XCTAssertEqual(defaults.string(forKey: "GameModeSettingsSection"), SettingsSection.general.rawValue)
            XCTAssertEqual(window.contentView.flatMap { self.findOutlineView(in: $0) }?.selectedRow, 0)
            let previousDetections = detections.value
            detected.withValue { $0.append(ShortcutEntry(id: shortcutID, name: "Another shortcut", category: "Test", disableInGamingMode: true)) }
            if shortcutID == 1002 { outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false) }
            else { store.settingsStore.send(.sectionSelected(.shortcuts)) }
            waitForUI("Revisiting Input Guard discovers shortcut \(shortcutID)") {
                store.settingsStore.selectedSection == .shortcuts && detections.value > previousDetections
                    && window.contentView.flatMap { self.findOutlineView(in: $0) }?.selectedRow == 1
                    && store.config.shortcuts.contains { $0.id == shortcutID }
            }

            XCTAssertEqual(store.config.shortcuts.first { $0.id == 999 }?.disableInGamingMode, true)
            XCTAssertEqual(store.config.shortcuts.first { $0.id == shortcutID }?.disableInGamingMode, false)
            XCTAssertFalse(store.config.isInputGuardEnabled)
        }
    }

    @MainActor
    func testRapidNavigationAndRecoveryDismissTheApplicationSheet() async throws {
        let suite = "GameMode.NavigationPresentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SettingsClient.preferences(defaults, detectShortcuts: { [] })
        var state = preferences.load()
        state.isPreview = true
        let root = Store(initialState: GameModeFeature.State(settings: state)) { GameModeFeature() } withDependencies: {
            $0.settingsClient = preferences
            $0.settingsViewClient = .previewValue
        }
        let store = root.scope(state: \.settings, action: \.settings)
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsWindow(store: store)))
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        waitForUI("Sidebar is ready") { window.contentView.flatMap { self.findOutlineView(in: $0) }?.selectedRow == 0 }
        let outline = try XCTUnwrap(window.contentView.flatMap { self.findOutlineView(in: $0) })
        for _ in 0..<3 {
            outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            store.send(.sectionSelected(.mouse))
            store.send(.sectionSelected(.hotkeys))
            store.send(.sectionSelected(.system))
        }
        waitForUI("The last requested destination wins") {
            store.selectedSection == .system && outline.selectedRow == SettingsSection.availableCases.firstIndex(of: .system)
        }
        XCTAssertEqual(defaults.string(forKey: "GameModeSettingsSection"), "system")
        XCTAssertNil(defaults.data(forKey: "GameModeConfig_v2"))
        store.send(.sectionSelected(.applications))
        waitForUI("Applications is selected") { outline.selectedRow == SettingsSection.availableCases.firstIndex(of: .applications) }
        let presentation = store.send(.addAppButtonTapped)
        waitForUI("Application picker is presented") { window.sheets.count == 1 }
        await root.send(.session(.recoveryStarted)).finish()
        waitForUI("Recovery dismisses the picker") { store.appPicker == nil && window.sheets.isEmpty }
        await presentation.finish()
        XCTAssertFalse(store.canEdit)
        XCTAssertNil(defaults.data(forKey: "GameModeConfig_v2"))
    }

    @MainActor
    private func waitForUI(_ description: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), description, file: file, line: line)
    }

    @MainActor
    func testFormerLogsSelectionOpensSystemWithoutChangingSavedConfiguration() throws {
        let suite = "GameMode.SettingsMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = GameModeConfig.defaults
        config.loggingEnabled = false
        config.logLevel = .error
        config.display.preferExactModeSwitching = false
        config.display.allowOverlayFallback = false
        config.mouse.gamingSpeed = 2.7
        let savedConfiguration = try JSONEncoder().encode(config)
        defaults.set(savedConfiguration, forKey: "GameModeConfig_v2")
        defaults.set("logs", forKey: "GameModeSettingsSection")
        let store = SettingsTestDriver(defaults: defaults, isPreview: true)
        let root = SettingsWindow(store: store.settingsStore)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        XCTAssertEqual(defaults.string(forKey: "GameModeSettingsSection"), "system")
        XCTAssertEqual(defaults.data(forKey: "GameModeConfig_v2"), savedConfiguration)
        XCTAssertFalse(store.config.loggingEnabled)
        XCTAssertEqual(store.config.logLevel, .error)
        XCTAssertFalse(store.config.display.preferExactModeSwitching)
        XCTAssertFalse(store.config.display.allowOverlayFallback)
        XCTAssertEqual(store.config.mouse.gamingSpeed, 2.7)
        for section in SettingsSection.availableCases {
            XCTAssertEqual(SettingsSection.resolve(section.rawValue), section)
        }
    }

    func testLegacyMouseHotkeyUsesCurrentNameWithoutChangingStoredIdentity() throws {
        let original = AppHotkey(id: "toggleMouseBoost", name: "Toggle Mouse Boost", keyCode: 5, modifiers: 256, isEnabled: true)
        let restored = try JSONDecoder().decode(AppHotkey.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.displayName, "Toggle Mouse Preset")
        XCTAssertEqual(restored.id, "toggleMouseBoost")
        XCTAssertEqual(restored.name, "Toggle Mouse Boost")
        XCTAssertEqual(restored.keyCode, 5)
    }

    func testUnknownHotkeyRetainsItsDisplayName() {
        let custom = AppHotkey(id: "futureAction", name: "Custom action", keyCode: nil, modifiers: 0, isEnabled: false)
        XCTAssertEqual(custom.displayName, "Custom action")
    }

    func testManualApplicationRejectsWhitespaceMalformedAndDuplicateIdentifiers() {
        XCTAssertNotNil(ApplicationPickerValidation.problem(for: " \n", existingIDs: []))
        XCTAssertNotNil(ApplicationPickerValidation.problem(for: "com.example game", existingIDs: []))
        XCTAssertNotNil(ApplicationPickerValidation.problem(for: "com..game", existingIDs: []))
        XCTAssertNotNil(ApplicationPickerValidation.problem(for: " com.example.game ", existingIDs: ["com.example.game"]))
        XCTAssertNil(ApplicationPickerValidation.problem(for: " com.example.game ", existingIDs: []))
    }

    func testManualApplicationRetainsPrefixPatternsWithoutAcceptingMalformedWildcards() {
        let pattern = "com.example.games.*"
        XCTAssertNil(ApplicationPickerValidation.problem(for: " \(pattern) ", existingIDs: []))
        XCTAssertNotNil(ApplicationPickerValidation.problem(for: pattern, existingIDs: [pattern]))
        for invalid in [".*", "*", "com.*.game", "com.example*", "com.example..*", "com.example.**"] {
            XCTAssertNotNil(ApplicationPickerValidation.problem(for: invalid, existingIDs: []), invalid)
        }
        let app = MonitoredApp(id: UUID(), bundleID: pattern, name: "Games", isEnabled: true, source: .manual)
        XCTAssertTrue(app.matches(bundleID: "com.example.games.first"))
        XCTAssertFalse(app.matches(bundleID: "com.other.game"))
    }

    #if FEATURE_DISPLAYS
    @MainActor
    func testDisplayApplicationSelectionsRemainEditableAndPersistWithoutResettingOtherSettings() throws {
        let suite = "GameMode.DisplaySelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsTestDriver(defaults: defaults, isPreview: true)
        let enabled = MonitoredApp(id: UUID(), bundleID: "test.custom.game", name: "Custom game", isEnabled: true, source: .manual)
        let disabled = MonitoredApp(id: UUID(), bundleID: "test.disabled.game", name: "Disabled game", isEnabled: false, source: .manual, lockRefreshRate: true)
        store.config.monitoredApps = [enabled, disabled]
        store.config.mouse.gamingSpeed = 2.7
        store.config.display.isRefreshRateLockEnabled = true
        let original = defaults.data(forKey: "GameModeConfig_v2")
        let pane = DisplaySettingsView(store: store.settingsStore)
        XCTAssertEqual(pane.refreshRateApps.map(\.id), [enabled.id])
        XCTAssertFalse(pane.refreshRateBinding(for: enabled.id).wrappedValue)
        XCTAssertEqual(defaults.data(forKey: "GameModeConfig_v2"), original, "Presenting controls must not rewrite choices")

        pane.refreshRateBinding(for: enabled.id).wrappedValue = true
        var reloaded = SettingsTestDriver(defaults: defaults, isPreview: true).config
        XCTAssertTrue(try XCTUnwrap(reloaded.monitoredApps.first { $0.id == enabled.id }).lockRefreshRate)
        XCTAssertEqual(reloaded.monitoredApps[1], disabled)
        XCTAssertEqual(reloaded.mouse.gamingSpeed, 2.7)
        pane.refreshRateBinding(for: enabled.id).wrappedValue = false
        reloaded = SettingsTestDriver(defaults: defaults, isPreview: true).config
        XCTAssertFalse(reloaded.monitoredApps[0].lockRefreshRate)
        XCTAssertTrue(reloaded.monitoredApps[1].lockRefreshRate)
    }

    #endif

    func testIdenticalDisplaysUseUniqueStableIDsAndInheritExistingSelections() throws {
        let first = DisplayIdentity(displayID: 1, uuid: "SCREEN-A", vendor: 10, model: 20, serial: 0)
        let second = DisplayIdentity(displayID: 2, uuid: "SCREEN-B", vendor: 10, model: 20, serial: 0)
        let ids = DisplayIdentity.resolvedIDs([first, second])
        let firstID = try XCTUnwrap(ids[first.displayID])
        let secondID = try XCTUnwrap(ids[second.displayID])
        XCTAssertNotEqual(firstID, secondID)
        let reconnected = DisplayIdentity(displayID: 99, uuid: first.uuid, vendor: first.vendor, model: first.model, serial: first.serial)
        XCTAssertEqual(DisplayIdentity.resolvedIDs([reconnected])[99], firstID)

        let original = ManagedDisplayPreference(id: first.legacyID, name: "Existing display", isEnabled: false)
        var config = DisplayConfig(managedDisplays: [original])
        XCTAssertFalse(config.isDisplayEnabled(id: firstID, legacyID: first.legacyID))
        XCTAssertFalse(config.isDisplayEnabled(id: secondID, legacyID: second.legacyID))
        XCTAssertEqual(config.managedDisplays, [original])
        config.setDisplayEnabled(true, id: firstID, name: "First display")
        config = try JSONDecoder().decode(DisplayConfig.self, from: JSONEncoder().encode(config))
        XCTAssertTrue(config.isDisplayEnabled(id: firstID, legacyID: first.legacyID))
        XCTAssertFalse(config.isDisplayEnabled(id: secondID, legacyID: second.legacyID))
        XCTAssertEqual(config.managedDisplays.first, original)
    }

    func testRepeatedOrMissingDisplayUUIDsCannotMergeConnectedDisplays() {
        for uuid in [nil, "REPEATED-UUID"] as [String?] {
            let displays = [1, 2].map { DisplayIdentity(displayID: UInt32($0), uuid: uuid, vendor: 10, model: 20, serial: 0) }
            let ids = DisplayIdentity.resolvedIDs(displays)
            XCTAssertEqual(ids.count, 2)
            XCTAssertEqual(Set(ids.values).count, 2)
            XCTAssertEqual(DisplayIdentity.resolvedIDs(Array(displays.reversed())), ids)
        }
    }

    func testManagedExternalDisplayUsesFixedModeWithoutAdvancedOptIn() throws {
        let config = DisplayConfig(isRefreshRateLockEnabled: true, manageExternalDisplays: true)
        let restored = try JSONDecoder().decode(DisplayConfig.self, from: JSONEncoder().encode(config))
        let display = makeDisplaySnapshot(isBuiltIn: false)
        XCTAssertFalse(restored.preferExactModeSwitching)
        XCTAssertEqual(display.preferredMethod(config: restored), .exactMode)
    }

    func testExternalDisplayManagementHonorsMasterCategoryAndPerDisplayOptOut() {
        let display = makeDisplaySnapshot(isBuiltIn: false)
        var config = DisplayConfig(isRefreshRateLockEnabled: true, manageExternalDisplays: true)
        config.isRefreshRateLockEnabled = false
        XCTAssertEqual(display.preferredMethod(config: config), .none)
        config.isRefreshRateLockEnabled = true
        config.manageExternalDisplays = false
        XCTAssertEqual(display.preferredMethod(config: config), .none)
        config.manageExternalDisplays = true
        config.setDisplayEnabled(false, id: display.id, name: display.name)
        XCTAssertEqual(display.preferredMethod(config: config), .none)
        config.setDisplayEnabled(true, id: display.id, name: display.name)
        XCTAssertEqual(display.preferredMethod(config: config), .exactMode)
    }

    func testBuiltInDisplayRetainsOverlayFallbackAndFixedModePreference() {
        let display = makeDisplaySnapshot(isBuiltIn: true)
        var config = DisplayConfig(isRefreshRateLockEnabled: true)
        XCTAssertEqual(display.preferredMethod(config: config), .overlayFallback)
        config.allowOverlayFallback = false
        XCTAssertEqual(display.preferredMethod(config: config), .none)
        config.preferExactModeSwitching = true
        XCTAssertEqual(display.preferredMethod(config: config), .exactMode)
        config.manageBuiltInProMotionDisplay = false
        XCTAssertEqual(display.preferredMethod(config: config), .none)
        config.manageBuiltInProMotionDisplay = true
        XCTAssertEqual(makeDisplaySnapshot(isBuiltIn: true, isLowPowerModeBlocked: true).preferredMethod(config: config), .none)
    }

    func testExternalDisplayWithoutHigherFixedModeDoesNotUseOverlay() {
        let display = makeDisplaySnapshot(isBuiltIn: false, canSwitchToHigherRefreshRate: false)
        let config = DisplayConfig(isRefreshRateLockEnabled: true, manageExternalDisplays: true)
        XCTAssertTrue(config.allowOverlayFallback)
        XCTAssertEqual(display.preferredMethod(config: config), .none)
    }

    private func makeDisplaySnapshot(isBuiltIn: Bool, canSwitchToHigherRefreshRate: Bool = true, isLowPowerModeBlocked: Bool = false) -> DisplaySnapshot {
        DisplaySnapshot(id: "test-display", legacyID: "test-legacy", name: "Test display", isBuiltIn: isBuiltIn,
                        supportsProMotion: isBuiltIn, maximumSupportedRefreshRate: 120,
                        currentRefreshRate: canSwitchToHigherRefreshRate ? 60 : 120, currentModeIsVariable: false,
                        highestExactRefreshRate: 120, canSwitchToHigherRefreshRate: canSwitchToHigherRefreshRate,
                        isLowPowerModeBlocked: isLowPowerModeBlocked, recommendedMethod: .exactMode)
    }

    @MainActor
    func testRecorderEscapeRemovesMonitorBeforeStreamFinishes() async throws {
        let monitor = FakeShortcutMonitor()
        let stream = ShortcutRecordingClient.stream(addMonitor: monitor.install, removeMonitor: monitor.remove)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertNil(monitor.handler?(escape))
        XCTAssertTrue(monitor.activeTokens.isEmpty)
        var iterator = stream.makeAsyncIterator()
        let key = await iterator.next()
        XCTAssertNil(key)
        XCTAssertEqual(monitor.removeCount, 1)
    }

    @MainActor
    func testRecorderCancellationRemovesMonitor() async {
        let monitor = FakeShortcutMonitor()
        let listening = expectation(description: "Recorder starts listening")
        let removed = expectation(description: "Cancellation removes the event monitor")
        let stream = ShortcutRecordingClient.stream(addMonitor: monitor.install, removeMonitor: { token in
            monitor.remove(token)
            removed.fulfill()
        })
        let task = Task {
            listening.fulfill()
            for await _ in stream {}
        }
        await fulfillment(of: [listening], timeout: 2)
        task.cancel()
        await task.value
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertTrue(monitor.activeTokens.isEmpty)
        XCTAssertEqual(monitor.removeCount, 1)
    }

    @MainActor
    func testRecorderInstallationFailureFinishesStream() async {
        let stream = ShortcutRecordingClient.stream(addMonitor: { _ in nil }, removeMonitor: { _ in XCTFail("No monitor was installed") })
        var iterator = stream.makeAsyncIterator()
        let key = await iterator.next()
        XCTAssertNil(key)
    }

    @MainActor
    func testMenuRowStateAndAccessibilityFollowAuthoritativeUpdates() {
        let row = MenuToggleRow(title: "Game Mode", showsStatus: true)
        let item = NSMenuItem(title: "Game Mode", action: nil, keyEquivalent: "g")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.view = row
        let menu = NSMenu()
        menu.addItem(item)

        row.update(isOn: false, isEnabled: true, status: "Disabled", shortcut: "⇧⌘G")
        XCTAssertEqual(row.toggle.state, .off)
        XCTAssertEqual(row.toggle.accessibilityLabel(), "Game Mode")
        XCTAssertEqual(row.toggle.accessibilityHelp(), "Disabled. ⇧⌘G")
        XCTAssertTrue(row.toggle.isEnabled)

        row.update(isOn: true, isEnabled: false, status: "Enabling…", shortcut: "⇧⌘G")
        XCTAssertEqual(row.toggle.state, .on)
        XCTAssertFalse(row.toggle.isEnabled)
        XCTAssertEqual(row.toggle.accessibilityHelp(), "Enabling…. ⇧⌘G")
        XCTAssertTrue(menu.item(at: 0) === item)
        XCTAssertTrue(item.view === row)
        XCTAssertEqual(item.keyEquivalent, "g")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])

        row.update(isOn: false, isEnabled: false, status: "Recovery Required")
        XCTAssertEqual(row.toggle.state, .off)
        XCTAssertEqual(row.toggle.accessibilityHelp(), "Recovery Required")
        XCTAssertEqual(row.toggle.toolTip, "Game Mode")
    }

    @MainActor
    func testMenuPointerAndSwitchActionsRespectDisabledState() throws {
        let row = MenuToggleRow(title: "Mouse Preset", showsStatus: false)
        var invocationCount = 0
        row.onToggle = { invocationCount += 1 }
        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))

        row.update(isOn: false, isEnabled: true)
        row.mouseUp(with: mouseUp)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(row.toggle.state, .off, "A request must wait for the authoritative state update")
        row.toggle.sendAction(row.toggle.action, to: row.toggle.target)
        XCTAssertEqual(invocationCount, 2)

        row.update(isOn: true, isEnabled: false)
        row.mouseUp(with: mouseUp)
        row.toggle.sendAction(row.toggle.action, to: row.toggle.target)
        XCTAssertEqual(invocationCount, 2)
    }

    @MainActor
    func testBusyMenuRowKeepsSelectionAndAppearanceWhileBlockingRepeatedInput() throws {
        let row = MenuToggleRow(title: "Mouse Preset", showsStatus: false)
        var actions = 0
        row.onToggle = { actions += 1 }
        row.update(isOn: false, isEnabled: true)
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: 20, y: 12), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        row.mouseEntered(with: entered)
        row.layoutSubtreeIfNeeded()
        let frame = row.frame
        let labels = row.subviews.compactMap { $0 as? NSTextField }
        let colors = labels.map(\.textColor)

        row.update(isOn: true, isEnabled: true, isBusy: true)
        XCTAssertTrue(row.isHighlighted)
        XCTAssertTrue(row.toggle.isEnabled, "Busy must not flash disabled switch artwork")
        XCTAssertFalse(row.toggle.isAccessibilityEnabled())
        XCTAssertFalse(row.toggle.accessibilityPerformPress())
        row.toggle.sendAction(row.toggle.action, to: row.toggle.target)
        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 20, y: 12), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        row.mouseUp(with: mouseUp)
        XCTAssertEqual(actions, 0)
        XCTAssertEqual(row.toggle.state, .on)
        XCTAssertEqual(labels.map(\.textColor), colors)
        XCTAssertEqual(row.frame, frame)

        row.update(isOn: true, isEnabled: true)
        XCTAssertTrue(row.isHighlighted)
        XCTAssertTrue(row.toggle.isAccessibilityEnabled())
        XCTAssertEqual(row.toggle.state, .on)
        XCTAssertEqual(row.frame, frame)
        row.mouseUp(with: mouseUp)
        XCTAssertEqual(actions, 1)
    }

    @MainActor
    func testMenuHoverCoversLabelsAndResetsOnExitOrKeyboardNavigation() throws {
        let row = MenuToggleRow(title: "Game Mode", showsStatus: true)
        row.update(isOn: false, isEnabled: true, status: "Disabled")
        row.layoutSubtreeIfNeeded()
        XCTAssertTrue(row.hitTest(NSPoint(x: 20, y: 25)) === row)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: 20, y: 25), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        row.mouseEntered(with: event)
        XCTAssertTrue(row.isHighlighted)
        row.mouseExited(with: event)
        XCTAssertFalse(row.isHighlighted)
        row.setMenuHighlighted(true)
        XCTAssertTrue(row.isHighlighted)
        row.setMenuHighlighted(false, clearPointer: true)
        XCTAssertFalse(row.isHighlighted)
        row.update(isOn: false, isEnabled: false, status: "Recovery Required")
        row.mouseEntered(with: event)
        XCTAssertFalse(row.isHighlighted)
    }

    @MainActor
    func testReleasingOutsideMenuRowDoesNotToggle() throws {
        let row = MenuToggleRow(title: "Game Mode", showsStatus: true)
        row.update(isOn: false, isEnabled: true, status: "Disabled")
        row.onToggle = { XCTFail("Dragging out of a row must cancel the click") }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -20, y: -20), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        row.mouseUp(with: event)
    }

    func testPendingMousePresentationDoesNotBounceSwitchOrFlashGameModeTransition() {
        for requestedState in [true, false] {
            var presentation = MenuModePresentation(gameModeEnabled: true, mouseProfileEnabled: !requestedState,
                                                    isTransitioning: true, gameModeTarget: true,
                                                    mouseProfileTarget: requestedState, requiresRecovery: false)
            XCTAssertEqual(presentation.mouseSwitchIsOn, requestedState)
            XCTAssertEqual(presentation.status, "Enabled")
            // The worker's result can arrive before the UI's completion callback.
            presentation.mouseProfileEnabled = requestedState
            XCTAssertEqual(presentation.mouseSwitchIsOn, requestedState)
            XCTAssertEqual(presentation.status, "Enabled")
            presentation.mouseProfileTarget = nil
            presentation.isTransitioning = false
            XCTAssertEqual(presentation.mouseSwitchIsOn, requestedState)
            XCTAssertEqual(presentation.status, "Enabled")

            presentation.isTransitioning = true
            presentation.gameModeTarget = false
            XCTAssertEqual(presentation.status, "Disabling…")
            presentation.requiresRecovery = true
            XCTAssertEqual(presentation.status, "Recovery Required")
        }
    }

    @MainActor
    func testCustomMenuViewKeepsKeyboardEquivalentWhenStateChanges() throws {
        let target = MenuActionRecorder()
        let item = NSMenuItem(title: "Game Mode", action: #selector(MenuActionRecorder.toggle(_:)), keyEquivalent: "g")
        item.target = target
        item.keyEquivalentModifierMask = [.command, .shift]
        let row = MenuToggleRow(title: "Game Mode", showsStatus: true)
        item.view = row
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: "G", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5))

        row.update(isOn: false, isEnabled: true, status: "Disabled")
        XCTAssertTrue(menu.performKeyEquivalent(with: key))
        XCTAssertEqual(target.invocationCount, 1)
        row.update(isOn: true, isEnabled: true, status: "Enabled")
        XCTAssertTrue(menu.performKeyEquivalent(with: key))
        XCTAssertEqual(target.invocationCount, 2)
        item.isEnabled = false
        row.update(isOn: true, isEnabled: false, status: "Disabling…")
        _ = menu.performKeyEquivalent(with: key)
        XCTAssertEqual(target.invocationCount, 2)
    }

    func testMenuActionsRemainUnavailableUntilRecoveryAndTransitionFinish() {
        let suite = "GameMode.SettingsPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsTestDriver(defaults: defaults, isPreview: true)
        XCTAssertTrue(store.canChangeMode)
        store.isTransitioning = true
        XCTAssertFalse(store.canChangeMode)
        store.recoveryRequired = true
        store.isTransitioning = false
        XCTAssertFalse(store.canChangeMode)
        store.recoveryRequired = false
        XCTAssertTrue(store.canChangeMode)
        defaults.set(Data("Unreadable configuration".utf8), forKey: "GameModeConfig_v2")
        let damaged = SettingsTestDriver(defaults: defaults, isPreview: true)
        XCTAssertFalse(damaged.canChangeMode)
        damaged.resetAllSavedData()
        XCTAssertTrue(damaged.canChangeMode)
    }

    @MainActor
    func testMouseRowRevealExpandsNativeMenuWithoutInsertionOrRemovalJumps() {
        var now: TimeInterval = 0
        let menu = NSMenu()
        menu.addItem(withTitle: "Game Mode", action: nil, keyEquivalent: "")
        let item = NSMenuItem(title: "Mouse Preset", action: nil, keyEquivalent: "")
        let row = MenuToggleRow(title: item.title, showsStatus: false)
        let reveal = MenuRowRevealView(row: row, item: item, clock: { now }, reduceMotion: { false })
        menu.addItem(item)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
        let collapsedHeight = menu.size.height

        reveal.setExpanded(true, animated: true)
        XCTAssertTrue(reveal.isAnimating)
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(menu.size.height, collapsedHeight, accuracy: 0.5, "Unhiding a zero-height view must not jump the menu")
        XCTAssertFalse(row.toggle.isAccessibilityEnabled())
        XCTAssertNil(reveal.hitTest(NSPoint(x: 20, y: 5)))

        now = 0.1
        reveal.advanceAnimation()
        reveal.layoutSubtreeIfNeeded()
        XCTAssertEqual(reveal.frame.height, 14, accuracy: 0.5)
        XCTAssertEqual(menu.size.height, collapsedHeight + 14, accuracy: 0.5)
        XCTAssertEqual(row.alphaValue, 0.5, accuracy: 0.01)
        XCTAssertEqual(row.frame.height, 28, "The content must be clipped, never compressed")

        now = 0.21
        reveal.advanceAnimation()
        XCTAssertFalse(reveal.isAnimating)
        XCTAssertEqual(menu.size.height, collapsedHeight + 28, accuracy: 0.5)
        XCTAssertEqual(row.alphaValue, 1)
        XCTAssertTrue(row.toggle.isAccessibilityEnabled())
        XCTAssertTrue(item.view === reveal)

        reveal.setExpanded(false, animated: true)
        XCTAssertFalse(item.isHidden, "Keep the same item visible until collapse completes")
        XCTAssertFalse(row.toggle.isAccessibilityEnabled())
        now = 0.31
        reveal.advanceAnimation()
        XCTAssertEqual(menu.size.height, collapsedHeight + 14, accuracy: 0.5)
        now = 0.42
        reveal.advanceAnimation()
        XCTAssertTrue(item.isHidden)
        XCTAssertEqual(menu.size.height, collapsedHeight, accuracy: 0.5)
        XCTAssertEqual(reveal.frame.height, 0)
        XCTAssertEqual(row.alphaValue, 0)
        XCTAssertFalse(reveal.isAnimating)
    }

    @MainActor
    func testRepeatedRevealUpdatesDoNotRestartAndReversingDoesNotSnap() {
        var now: TimeInterval = 0
        let item = NSMenuItem()
        let row = MenuToggleRow(title: "Mouse Preset", showsStatus: false)
        let reveal = MenuRowRevealView(row: row, item: item, clock: { now }, reduceMotion: { false })
        reveal.setExpanded(true, animated: true)
        now = 0.1
        reveal.advanceAnimation()
        reveal.setExpanded(true, animated: true)
        now = 0.21
        reveal.advanceAnimation()
        XCTAssertFalse(reveal.isAnimating, "An unrelated menu update must not restart the reveal")

        reveal.setExpanded(false, animated: true)
        now = 0.31
        reveal.advanceAnimation()
        let intermediateHeight = reveal.frame.height
        let intermediateAlpha = row.alphaValue
        reveal.setExpanded(true, animated: true)
        XCTAssertEqual(reveal.frame.height, intermediateHeight)
        XCTAssertEqual(row.alphaValue, intermediateAlpha)
        XCTAssertFalse(item.isHidden)
        now = 0.42
        reveal.advanceAnimation()
        XCTAssertEqual(reveal.frame.height, 28)
        XCTAssertEqual(row.alphaValue, 1)
        XCTAssertFalse(reveal.isAnimating)
    }

    @MainActor
    func testClosingMenuAndReducedMotionFinishRevealImmediately() {
        var now: TimeInterval = 0
        var reducedMotion = false
        let item = NSMenuItem()
        let row = MenuToggleRow(title: "Mouse Preset", showsStatus: false)
        let reveal = MenuRowRevealView(row: row, item: item, clock: { now }, reduceMotion: { reducedMotion })
        reveal.setExpanded(true, animated: true)
        now = 0.05
        reveal.advanceAnimation()
        reveal.finishAnimation()
        XCTAssertEqual(reveal.frame.height, 28)
        XCTAssertFalse(reveal.isAnimating)
        XCTAssertTrue(row.toggle.isAccessibilityEnabled())

        reveal.setExpanded(false, animated: false)
        XCTAssertEqual(reveal.frame.height, 0)
        XCTAssertTrue(item.isHidden)
        reducedMotion = true
        reveal.setExpanded(true, animated: true)
        XCTAssertEqual(reveal.frame.height, 28)
        XCTAssertEqual(row.alphaValue, 1)
        XCTAssertFalse(reveal.isAnimating)
        reducedMotion = false
        reveal.setExpanded(false, animated: true)
        reducedMotion = true
        reveal.advanceAnimation()
        XCTAssertTrue(item.isHidden)
        XCTAssertFalse(reveal.isAnimating)
    }

    @MainActor
    func testRevealTimerAdvancesDuringNativeMenuTracking() {
        var now: TimeInterval = 0
        let item = NSMenuItem()
        let row = MenuToggleRow(title: "Mouse Preset", showsStatus: false)
        let reveal = MenuRowRevealView(row: row, item: item, clock: { now }, reduceMotion: { false })
        reveal.setExpanded(true, animated: true)
        now = 1
        let deadline = Date().addingTimeInterval(0.25)
        while reveal.isAnimating && Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
        XCTAssertFalse(reveal.isAnimating, "A default-mode-only timer would stall until the menu closes")
        XCTAssertEqual(reveal.frame.height, 28)
    }

    @MainActor
    func testRevealingRowBlocksInputAndPreservesBusyStateAtCompletion() {
        let item = NSMenuItem()
        let row = MenuToggleRow(title: "Mouse Preset", showsStatus: false)
        let reveal = MenuRowRevealView(row: row, item: item, reduceMotion: { false })
        row.onToggle = { XCTFail("Partially revealed or busy controls must not activate") }
        row.update(isOn: false, isEnabled: true)
        reveal.setExpanded(true, animated: true)
        row.setMenuHighlighted(true)
        XCTAssertFalse(row.isHighlighted)
        XCTAssertFalse(row.toggle.accessibilityPerformPress())
        row.toggle.sendAction(row.toggle.action, to: row.toggle.target)
        row.update(isOn: false, isEnabled: true, isBusy: true)
        reveal.finishAnimation()
        XCTAssertTrue(row.toggle.isEnabled, "Keep native switch artwork stable")
        XCTAssertFalse(row.toggle.isAccessibilityEnabled())
        row.toggle.sendAction(row.toggle.action, to: row.toggle.target)
        row.update(isOn: false, isEnabled: true)
        XCTAssertTrue(row.toggle.isAccessibilityEnabled())
    }

    /// Exercise AppKit's actual tracking loop with isolated controls and no settings actions.
    @MainActor
    func testOpenMenuKeepsItsWindowAndHeaderStableThroughoutReveal() throws {
        let output = URL(fileURLWithPath: "/tmp/gamemode-ui-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let menu = NSMenu()
            menu.autoenablesItems = false
            let tracking = MenuTrackingRecorder()
            menu.delegate = tracking
            let game = MenuToggleRow(title: "Game Mode", showsStatus: true)
            game.update(isOn: true, isEnabled: true, status: "Enabled")
            let gameItem = NSMenuItem(title: "Game Mode", action: nil, keyEquivalent: "")
            gameItem.view = game
            menu.addItem(gameItem)
            let item = NSMenuItem(title: "Mouse Preset", action: nil, keyEquivalent: "")
            let mouse = MenuToggleRow(title: item.title, showsStatus: false)
            var now: TimeInterval = 0
            let reveal = MenuRowRevealView(row: mouse, item: item, clock: { now }, reduceMotion: { false })
            mouse.update(isOn: false, isEnabled: true)
            menu.addItem(item)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
            menu.addItem(withTitle: "Quit GameMode", action: nil, keyEquivalent: "q")
            var phase = 0
            var originalWindow: NSWindow?
            var originalTop: CGFloat = 0
            var heights: [CGFloat] = []
            let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
                defer { phase += 1 }
                if phase == 0 {
                    originalWindow = game.window
                    originalTop = game.window?.frame.maxY ?? 0
                    reveal.setExpanded(true, animated: true)
                } else if phase <= 4 {
                    now = Double(phase) * 0.05 + 0.001
                    reveal.advanceAnimation()
                } else if phase == 5 {
                    reveal.setExpanded(false, animated: true)
                } else if phase <= 9 {
                    now = 0.201 + Double(phase - 5) * 0.05 + 0.001
                    reveal.advanceAnimation()
                } else {
                    timer.invalidate()
                    menu.cancelTrackingWithoutAnimation()
                    return
                }
                XCTAssertNotNil(originalWindow)
                XCTAssertTrue(game.window === originalWindow, "The menu must keep the same window")
                XCTAssertEqual(game.window?.frame.maxY ?? 0, originalTop, accuracy: 0.5)
                heights.append(menu.size.height)
                if let view = game.window?.contentView {
                    view.layoutSubtreeIfNeeded()
                    view.displayIfNeeded()
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        let data = bitmap.representation(using: .png, properties: [:])
                        try? data?.write(to: output.appendingPathComponent("menu-reveal-\(appearanceName)-\(phase).png"), options: .atomic)
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
            defer { timer.invalidate(); reveal.finishAnimation() }
            let top = NSScreen.main?.visibleFrame.maxY ?? 500
            menu.popUp(positioning: nil, at: NSPoint(x: 30, y: top - 50), in: nil)
            XCTAssertEqual(tracking.openCount, 1)
            XCTAssertEqual(tracking.closeCount, 1, "Reveal must never close and reopen the menu")
            XCTAssertEqual(heights.count, 10)
            if heights.count == 10 {
                XCTAssertEqual(heights[0], heights[9], accuracy: 0.5)
                XCTAssertEqual(heights[4] - heights[0], 28, accuracy: 0.5)
                XCTAssertTrue(zip(heights[0...3], heights[1...4]).allSatisfy { $0 <= $1 })
                XCTAssertTrue(zip(heights[5...8], heights[6...9]).allSatisfy { $0 >= $1 })
            }
        }
    }


    /// Own-view rendering; never captures the desktop or starts GameMode's engines.
    @MainActor
    func testRenderSettingsForVisualReview() throws {
        let output = URL(fileURLWithPath: "/tmp/gamemode-ui-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        let sizes = [NSSize(width: 820, height: 600), NSSize(width: 720, height: 500)]
        for (appearanceName, appearance) in appearances {
            for size in sizes {
                for section in SettingsSection.availableCases {
                    try renderSettings(section: section, appearance: appearance, size: size, output: output.appendingPathComponent("\(section.rawValue)-\(Int(size.width))x\(Int(size.height))-\(appearanceName).png"))
                }
            }
        }
    }

    @MainActor
    private func renderSettings(section: SettingsSection, appearance: NSAppearance.Name, size: NSSize, output: URL) throws {
        let suite = "GameMode.RenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(section.rawValue, forKey: "GameModeSettingsSection")
        let store = SettingsTestDriver(defaults: defaults, isPreview: true)
        store.isAccessibilityGranted = true
        store.settingsStore.send(.sectionSelected(section))
        let root = SettingsWindow(store: store.settingsStore)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.title = "GameMode Settings"
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "SettingsRenderToolbar")
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }

        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        if section == .general, size.width == 820, appearance == .aqua {
            try viewHierarchy(view).write(to: output.deletingLastPathComponent().appendingPathComponent("native-view-hierarchy.txt"), atomically: true, encoding: .utf8)
        }
        if section == .general, let outline = findOutlineView(in: view) {
            XCTAssertEqual(outline.numberOfRows, SettingsSection.availableCases.count)
            let sidebarBitmap = try XCTUnwrap(outline.bitmapImageRepForCachingDisplay(in: outline.bounds))
            outline.cacheDisplay(in: outline.bounds, to: sidebarBitmap)
            let sidebarData = try XCTUnwrap(sidebarBitmap.representation(using: .png, properties: [:]))
            try sidebarData.write(to: output.deletingLastPathComponent().appendingPathComponent("sidebar-content-\(output.lastPathComponent)"), options: .atomic)
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), "No bitmap for \(section.title)")
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output, options: .atomic)

        // Native cacheDisplay can fail to draw hosted SwiftUI on some runtimes.
        // Require variation across the whole image so a flat/transparent image is rejected.
        var luminances = Set<Int>()
        var opaqueSamples = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.1 {
                    opaqueSamples += 1
                    luminances.insert(Int((color.redComponent + color.greenComponent + color.blueComponent) * 85))
                }
            }
        }
        XCTAssertGreaterThan(opaqueSamples, 100, "Transparent render: \(output.lastPathComponent)")
        XCTAssertGreaterThan(luminances.count, 12, "Blank or incomplete render: \(output.lastPathComponent)")
        if let scroll = findFormScrollView(in: view), let document = scroll.documentView {
            // Capture every page of long forms so moved controls below the fold
            // receive the same visual review as the first screenful.
            let pageHeight = scroll.contentView.bounds.height * 0.8
            let maximumOffset = max(0, document.bounds.height - scroll.contentView.bounds.height)
            if pageHeight > 0, maximumOffset > 0 {
                for page in 1...Int(ceil(maximumOffset / pageHeight)) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(CGFloat(page) * pageHeight, maximumOffset)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    view.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    let pageBitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: pageBitmap)
                    let pageData = try XCTUnwrap(pageBitmap.representation(using: .png, properties: [:]))
                    let pageURL = output.deletingPathExtension().appendingPathExtension("scroll-\(page).png")
                    try pageData.write(to: pageURL, options: .atomic)
                }
            }
        }
        print("Settings render: \(output.path)")
    }

    @MainActor
    private func findFormScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil, !(scroll.documentView is NSTableView) { return scroll }
        return view.subviews.lazy.compactMap { self.findFormScrollView(in: $0) }.first
    }


    @MainActor
    private func findOutlineView(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap { self.findOutlineView(in: $0) }.first
    }

    @MainActor
    private func viewHierarchy(_ view: NSView, depth: Int = 0) -> String {
        let row = "\(String(repeating: "  ", count: depth))\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) layer=\(String(describing: view.layer))\n"
        return row + view.subviews.map { viewHierarchy($0, depth: depth + 1) }.joined()
    }

    @MainActor
    func testRenderMenuRowsForVisualReview() throws {
        let output = URL(fileURLWithPath: "/tmp/gamemode-ui-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let states: [(name: String, isOn: Bool, enabled: Bool, busy: Bool, status: String, showMouse: Bool, mouseOn: Bool, hover: Bool)] = [
            ("disabled", false, true, false, "Disabled", false, false, false),
            ("enabled", true, true, false, "Enabled", true, true, false),
            ("profile-off", true, true, false, "Enabled", true, false, false),
            ("transition", true, true, true, "Enabling…", false, false, false),
            ("recovery", false, false, false, "Recovery Required", false, false, false),
            ("hover", false, true, false, "Disabled", false, false, true),
            ("mouse-hover", true, true, false, "Enabled", true, false, true),
            ("mouse-busy", true, true, true, "Enabled", true, true, true)
        ]
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for state in states {
                let game = MenuToggleRow(title: "Game Mode", showsStatus: true)
                let mouse = MenuToggleRow(title: "Mouse Preset", showsStatus: false)
                let height = game.frame.height + (state.showMouse ? mouse.frame.height : 0) + 8
                let container = MenuRenderBackground(frame: NSRect(x: 0, y: 0, width: game.frame.width, height: height))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: game.frame.width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = container
                game.frame.origin = NSPoint(x: 0, y: height - game.frame.height - 4)
                game.update(isOn: state.isOn, isEnabled: state.enabled, isBusy: state.busy, status: state.status, shortcut: "⇧⌘G")
                game.setMenuHighlighted(state.hover && !state.showMouse)
                container.addSubview(game)
                if state.showMouse {
                    mouse.frame.origin = NSPoint(x: 0, y: 4)
                    mouse.update(isOn: state.mouseOn, isEnabled: state.enabled, isBusy: state.busy, shortcut: "⇧⌘M")
                    mouse.setMenuHighlighted(state.hover)
                    container.addSubview(mouse)
                }
                window.orderBack(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                container.layoutSubtreeIfNeeded()
                container.displayIfNeeded()
                let bitmap = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
                container.cacheDisplay(in: container.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: output.appendingPathComponent("menu-rows-\(state.name)-\(appearanceName).png"), options: .atomic)
                window.orderOut(nil)
                window.close()
            }
        }
    }

}


private final class MenuActionRecorder: NSObject {
    var invocationCount = 0

    @objc func toggle(_ sender: Any?) {
        invocationCount += 1
    }
}

private final class MenuTrackingRecorder: NSObject, NSMenuDelegate {
    var openCount = 0
    var closeCount = 0

    func menuWillOpen(_ menu: NSMenu) { openCount += 1 }
    func menuDidClose(_ menu: NSMenu) { closeCount += 1 }
}


private final class FakeShortcutMonitor {
    var installCount = 0
    var removeCount = 0
    var activeTokens = Set<ObjectIdentifier>()
    var handler: ((NSEvent) -> NSEvent?)?

    func install(_ handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        let token = NSObject()
        installCount += 1
        activeTokens.insert(ObjectIdentifier(token))
        self.handler = handler
        return token
    }

    func remove(_ token: Any) {
        removeCount += 1
        activeTokens.remove(ObjectIdentifier(token as AnyObject))
    }
}


/// Neutral native background for inspecting the row controls without menu tracking.
private final class MenuRenderBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
