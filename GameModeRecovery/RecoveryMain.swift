//
//  RecoveryMain.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import Foundation

@main
enum RecoveryMain {
    static func main() {
        do { try run() }
        catch { fputs("GameMode recovery: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    private static func run() throws {
        let args = CommandLine.arguments
        try validateArguments(args)
        var files = RecoveryAgentFiles.live
        var settings = SettingsManager()
        #if DEBUG
        if let index = args.firstIndex(of: "--fixture-root"), args.indices.contains(index + 1) {
            files = .init(support: URL(fileURLWithPath: args[index + 1]))
            settings = SettingsManager(functionKeys: RecoveryFixture.access(at: files.support.appendingPathComponent("keyboard.json")))
            if args.contains("--fixture-owner") { try RecoveryFixture.ownSession(files: files, settings: settings); return }
        }
        #endif
        let journal = StateJournal(directory: files.support.appendingPathComponent("GameMode"))
        if args.contains("--watch") {
            let agentLock = ApplicationInstanceLock(directory: files.support, filename: "GameMode.recovery-agent.lock")
            try agentLock.acquire()
            defer { withExtendedLifetime(agentLock) {} }
            let worker = controller(files: files, journal: journal, settings: settings)
            var lastError: String?
            var nextAttempt = Date.distantPast
            let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
                do {
                    try files.acknowledge()
                    guard Date() >= nextAttempt else { return }
                    switch journal.inspect() {
                    case .missing, .clean: return
                    case .pending, .invalid: break
                    }
                    let ownerLock = ApplicationInstanceLock(directory: files.support)
                    do { try ownerLock.acquire(otherInstanceRunning: hasRunningApp(fixture: files.support != RecoveryAgentFiles.live.support)) }
                    catch ApplicationInstanceLock.Failure.alreadyRunning { return }
                    defer { withExtendedLifetime(ownerLock) {} }
                    try worker.recover(repairLegacyOverride: RecoveryController.savedLegacyRepairPolicy(for: journal))
                    try files.write(RecoveryAgentFiles.Result(date: Date(), succeeded: true, message: "Interrupted session restored and verified by the independent helper."), to: files.resultURL)
                    lastError = nil
                } catch {
                    nextAttempt = Date().addingTimeInterval(5)
                    if error.localizedDescription != lastError {
                        lastError = error.localizedDescription
                        try? files.write(RecoveryAgentFiles.Result(date: Date(), succeeded: false, message: error.localizedDescription), to: files.resultURL)
                        Log.error(error.localizedDescription)
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            try files.acknowledge()
            RunLoop.main.run()
            return
        }
        if let index = args.firstIndex(of: "--export-kit"), args.indices.contains(index + 1) {
            try RecoveryKit.export(to: URL(fileURLWithPath: args[index + 1]), journal: journal,
                                   helper: URL(fileURLWithPath: args[0]), support: files.support)
            print("Recovery kit exported.")
            return
        }
        if let index = args.firstIndex(of: "--kit"), args.indices.contains(index + 1) {
            try RecoveryKit.validate(at: URL(fileURLWithPath: args[index + 1]), support: files.support)
        }
        if args.contains("--inspect") {
            print("Recovery journal: \(journal.manifestURL.path)")
            switch journal.inspect() {
            case .missing, .clean: print("No pending recovery. Archived exports are never replayed automatically.")
            case .pending(let state): print(String(data: try JSONEncoder().encode(state), encoding: .utf8)!)
            case .invalid(let reason): throw JournalError.invalid(reason)
            }
            return
        }
        guard args.contains("--restore") else {
            print("GameModeRecovery --inspect | --restore [--kit <export folder>]")
            return
        }
        let ownerLock = ApplicationInstanceLock(directory: files.support)
        try ownerLock.acquire(otherInstanceRunning: hasRunningApp(fixture: files.support != RecoveryAgentFiles.live.support))
        defer { withExtendedLifetime(ownerLock) {} }
        try controller(files: files, journal: journal, settings: settings, interactive: true)
            .recover(repairLegacyOverride: RecoveryController.savedLegacyRepairPolicy(for: journal))
        print("Recovery complete. Pending settings were restored and verified; newer keyboard preferences were preserved.")
    }

    private static func controller(files: RecoveryAgentFiles, journal: StateJournal, settings: SettingsManager, interactive: Bool = false) -> RecoveryController {
        #if DEBUG
        if files.support != RecoveryAgentFiles.live.support { return RecoveryFixture.controller(files: files, settings: settings, journal: journal) }
        #endif
        return RecoveryController.system(journal: journal, settings: settings, interactive: interactive)
    }

    private static func validateArguments(_ args: [String]) throws {
        var commands: Set<String> = ["--watch", "--inspect", "--restore", "--export-kit"]
        var valued: Set<String> = ["--kit", "--export-kit"]
        #if DEBUG
        commands.insert("--fixture-owner")
        valued.insert("--fixture-root")
        #endif
        var index = 1
        var commandCount = 0
        while index < args.count {
            let argument = args[index]
            guard commands.contains(argument) || valued.contains(argument) else {
                throw RecoveryController.Failure.message("Unknown recovery option: \(argument). No settings were changed.")
            }
            if commands.contains(argument) { commandCount += 1 }
            if valued.contains(argument) {
                guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else {
                    throw RecoveryController.Failure.message("\(argument) needs a folder path")
                }
                index += 1
            }
            index += 1
        }
        guard commandCount <= 1 else { throw RecoveryController.Failure.message("Choose one recovery command at a time") }
    }

    private static func hasRunningApp(fixture: Bool) -> Bool {
        guard !fixture else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.moshyn.nikita.GameMode")
            .contains { !$0.isTerminated && $0.processIdentifier != getpid() && $0.executableURL?.lastPathComponent == "GameMode" }
    }
}
