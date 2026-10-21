//
//  ApplicationInstanceLockTests.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import XCTest
@testable import GameMode

final class ApplicationInstanceLockTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOnlyOneCopyCanOwnRecoveryAndRejectedCopyCannotUnlockIt() throws {
        let owner = ApplicationInstanceLock(directory: directory)
        try owner.acquire()
        XCTAssertTrue(owner.isAcquired)
        for _ in 0..<2 {
            let contender = ApplicationInstanceLock(directory: directory)
            XCTAssertThrowsError(try contender.acquire()) {
                XCTAssertEqual($0 as? ApplicationInstanceLock.Failure, .alreadyRunning)
            }
            XCTAssertFalse(contender.isAcquired)
        }
        XCTAssertTrue(owner.isAcquired)
    }

    func testClosingOwnerAllowsRecoveryWithoutDeletingLockFile() throws {
        var owner: ApplicationInstanceLock? = ApplicationInstanceLock(directory: directory)
        try owner?.acquire()
        owner = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("GameMode.instance.lock").path))
        let nextLaunch = ApplicationInstanceLock(directory: directory)
        try nextLaunch.acquire()
        XCTAssertTrue(nextLaunch.isAcquired)
    }

    func testLeftoverFileAfterRestartDoesNotBlockLaunch() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("previous process".utf8).write(to: directory.appendingPathComponent("GameMode.instance.lock"))
        let nextLaunch = ApplicationInstanceLock(directory: directory)
        try nextLaunch.acquire()
        XCTAssertTrue(nextLaunch.isAcquired)
    }

    func testOlderRunningCopyBlocksLaunchBeforeCreatingRecoveryDirectory() {
        let subject = ApplicationInstanceLock(directory: directory)
        XCTAssertThrowsError(try subject.acquire(otherInstanceRunning: true)) {
            XCTAssertEqual($0 as? ApplicationInstanceLock.Failure, .alreadyRunning)
        }
        XCTAssertFalse(subject.isAcquired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUnavailableDirectoryCannotAllowUnprotectedLaunch() throws {
        try Data().write(to: directory)
        let subject = ApplicationInstanceLock(directory: directory)
        XCTAssertThrowsError(try subject.acquire())
        XCTAssertFalse(subject.isAcquired)
    }

    func testAcquiringTwiceKeepsTheOriginalLock() throws {
        let subject = ApplicationInstanceLock(directory: directory)
        try subject.acquire()
        try subject.acquire()
        let contender = ApplicationInstanceLock(directory: directory)
        XCTAssertThrowsError(try contender.acquire())
        XCTAssertTrue(subject.isAcquired)
    }

    func testResettingRecoveryCannotUnlockTheRunningCopy() throws {
        let owner = ApplicationInstanceLock(directory: directory)
        try owner.acquire()
        let journal = StateJournal(directory: directory.appendingPathComponent("GameMode"))
        try journal.begin(.init(isActive: true, activatedAt: nil, appliedChanges: .empty))
        try journal.complete()
        try journal.reset()
        XCTAssertEqual(journal.inspect(), .clean)
        let contender = ApplicationInstanceLock(directory: directory)
        XCTAssertThrowsError(try contender.acquire()) {
            XCTAssertEqual($0 as? ApplicationInstanceLock.Failure, .alreadyRunning)
        }
        XCTAssertTrue(owner.isAcquired)
    }
}
