//
//  RecoverySettingsSection.swift
//  GameMode
//
//  Created by OpenAI Codex on 19/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import SwiftUI

struct RecoverySettingsSection: View {
    @Bindable var store: StoreOf<AppSettings>

    var body: some View {
        Section {
            LabeledContent("Crash Recovery", value: store.runtime.recoveryRequired ? "Needs Attention" : store.recoveryStatus.protection.rawValue)
            if store.recoveryStatus.protection != .ready {
                if store.recoveryStatus.protection == .approval {
                    Button("Allow in System Settings…") { store.send(.openRecoverySettings) }
                } else {
                    Button("Enable Crash Recovery") { store.send(.retryRecovery) }
                        .disabled(store.runtime.isTransitioning)
                }
            }
            NavigationLink("Recovery", value: SettingsDestination.recovery)
                .disabled(store.runtime.isTransitioning)
        } header: {
            Text("Recovery")
        } footer: {
            Text("Automatically restores settings changed by GameMode if the app closes unexpectedly.")
        }
        .task {
            while !Task.isCancelled {
                await store.send(.recoveryStatusRequested).finish()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
}
