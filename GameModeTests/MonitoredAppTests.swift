//
//  MonitoredAppTests.swift
//  GameMode
//
//  Created by Nikita Moshyn on 21/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import XCTest
@testable import GameMode

final class MonitoredAppTests: XCTestCase {

    // MARK: - Exact Matching

    func test_exactMatch_sameID_returnsTrue() {
        let app = MonitoredApp(
            id: UUID(), bundleID: "com.nvidia.gfnpc.mall",
            name: "GeForce Now", isEnabled: true, source: .preset
        )
        XCTAssertTrue(app.matches(bundleID: "com.nvidia.gfnpc.mall"))
    }

    func test_exactMatch_differentID_returnsFalse() {
        let app = MonitoredApp(
            id: UUID(), bundleID: "com.nvidia.gfnpc.mall",
            name: "GeForce Now", isEnabled: true, source: .preset
        )
        XCTAssertFalse(app.matches(bundleID: "com.nvidia.other"))
    }

    // MARK: - Prefix Matching

    func test_prefixMatch_matchingPrefix_returnsTrue() {
        let app = MonitoredApp(
            id: UUID(), bundleID: "com.valvesoftware.steam.app.*",
            name: "Steam Games", isEnabled: true, source: .preset
        )
        XCTAssertTrue(app.matches(bundleID: "com.valvesoftware.steam.app.730"))
    }

    func test_prefixMatch_nonMatchingPrefix_returnsFalse() {
        let app = MonitoredApp(
            id: UUID(), bundleID: "com.valvesoftware.steam.app.*",
            name: "Steam Games", isEnabled: true, source: .preset
        )
        XCTAssertFalse(app.matches(bundleID: "com.epicgames.something"))
    }

    func test_prefixMatch_exactBaseWithDot_returnsTrue() {
        let app = MonitoredApp(
            id: UUID(), bundleID: "com.valvesoftware.steam.app.*",
            name: "Steam Games", isEnabled: true, source: .preset
        )
        // After dropping ".*", prefix is "com.valvesoftware.steam.app."
        XCTAssertTrue(app.matches(bundleID: "com.valvesoftware.steam.app."))
    }

    // MARK: - usesPrefixMatch

    func test_usesPrefixMatch_withWildcard_returnsTrue() {
        let app = MonitoredApp(
            id: UUID(), bundleID: "com.foo.*",
            name: "Foo", isEnabled: true, source: .preset
        )
        XCTAssertTrue(app.usesPrefixMatch)
    }

    func test_usesPrefixMatch_withoutWildcard_returnsFalse() {
        let app = MonitoredApp(
            id: UUID(), bundleID: "com.foo.bar",
            name: "Foo", isEnabled: true, source: .preset
        )
        XCTAssertFalse(app.usesPrefixMatch)
    }

    // MARK: - Codable

    func test_codableRoundTrip() throws {
        let original = MonitoredApp(
            id: UUID(), bundleID: "com.test.app",
            name: "Test App", isEnabled: true, source: .manual
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MonitoredApp.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.bundleID, original.bundleID)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.isEnabled, original.isEnabled)
        XCTAssertEqual(decoded.source, original.source)
    }

    // MARK: - Presets

    func test_presetsIntegrity() {
        let presets = MonitoredApp.presets
        XCTAssertEqual(presets.count, 8)

        // Unique UUIDs
        let ids = Set(presets.map { $0.id })
        XCTAssertEqual(ids.count, 8)

        // Unique bundle IDs
        let bundleIDs = Set(presets.map { $0.bundleID })
        XCTAssertEqual(bundleIDs.count, 8)

        // All preset source
        XCTAssertTrue(presets.allSatisfy { $0.source == .preset })

        // Steam Games uses prefix match
        let steam = presets.first { $0.name == "Steam Games" }
        XCTAssertNotNil(steam)
        XCTAssertTrue(steam!.usesPrefixMatch)

        // GeForce Now and Steam Games are enabled by default
        let enabledPresets = presets.filter { $0.isEnabled }
        XCTAssertEqual(enabledPresets.count, 2)
    }
}
