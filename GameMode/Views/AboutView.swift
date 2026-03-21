//
//  AboutView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 16/03/2026.
//  Copyright © 2025 Nikita Moshyn. All rights reserved.
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
        VStack(spacing: 16) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("GameMode")
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Copyright © 2025 Nikita Moshyn.\nAll rights reserved.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Divider()
                .frame(width: 200)

            Text("Released under the MIT License")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link("GitHub Repository", destination: URL(string: "https://github.com/user/GameMode")!)
                .font(.caption)

            Spacer()
        }
        .frame(width: 300, height: 340)
    }
}
