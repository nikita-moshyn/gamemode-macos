//
//  SettingsWindow.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import ComposableArchitecture
import SwiftUI

struct SettingsWindow: View {
    @Bindable var store: StoreOf<AppSettings>

    private var selectedSection: SettingsSection { store.selectedSection }

    private var sidebarSelection: Binding<SettingsSection?> {
        Binding(get: { store.selectedSection }, set: { store.send(.sectionSelected($0)) })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(SettingsSection.availableCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                        .padding(.vertical, 3)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 175, ideal: 195, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GameMode")
                        .fontWeight(.medium)
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        } detail: {
            detailView(for: selectedSection)
                .navigationTitle(selectedSection.title)
                .disabled(selectedSection != .system && (store.configurationLoadError != nil || store.runtime.recoveryRequired || store.runtime.isTransitioning))
                .safeAreaInset(edge: .top, spacing: 0) {
                    if selectedSection != .system, let message = store.configurationLoadError ?? (store.runtime.recoveryRequired ? (store.runtime.recoveryMessage ?? "Recovery must finish before Game Mode can start.") : nil) ?? store.persistenceError {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(message)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Review") { store.send(.sectionSelected(.system)) }
                        }
                        .padding()
                        .background(.background)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 500)
        .task { await store.send(.settingsOpened).finish() }
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(store: store)
        case .shortcuts:
            ShortcutsSettingsView(store: store)
        case .hotkeys:
            HotkeysSettingsView(store: store)
        case .applications:
            AppsSettingsView(store: store)
        case .mouse:
            MouseSettingsView(store: store)
        case .display:
            #if FEATURE_DISPLAYS
            DisplaySettingsView(store: store)
            #else
            GeneralSettingsView(store: store)
            #endif
        case .system:
            SystemSettingsView(store: store)
        }
    }
}
