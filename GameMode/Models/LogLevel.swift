//
//  LogLevel.swift
//  GameMode
//
//  Created by Nikita Moshyn on 23/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Foundation

enum LogLevel: String, Codable, CaseIterable, Comparable {
    case debug
    case info
    case warning
    case error

    var title: String {
        switch self {
        case .debug:   return "Debug"
        case .info:    return "Info"
        case .warning: return "Warning"
        case .error:   return "Error"
        }
    }

    private var sortIndex: Int {
        switch self {
        case .debug:   return 0
        case .info:    return 1
        case .warning: return 2
        case .error:   return 3
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.sortIndex < rhs.sortIndex
    }
}
