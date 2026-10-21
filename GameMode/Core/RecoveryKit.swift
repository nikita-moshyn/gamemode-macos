//
//  RecoveryKit.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Darwin
import Foundation

enum RecoveryKit {
    struct Metadata: Codable {
        var version = 1
        var createdAt: Date
        var machine: String
        var uid: UInt32
        var supportPath: String
        var pendingAtExport: Bool
    }

    static var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/GameModeRecovery") }
    static var automaticURL: URL { RecoveryAgentFiles.live.directory.appendingPathComponent("Recovery Kit") }

    static var standaloneAppURL: URL {
        if Bundle.main.bundleIdentifier == "com.moshyn.nikita.GameMode.RecoveryTool" { return Bundle.main.bundleURL }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GameMode Recovery.app")
    }

    static func exportBackup(_ backup: RecoveryBackup, to file: URL, application: URL = standaloneAppURL) throws {
        try backup.validate()
        try copyApplication(from: application, to: file.deletingLastPathComponent())
        try backup.write(to: file)
    }

    private static func copyApplication(from source: URL, to directory: URL) throws {
        let manager = FileManager.default
        let identifier = "com.moshyn.nikita.GameMode.RecoveryTool"
        guard Bundle(url: source)?.bundleIdentifier == identifier else { throw JournalError.invalid("The recovery app is missing. Reinstall GameMode and export again.") }
        let destination = directory.appendingPathComponent("GameMode Recovery.app")
        if source.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL { return }
        if manager.fileExists(atPath: destination.path) {
            guard Bundle(url: destination)?.bundleIdentifier == identifier else { throw JournalError.invalid("This folder already contains a different app named GameMode Recovery. Choose another folder.") }
            // Do not replace a running copy or rewrite an unchanged signed bundle.
            let signature = "Contents/_CodeSignature/CodeResources"
            if let existing = try? Data(contentsOf: destination.appendingPathComponent(signature)),
               existing == (try? Data(contentsOf: source.appendingPathComponent(signature))),
               let executable = Bundle(url: source)?.executableURL, let existingExecutable = Bundle(url: destination)?.executableURL,
               (try? Data(contentsOf: executable)) == (try? Data(contentsOf: existingExecutable)) { return }
        }
        let staging = directory.appendingPathComponent(".GameMode-Recovery-\(UUID().uuidString).app")
        let previous = directory.appendingPathComponent(".GameMode-Recovery-previous-\(UUID().uuidString).app")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        let replacing = manager.fileExists(atPath: destination.path)
        if replacing { try manager.moveItem(at: destination, to: previous) }
        do { try manager.moveItem(at: staging, to: destination) }
        catch {
            if replacing { try? manager.moveItem(at: previous, to: destination) }
            throw error
        }
        if replacing { try? manager.removeItem(at: previous) }
    }

    static func export(to directory: URL, journal: StateJournal, helper: URL = helperURL, support: URL = RecoveryAgentFiles.live.support) throws {
        guard let machine = RecoveryIdentity.machine else { throw JournalError.invalid("This Mac could not be identified for the recovery kit.") }
        switch journal.inspect() { case .invalid(let reason): throw JournalError.invalid(reason); default: break }
        let state = try journal.load()
        let evidence = try journal.recoveryEvidence()
        let executable = try Data(contentsOf: helper)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if manager.fileExists(atPath: standaloneAppURL.path) { try copyApplication(from: standaloneAppURL, to: directory) }
        let tool = directory.appendingPathComponent("GameModeRecovery")
        if (try? Data(contentsOf: tool)) != executable {
            try executable.write(to: tool, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: directory.appendingPathComponent("pending-at-export.json"), options: .atomic)
        try encoder.encode(evidence).write(to: directory.appendingPathComponent("originals-and-changes.json"), options: .atomic)
        let metadata = Metadata(createdAt: Date(), machine: machine, uid: getuid(), supportPath: support.path, pendingAtExport: state.isActive)
        try encoder.encode(metadata).write(to: directory.appendingPathComponent("kit.json"), options: .atomic)
        let command = """
        #!/bin/zsh
        set -e
        kit_directory="${0:A:h}"
        "$kit_directory/GameModeRecovery" --restore --kit "$kit_directory"
        echo ""
        read '?Press Return to close.'
        """ + "\n"
        let launcher = directory.appendingPathComponent("Restore.command")
        try Data(command.utf8).write(to: launcher, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let instructions = """
        GameMode Recovery Kit

        This folder works without GameMode.app installed. Keep it on this Mac.
        Quit GameMode, then double-click Restore.command. The standalone executable
        uses the latest recovery record in:
        \(journal.directory.path)

        It acquires GameMode's process lock, restores only pending changes, verifies
        the result, and honors newer saved function-key preferences. It does not
        replace the normal macOS function-key preference with a gaming preference.
        Low Power Mode recovery may ask for the macOS administrator authorization
        already required to change that setting. The background helper never asks.

        originals-and-changes.json lists recorded originals and changes.
        pending-at-export.json is an audit snapshot. These exports are NOT authority
        to replay an old session after it has already completed. The latest live
        recovery record always wins. If that record is missing or damaged, the tool
        stops rather than guessing from an older export. Preserve this folder and
        the Application Support recovery directory when deleting the app.

        To inspect without changing anything, run GameModeRecovery --inspect.
        Normal keyboard behavior is also available in macOS System Settings >
        Keyboard > Keyboard Shortcuts > Function Keys.
        """ + "\n"
        try Data(instructions.utf8).write(to: directory.appendingPathComponent("Recovery instructions.txt"), options: .atomic)
    }

    static func validate(at directory: URL, support: URL = RecoveryAgentFiles.live.support) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(Metadata.self, from: Data(contentsOf: directory.appendingPathComponent("kit.json")))
        guard metadata.version == 1, metadata.machine == RecoveryIdentity.machine, metadata.uid == getuid(), metadata.supportPath == support.path else {
            throw JournalError.invalid("This recovery kit belongs to a different Mac, user, or recovery directory.")
        }
        if metadata.pendingAtExport, StateJournal(directory: support.appendingPathComponent("GameMode")).inspect() == .missing {
            throw JournalError.invalid("The current recovery record is missing. The exported audit snapshot cannot safely prove which changes are still pending.")
        }
    }
}
