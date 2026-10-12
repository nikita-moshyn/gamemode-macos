//
//  SettingsWindow.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import Combine
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
    @State private var selection: SettingsSection?

    private var selectedSection: SettingsSection {
        selection ?? SettingsSection.resolve(selectedSectionID) ?? .general
    }

    private var sidebarSelection: Binding<SettingsSection?> {
        Binding(get: { selection }, set: { section in
            if let section { selectSection(section) }
        })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
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
                            Button("Review") { selectSection(.system) }
                        }
                        .padding()
                        .background(.background)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 500)
        .onAppear {
            if selection == nil { selectSection(selectedSection) }
        }
        // Consume requests after @Published finishes assigning them. This event
        // stream also avoids onChange/task(id:)'s per-frame guard when clearing
        // one request and receiving the next in quick succession.
        .onReceive(configStore.$requestedSettingsSection.compactMap { $0 }.receive(on: RunLoop.main)) { requested in
            selectRequestedSection(requested)
        }
    }

    private func selectSection(_ section: SettingsSection) {
        guard selection != section else { return }
        selection = section
        selectedSectionID = section.rawValue
        // Refresh as part of navigation, even if SwiftUI retains the detail view
        // or coalesces several selection changes into one rendering frame.
        if section == .shortcuts { configStore.refreshDetectedShortcuts() }
    }

    private func selectRequestedSection(_ requested: String) {
        guard configStore.requestedSettingsSection == requested else { return }
        if let section = SettingsSection.resolve(requested) {
            selectSection(section)
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
