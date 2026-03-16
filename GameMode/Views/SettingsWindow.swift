//
//  SettingsWindow.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case hotkeys
    case applications
    case mouse
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .shortcuts:    return "Shortcuts"
        case .hotkeys:      return "Hotkeys"
        case .applications: return "Applications"
        case .mouse:        return "Mouse"
        case .system:       return "System"
        }
    }

    var icon: String {
        switch self {
        case .general:      return "gearshape"
        case .shortcuts:    return "keyboard"
        case .hotkeys:      return "command.square"
        case .applications: return "app.dashed"
        case .mouse:        return "computermouse"
        case .system:       return "wrench.and.screwdriver"
        }
    }
}

struct SettingsWindow: View {
    @ObservedObject var configStore: ConfigStore
    var onForceRestore: (() -> Void)?
    var onHotkeysChanged: (() -> Void)?

    @State private var selectedSection: SettingsSection = .general

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }

                Section {
                    Text("v\(appVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detailView(for: selectedSection)
        }
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(configStore: configStore)
        case .shortcuts:
            ShortcutsSettingsView(configStore: configStore)
        case .hotkeys:
            HotkeysSettingsView(configStore: configStore, onHotkeysChanged: onHotkeysChanged)
        case .applications:
            AppsSettingsView(configStore: configStore)
        case .mouse:
            MouseSettingsView(configStore: configStore)
        case .system:
            SystemSettingsView(configStore: configStore, onForceRestore: onForceRestore)
        }
    }
}
