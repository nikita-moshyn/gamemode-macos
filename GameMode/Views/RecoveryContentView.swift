//
//  RecoveryContentView.swift
//  GameMode
//
//  Created by OpenAI Codex on 20/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

/// The same recovery screen is used in GameMode and the standalone recovery app.
struct RecoveryContentView: View {
    var backup: RecoveryBackup?
    var fileName: String?
    var selection: Set<RecoveryBackup.Setting>
    var isBusy: Bool
    var canRestore: Bool
    var status: String
    var message: String?
    var error: String?
    var restore: () -> Void
    var export: () -> Void
    var open: () -> Void
    var cancelImport: () -> Void
    var select: (RecoveryBackup.Setting, Bool) -> Void

    var body: some View {
        Form {
            Section {
                if isBusy {
                    ProgressView("Working…")
                        .controlSize(.small)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if fileName == nil || message != nil {
                    Label(message ?? status, systemImage: "checkmark.shield")
                }
                if let fileName, let backup {
                    LabeledContent("Recovery File", value: fileName)
                    LabeledContent("Saved", value: backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("Review the settings below, then choose Restore Selected Settings. Newer keyboard preferences will be kept.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Saved Settings") {
                if let backup, !backup.rows.isEmpty {
                    ForEach(backup.rows) { row in
                        if fileName != nil {
                            HStack {
                                Toggle(row.id.title, isOn: Binding(get: { selection.contains(row.id) }, set: { select(row.id, $0) }))
                                    .toggleStyle(.checkbox)
                                    .accessibilityHint("Saved value: \(row.value)")
                                Spacer(minLength: 16)
                                Text(row.value)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                            .disabled(isBusy)
                        } else {
                            LabeledContent(row.id.title, value: row.value)
                        }
                    }
                } else if !isBusy {
                    Text("Choose a recovery file to review its saved settings.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button(fileName == nil ? "Restore Settings" : "Restore Selected Settings", action: restore)
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || !canRestore || (fileName != nil && selection.isEmpty))
                if fileName != nil { Button("Cancel File Recovery", action: cancelImport).disabled(isBusy) }
                if fileName == nil {
                    Button("Export…", action: export)
                        .disabled(isBusy || backup?.rows.isEmpty != false)
                }
                Button("Recover from File…", action: open)
                    .disabled(isBusy)
            } footer: {
                if fileName == nil {
                    Text("Export includes a recovery app you can open even if GameMode is no longer installed.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
