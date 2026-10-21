//
//  GameModeApp.swift
//  GameMode
//
//  Created by Nikita Moshyn on 10/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

@main
struct GameModeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            SidebarCommands()
            CommandGroup(before: .sidebar) {
                Button("Back") { appDelegate.navigateSettingsBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!appDelegate.canNavigateSettingsBack)
                Button("Forward") { appDelegate.navigateSettingsForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!appDelegate.canNavigateSettingsForward)
                Divider()
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About GameMode") { appDelegate.openAbout() }
            }
        }
    }
}
