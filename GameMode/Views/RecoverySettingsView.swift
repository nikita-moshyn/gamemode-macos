//
//  RecoverySettingsView.swift
//  GameMode
//
//  Created by OpenAI Codex on 20/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import SwiftUI

struct RecoverySettingsView: View {
    @Bindable var store: StoreOf<AppSettings>

    var body: some View {
        VStack(spacing: 0) {
            RecoveryContentView(
                backup: store.importedRecovery ?? store.recoveryDocument,
                fileName: store.importedRecoveryName,
                selection: store.selectedRecoverySettings,
                isBusy: store.runtime.isTransitioning,
                canRestore: store.importedRecovery != nil || store.runtime.isGamingMode || store.runtime.recoveryRequired,
                status: store.runtime.recoveryRequired ? "Some settings still need recovery." : "GameMode restores changes automatically after a crash.",
                message: store.recoveryNotice,
                error: store.recoveryToolError ?? (store.runtime.recoveryRequired ? store.runtime.recoveryMessage : nil),
                restore: { store.send(store.importedRecovery == nil ? .retryRecovery : .restoreRecoveryFile) },
                export: { store.send(.exportRecoveryKit) },
                open: { store.send(.importRecoveryFile) },
                cancelImport: { store.send(.discardRecoveryFile) },
                select: { store.send(.recoverySettingSelected($0, $1)) }
            )
            if store.runtime.recoveryRequired {
                Button("Keep Current Settings…") { store.send(.confirmationRequested(.acceptCurrentSettings)) }
                    .disabled(store.runtime.isTransitioning)
                    .padding(.bottom, 16)
            }
        }
    }
}
