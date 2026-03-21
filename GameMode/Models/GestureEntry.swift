//
//  GestureEntry.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

/// Represents a macOS trackpad or mouse gesture that can be disabled in gaming mode.
struct GestureEntry: Codable, Identifiable, Hashable {
    /// The preference key (e.g. "TrackpadThreeFingerVertSwipeGesture").
    let id: String
    /// Human-readable name.
    var name: String
    /// Grouping category ("Trackpad Gestures" or "Mouse Gestures").
    var category: String
    /// Preference domains to write to (e.g. both wired and Bluetooth trackpad domains).
    var domains: [String]
    /// When true, this gesture is disabled (set to 0) when gaming mode activates.
    var disableInGamingMode: Bool

    // MARK: - Defaults

    static let defaults: [GestureEntry] = trackpadGestures

    private static let trackpadDomains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    ]

    private static let trackpadGestures: [GestureEntry] = [
        GestureEntry(
            id: "TrackpadThreeFingerVertSwipeGesture",
            name: "Mission Control (3-finger swipe up)",
            category: "Trackpad Gestures",
            domains: trackpadDomains,
            disableInGamingMode: false
        ),
        GestureEntry(
            id: "TrackpadFourFingerVertSwipeGesture",
            name: "Mission Control (4-finger swipe up)",
            category: "Trackpad Gestures",
            domains: trackpadDomains,
            disableInGamingMode: false
        ),
        GestureEntry(
            id: "TrackpadThreeFingerHorizSwipeGesture",
            name: "Switch Spaces (3-finger swipe)",
            category: "Trackpad Gestures",
            domains: trackpadDomains,
            disableInGamingMode: false
        ),
        GestureEntry(
            id: "TrackpadFourFingerHorizSwipeGesture",
            name: "Switch Spaces (4-finger swipe)",
            category: "Trackpad Gestures",
            domains: trackpadDomains,
            disableInGamingMode: false
        ),
        GestureEntry(
            id: "TrackpadFourFingerPinchGesture",
            name: "Launchpad (4-finger pinch)",
            category: "Trackpad Gestures",
            domains: trackpadDomains,
            disableInGamingMode: false
        ),
        GestureEntry(
            id: "TrackpadThreeFingerTapGesture",
            name: "Look Up (3-finger tap)",
            category: "Trackpad Gestures",
            domains: trackpadDomains,
            disableInGamingMode: false
        ),
        GestureEntry(
            id: "TrackpadTwoFingerFromRightEdgeSwipeGesture",
            name: "Notification Center (2-finger edge swipe)",
            category: "Trackpad Gestures",
            domains: trackpadDomains,
            disableInGamingMode: false
        ),
    ]
}
