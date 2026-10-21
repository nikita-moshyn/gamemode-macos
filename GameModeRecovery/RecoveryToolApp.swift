//
//  RecoveryToolApp.swift
//  GameMode
//
//  Created by OpenAI Codex on 20/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import SwiftUI

@main
struct RecoveryToolApp: App {
    @StateObject private var model = RecoveryToolModel()

    var body: some Scene {
        Window("Recovery", id: "recovery") {
            RecoveryContentView(
                backup: model.imported ?? model.backup,
                fileName: model.fileName,
                selection: model.selection,
                isBusy: model.isBusy,
                canRestore: model.imported != nil || model.hasPendingChanges,
                status: model.hasPendingChanges ? "Some settings still need recovery." : "Your settings are ready to export.",
                message: model.message,
                error: model.error,
                restore: { model.restore() },
                export: { Task { await model.export() } },
                open: { Task { await model.open() } },
                cancelImport: { model.cancelImport() },
                select: { setting, selected in
                    if selected { model.selection.insert(setting) } else { model.selection.remove(setting) }
                }
            )
            .frame(minWidth: 480, minHeight: 520)
            .task { await model.start() }
            .onOpenURL { model.review($0) }
        }
        .defaultSize(width: 540, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Recover from File…") { Task { await model.open() } }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
                Button("Export…") { Task { await model.export() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.backup == nil || model.imported != nil)
            }
        }
    }
}

@MainActor
final class RecoveryToolModel: ObservableObject {
    @Published var backup: RecoveryBackup?
    @Published var imported: RecoveryBackup?
    @Published var fileName: String?
    @Published var selection: Set<RecoveryBackup.Setting> = []
    @Published var isBusy = false
    @Published var hasPendingChanges = false
    @Published var message: String?
    @Published var error: String?
    private var started = false
    private var pendingFile: URL?

    func start() async {
        guard !started else { return }
        started = true
        await refresh()
        guard imported == nil else { return }
        // Export keeps the signed app intact and places its data beside it.
        let directory = Bundle.main.bundleURL.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let backups = files.filter { $0.pathExtension == "gamemoderecovery" }
        if backups.count == 1 { review(backups[0]) }
    }

    private func refresh() async {
        isBusy = true
        defer {
            isBusy = false
            if let pendingFile {
                self.pendingFile = nil
                review(pendingFile)
            }
        }
        do {
            let state = try await Task.detached(priority: .userInitiated) {
                let journal = StateJournal.shared
                let controller = RecoveryController.system(journal: journal)
                let state = try journal.load()
                return (try controller.backup(), state.isActive || state.appliedChanges.hasPendingChanges)
            }.value
            backup = state.0
            hasPendingChanges = state.1
        } catch { self.error = error.localizedDescription }
    }

    func open() async {
        guard !isBusy, let file = await RecoveryFilePanels.open() else { return }
        review(file)
    }

    func review(_ file: URL) {
        guard !isBusy else { pendingFile = file; return }
        do {
            let document = try RecoveryBackup.read(from: file)
            imported = document
            fileName = file.lastPathComponent
            selection = document.settings
            error = nil
            message = nil
        } catch { self.error = "This file could not be opened. " + error.localizedDescription }
    }

    func cancelImport() {
        guard !isBusy else { return }
        imported = nil
        fileName = nil
        selection = []
        error = nil
    }

    func export() async {
        guard !isBusy, imported == nil, let backup, let destination = await RecoveryFilePanels.save() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await Task.detached(priority: .userInitiated) { try RecoveryKit.exportBackup(backup, to: destination) }.value
            error = nil
            message = "Recovery file and standalone app exported."
        } catch { self.error = error.localizedDescription }
    }

    func restore() {
        guard !isBusy, imported != nil || hasPendingChanges, imported == nil || !selection.isEmpty else { return }
        let imported = self.imported
        let selected = selection
        let anotherApp = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.moshyn.nikita.GameMode").isEmpty
        isBusy = true
        error = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let owner = ApplicationInstanceLock()
                    try owner.acquire(otherInstanceRunning: anotherApp, timeout: 2)
                    try withExtendedLifetime(owner) {
                        let controller = RecoveryController.system(journal: .shared, interactive: true)
                        if let imported { try controller.restoreBackup(imported, settings: selected) }
                        else { try controller.recover(repairLegacyOverride: RecoveryController.savedLegacyRepairPolicy(for: .shared)) }
                    }
                }.value
                self.imported = nil
                fileName = nil
                selection = []
                message = "Settings restored."
            } catch ApplicationInstanceLock.Failure.alreadyRunning {
                error = "Quit GameMode and any other recovery window, then try again."
            } catch { self.error = error.localizedDescription }
            await refresh()
        }
    }
}
