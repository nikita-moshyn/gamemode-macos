//
//  ApplicationInstanceLock.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Darwin
import Foundation

/// All copies share one recovery journal and must hold this lock for their
/// entire live lifecycle. The kernel releases it even after a crash.
final class ApplicationInstanceLock {
    enum Failure: LocalizedError, Equatable {
        case alreadyRunning
        case unavailable(Int32)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "GameMode or its recovery tool is already using the saved settings. Let recovery finish, or quit the other copy before opening this one."
            case .unavailable:
                return "GameMode could not protect its recovery files from another running copy. No system settings were changed."
            }
        }
    }

    private let directory: URL
    private let filename: String
    private var descriptor: Int32 = -1
    var isAcquired: Bool { descriptor >= 0 }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], filename: String = "GameMode.instance.lock") {
        self.directory = directory
        self.filename = filename
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        // Never unlink the file: a new inode would let two copies hold a lock.
    }

    func acquire(otherInstanceRunning: Bool = false, timeout: TimeInterval = 0) throws {
        guard !isAcquired else { return }
        // Older releases do not take the lock, so also check NSWorkspace at launch.
        guard !otherInstanceRunning else { throw Failure.alreadyRunning }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Keep the lock outside the journal directory so resetting recovery cannot
        // replace its inode or bypass the journal's durable directory creation.
        let candidate = Darwin.open(directory.appendingPathComponent(filename).path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard candidate >= 0 else { throw Failure.unavailable(errno) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(candidate, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            if failure == EWOULDBLOCK, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            Darwin.close(candidate)
            if failure == EWOULDBLOCK { throw Failure.alreadyRunning }
            throw Failure.unavailable(failure)
        }
        descriptor = candidate
    }
}
