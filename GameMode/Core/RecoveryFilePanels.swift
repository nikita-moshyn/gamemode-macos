//
//  RecoveryFilePanels.swift
//  GameMode
//
//  Created by OpenAI Codex on 20/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum RecoveryFilePanels {
    static let fileType = UTType(exportedAs: "com.moshyn.nikita.GameMode.recovery", conformingTo: .data)
    private static var isPresenting = false

    static func save() async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Recovery"
        panel.message = "Saves your settings and a standalone recovery app beside the file."
        panel.nameFieldStringValue = "GameMode Settings.gamemoderecovery"
        panel.allowedContentTypes = [fileType]
        panel.canCreateDirectories = true
        let response = await present(panel)
        return response == .OK ? panel.url : nil
    }

    static func open() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Recover from File"
        panel.prompt = "Review Settings"
        panel.allowedContentTypes = [fileType]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let response = await present(panel)
        return response == .OK ? panel.url : nil
    }

    private static func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        guard !isPresenting else { return .cancel }
        isPresenting = true
        defer { isPresenting = false }
        let owner = NSApp.keyWindow ?? NSApp.mainWindow
        return await withCheckedContinuation { continuation in
            if let owner {
                panel.beginSheetModal(for: owner) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
    }
}
