//
//  SettingsWindow.swift
//  GameMode
//
//  Created by Nikita Moshyn on 15/03/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct SettingsWindow: View {
    @ObservedObject var configStore: ConfigStore
    var onForceRestore: (() -> Void)?
    var onHotkeysChanged: (() -> Void)?

    var body: some View {
        TabView {
            ShortcutsSettingsView(configStore: configStore)
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            HotkeysSettingsView(configStore: configStore, onHotkeysChanged: onHotkeysChanged)
                .tabItem {
                    Label("Hotkeys", systemImage: "command.square")
                }

            AppsSettingsView(configStore: configStore)
                .tabItem {
                    Label("Applications", systemImage: "app.dashed")
                }

            MouseSettingsView(configStore: configStore)
                .tabItem {
                    Label("Mouse", systemImage: "computermouse")
                }

            SystemSettingsView(configStore: configStore, onForceRestore: onForceRestore)
                .tabItem {
                    Label("System", systemImage: "gearshape.2")
                }
        }
        .frame(width: 540, height: 480)
    }
}
