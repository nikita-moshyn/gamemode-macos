//
//  SettingsWindowController.swift
//  GameMode
//
//  Created by OpenAI Codex on 20/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import Combine
import ComposableArchitecture
import SwiftUI

/// AppKit owns the divider and toolbar together, including their native animation.
@MainActor
final class SettingsWindowController: NSSplitViewController, NSToolbarDelegate {
    private let store: StoreOf<AppSettings>
    private let navigationID = NSToolbarItem.Identifier("settingsNavigation")
    private var navigationObservation: AnyCancellable?
    let navigationGroup = NSToolbarItemGroup(itemIdentifier: .init("settingsNavigation"))
    let backItem = NSToolbarItem(itemIdentifier: .init("settingsBack"))
    let forwardItem = NSToolbarItem(itemIdentifier: .init("settingsForward"))
    var navigationDidChange: (() -> Void)?
    var canNavigateBack: Bool { store.canNavigateBack }
    var canNavigateForward: Bool { store.canNavigateForward }

    private struct Navigation: Equatable {
        var title: String
        var canGoBack: Bool
        var canGoForward: Bool
    }

    init(store: StoreOf<AppSettings>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        backItem.label = "Back"
        backItem.toolTip = "Back"
        backItem.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
        backItem.target = self
        backItem.action = #selector(goBack(_:))
        backItem.autovalidates = false
        forwardItem.label = "Forward"
        forwardItem.toolTip = "Forward"
        forwardItem.image = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Forward")
        forwardItem.target = self
        forwardItem.action = #selector(goForward(_:))
        forwardItem.autovalidates = false
        navigationGroup.label = "Back and Forward"
        navigationGroup.isNavigational = true
        navigationGroup.subitems = [backItem, forwardItem]
        navigationObservation = store.publisher
            .map { Navigation(title: $0.navigationTitle, canGoBack: $0.canNavigateBack, canGoForward: $0.canNavigateForward) }
            .removeDuplicates()
            .sink { [weak self] navigation in self?.updateNavigation(navigation) }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let sidebar = NSHostingController(rootView: SettingsSidebar(store: store))
        let detail = SettingsDetailController(store: store)
        // The native toolbar is persistent; SwiftUI only presents the pane content.
        sidebar.sceneBridgingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 240
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 480
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: self)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.title = store.navigationTitle
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 600))
        window.contentMinSize = NSSize(width: 720, height: 500)
        let toolbar = NSToolbar(identifier: "GameModeSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        splitView.setPosition(190, ofDividerAt: 0)
        return window
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, navigationID, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .sidebarTrackingSeparator {
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 0)
        }
        if identifier == navigationID {
            return navigationGroup
        }
        return nil
    }

    private func updateNavigation(_ navigation: Navigation) {
        backItem.isEnabled = navigation.canGoBack
        forwardItem.isEnabled = navigation.canGoForward
        if isViewLoaded { view.window?.title = navigation.title }
        navigationDidChange?()
    }

    @objc func goBack(_ sender: Any?) {
        guard canNavigateBack else { return }
        store.send(.navigationBackRequested)
    }

    @objc func goForward(_ sender: Any?) {
        guard canNavigateForward else { return }
        store.send(.navigationForwardRequested)
    }
}

/// The scroll viewport ends at the system safe area, including during resizing.
/// Full-height layout remains available to the sidebar and tracking separator.
@MainActor
private final class SettingsDetailController: NSViewController {
    private let content: NSHostingController<SettingsWindow>

    init(store: StoreOf<AppSettings>) {
        content = NSHostingController(rootView: SettingsWindow(store: store))
        content.sceneBridgingOptions = []
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        content.view.clipsToBounds = true
        view.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
}

private struct SettingsSidebar: View {
    @Bindable var store: StoreOf<AppSettings>

    var body: some View {
        List(selection: Binding<SettingsSection?>(get: { store.selectedSection }, set: { store.send(.sectionSelected($0)) })) {
            ForEach(SettingsSection.availableCases) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
                    .padding(.vertical, 3)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("GameMode").fontWeight(.medium)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}
