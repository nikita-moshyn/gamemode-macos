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

    private var navigationPath: Binding<[SettingsDestination]> {
        Binding(get: {
            store.navigationDestination.map { [$0] } ?? []
        }, set: { path in
            guard path.last != store.navigationDestination else { return }
            switch path.last {
            case .recovery where selectedSection == .system:
                store.send(.recoveryPageOpened)
            case .addApplications where selectedSection == .applications:
                store.send(.addAppButtonTapped)
            default:
                store.send(.navigationBackRequested)
            }
        })
    }

    var body: some View {
        NavigationStack(path: navigationPath) {
            detailView(for: selectedSection)
                .disabled(selectedSection != .system && (store.configurationLoadError != nil || store.runtime.recoveryRequired || store.runtime.isTransitioning))
                .safeAreaInset(edge: .top, spacing: 0) { statusBanner }
                .navigationDestination(for: SettingsDestination.self) { destination in
                    Group {
                        switch destination {
                        case .recovery:
                            RecoverySettingsView(store: store)
                        case .addApplications:
                            if let pickerStore = store.scope(state: \.appPicker, action: \.appPicker.presented) {
                                AppPickerView(store: pickerStore)
                            }
                        }
                    }
                    .navigationBarBackButtonHidden()
                }
        }
        .id(selectedSection)
        .disclosureGroupStyle(SettingsDisclosureGroupStyle())
        .task { await store.send(.settingsOpened).finish() }
        .alert("Use current settings as normal?", isPresented: confirmationBinding(.acceptCurrentSettings)) {
            Button("Cancel", role: .cancel) {}
            Button("Use Current Settings", role: .destructive) {
                guard store.canAcceptCurrentSettings else { return }
                store.send(.confirmationDismissed(.acceptCurrentSettings))
                store.send(.acceptCurrentSettings)
            }
        } message: {
            Text("First set your preferred normal keyboard, mouse, and system settings in macOS. This accepts the current settings as your normal configuration and ends recovery. The previous saved values will no longer be used for automatic recovery.")
        }
        .alert("Reset saved configuration?", isPresented: confirmationBinding(.resetConfiguration)) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Configuration", role: .destructive) {
                guard store.canResetConfiguration else { return }
                store.send(.confirmationDismissed(.resetConfiguration))
                store.send(.resetConfiguration)
            }
        } message: {
            Text("This resets monitored applications, shortcuts, presets, and other GameMode preferences. Your current macOS settings will not be changed.")
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
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

    private func confirmationBinding(_ confirmation: AppSettings.Confirmation) -> Binding<Bool> {
        Binding(get: { store.confirmation == confirmation }, set: { if !$0 { store.send(.confirmationDismissed(confirmation)) } })
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

/// Only the header is a button; revealed settings keep their own interactions.
struct SettingsDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .default) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? (layoutDirection == .rightToLeft ? -90 : 90) : 0))
                        .accessibilityHidden(true)
                    configuration.label
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                VStack(alignment: .leading, spacing: 10) { configuration.content }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .padding(-10)
    }
}
