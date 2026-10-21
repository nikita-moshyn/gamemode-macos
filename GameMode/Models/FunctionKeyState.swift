//
//  FunctionKeyState.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Darwin
import Foundation
import IOKit

enum FunctionKeyBehavior: String, Codable, CaseIterable, Sendable {
    case unchanged, standard, media

    var title: String {
        switch self {
        case .unchanged: return "Keep normal behavior"
        case .standard: return "Standard F1–F12"
        case .media: return "Brightness and volume"
        }
    }

    var target: Bool? {
        switch self { case .unchanged: return nil; case .standard: return true; case .media: return false }
    }
}

struct FunctionKeyPreferences: Codable, Equatable, Sendable {
    var global: Bool?
    var host: Bool?
    var isManaged = false
    var effective: Bool? { host ?? global }
    var hasLegacyConflict: Bool { !isManaged && global == false && host == true }

    static func read() throws -> Self {
        let key = "com.apple.keyboard.fnState" as CFString
        func value(_ host: CFString) throws -> Bool? {
            guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host) else {
                throw RecoveryController.Failure.message("Function-key preferences could not be refreshed. Retry Recovery.")
            }
            guard let value = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host) else { return nil }
            guard let number = value as? NSNumber, number == NSNumber(value: 0) || number == NSNumber(value: 1) else {
                throw RecoveryController.Failure.message("The saved function-key preference is invalid. No preference was changed.")
            }
            return number.boolValue
        }
        return try Self(global: value(kCFPreferencesAnyHost), host: value(kCFPreferencesCurrentHost),
                        isManaged: CFPreferencesAppValueIsForced(key, kCFPreferencesCurrentApplication))
    }
}

struct FunctionKeyRecoveryContext: Codable, Equatable, Sendable {
    var preferences: FunctionKeyPreferences
    var appliedMode: Bool
    var bootSession: String

    /// A newer saved preference or a reboot takes precedence over the old live baseline.
    /// A different live value belongs to another actor; do not fight it.
    func restorationTarget(original: Bool, current: Bool, preferences now: FunctionKeyPreferences, bootSession currentBoot: String) -> Bool? {
        guard !now.isManaged else { return nil }
        // macOS has already reloaded normal preferences after a reboot. Never
        // replay an old live mode over this boot's keyboard activity.
        guard currentBoot == bootSession else { return nil }
        if now != preferences { return now.effective }
        guard current == appliedMode else { return nil }
        return original
    }
}

struct FunctionKeyOverrideRemoval: Codable, Equatable, Sendable {
    var expected: FunctionKeyPreferences
}

enum RecoveryIdentity {
    static var bootSession: String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }

    static var machine: String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
}
