//
//  SettingsWindow.swift
//  GameMode
//
//  Created by Nikita Moshyn on 10/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    // Retain persisted identifiers while presenting the new names and order.
    case general, shortcuts, mouse, display, applications, hotkeys, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Input Guard"
        case .hotkeys: return "Hotkeys"
        case .applications: return "Auto-Activation"
        case .mouse: return "Mouse"
        case .display: return "Displays"
        case .system: return "System"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "hand.raised"
        case .hotkeys: return "command.square"
        case .applications: return "app.dashed"
        case .mouse: return "computermouse"
        case .display: return "display"
        case .system: return "wrench.and.screwdriver"
        }
    }

    static func resolve(_ identifier: String) -> SettingsSection? {
        identifier == "logs" ? .system : SettingsSection(rawValue: identifier)
    }
}

struct SettingsWindow: View {
    @ObservedObject var configStore: ConfigStore
    var onApplyConfiguredMouseSpeed: (() -> Void)?
    var onForceRestore: (() -> Void)?
    var onResetAllSavedData: (() -> Void)?
    var onHotkeysChanged: (() -> Void)?
    var onAcceptCurrentSettings: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    @AppStorage("GameModeSettingsSection") private var selectedSectionID = SettingsSection.general.rawValue

    private var selectedSection: SettingsSection {
        SettingsSection.resolve(selectedSectionID) ?? .general
    }

    private var selection: Binding<SettingsSection> {
        Binding(get: { selectedSection }, set: { selectedSectionID = $0.rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(SettingsSection.allCases) { section in
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
                .disabled(selectedSection != .system && (configStore.configurationLoadError != nil || configStore.recoveryRequired || configStore.isTransitioning))
                .safeAreaInset(edge: .top, spacing: 0) {
                    if selectedSection != .system, let message = configStore.configurationLoadError ?? (configStore.recoveryRequired ? (configStore.recoveryMessage ?? "Recovery must finish before Game Mode can start.") : nil) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(message)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Review") { selectedSectionID = SettingsSection.system.rawValue }
                        }
                        .padding()
                        .background(.background)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 500)
        .onAppear {
            selectedSectionID = selectedSection.rawValue
            selectRequestedSection()
        }
        .onChange(of: configStore.requestedSettingsSection) { _, _ in selectRequestedSection() }
    }

    private func selectRequestedSection() {
        guard let requested = configStore.requestedSettingsSection else { return }
        if let section = SettingsSection.resolve(requested) {
            selectedSectionID = section.rawValue
        }
        configStore.requestedSettingsSection = nil
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(configStore: configStore, onCheckForUpdates: onCheckForUpdates)
        case .shortcuts:
            ShortcutsSettingsView(configStore: configStore)
        case .hotkeys:
            HotkeysSettingsView(configStore: configStore, onHotkeysChanged: onHotkeysChanged)
        case .applications:
            AppsSettingsView(configStore: configStore)
        case .mouse:
            MouseSettingsView(configStore: configStore, onApplyConfiguredMouseSpeed: onApplyConfiguredMouseSpeed)
        case .display:
            DisplaySettingsView(configStore: configStore)
        case .system:
            SystemSettingsView(configStore: configStore, onForceRestore: onForceRestore, onResetAllSavedData: onResetAllSavedData, onAcceptCurrentSettings: onAcceptCurrentSettings)
        }
    }
}
