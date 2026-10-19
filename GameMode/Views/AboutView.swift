//
//  AboutView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 11/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import SwiftUI

struct AboutView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
                .padding(.bottom, 10)

            Text("GameMode")
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 6)

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            Text("GameMode prepares your Mac for gaming by blocking accidental shortcuts, applying your mouse preset, and restoring your everyday settings when you’re done.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)

            Text("© 2026 Nikita Moshyn")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            Link("GitHub Repository", destination: URL(string: "https://github.com/nikita-moshyn/gamemode-macos")!)
                .font(.system(size: 11))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: 300)
    }
}
