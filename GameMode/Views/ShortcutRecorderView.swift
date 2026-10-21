//
//  ShortcutRecorderView.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import SwiftUI

/// A native shortcut table uses the same selection and checkbox controls as macOS.
struct ShortcutRecorderView: NSViewRepresentable {
    var hotkeys: [AppHotkey]
    var recordingHotkeyID: String?
    var isEnabled: Bool
    var onEnable: (String, Bool) -> Void
    var onRecord: (String) -> Void
    var onClear: (String) -> Void
    var onStopRecording: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let table = HotkeyTable()
        table.frame = NSRect(x: 0, y: 0, width: 600, height: CGFloat(hotkeys.count) * 24)
        table.autoresizingMask = .width
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.usesAlternatingRowBackgroundColors = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for (identifier, width) in [("enabled", CGFloat(44)), ("action", 280), ("shortcut", 150)] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.width = width
            if identifier == "action" { column.minWidth = 100; column.resizingMask = .autoresizingMask }
            else { column.minWidth = width; column.maxWidth = width; column.resizingMask = [] }
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.editClickedShortcut(_:))
        table.onEdit = { [weak coordinator = context.coordinator] row in coordinator?.edit(row: row) }
        table.onClear = { [weak coordinator = context.coordinator] row in coordinator?.clear(row: row) }
        table.setAccessibilityLabel("GameMode keyboard shortcuts")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        menu.addItem(withTitle: "Change Shortcut", action: #selector(Coordinator.editSelectedShortcut(_:)), keyEquivalent: "").target = context.coordinator
        menu.addItem(withTitle: "Clear Shortcut", action: #selector(Coordinator.clearSelectedShortcut(_:)), keyEquivalent: "").target = context.coordinator
        table.menu = menu
        scroll.documentView = table
        context.coordinator.table = table
        table.reloadData()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let previous = context.coordinator.parent
        context.coordinator.parent = self
        guard hotkeys != previous.hotkeys || recordingHotkeyID != previous.recordingHotkeyID || isEnabled != previous.isEnabled else { return }
        guard let table = context.coordinator.table else { return }
        let selectedID = previous.hotkeys.indices.contains(table.selectedRow) ? previous.hotkeys[table.selectedRow].id : nil
        context.coordinator.isUpdating = true
        table.reloadData()
        if let selectedID, let row = hotkeys.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        context.coordinator.isUpdating = false
        if let row = hotkeys.firstIndex(where: { $0.id == recordingHotkeyID }),
           let cell = table.view(atColumn: 2, row: row, makeIfNecessary: true) as? NSTableCellView {
            cell.textField?.selectText(nil)
        }
    }

    final class HotkeyTable: NSTableView {
        var onEdit: ((Int) -> Void)?
        var onClear: ((Int) -> Void)?

        override func keyDown(with event: NSEvent) {
            if [36, 76].contains(event.keyCode) { onEdit?(selectedRow) }
            else if [51, 117].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { onClear?(selectedRow) }
            else { super.keyDown(with: event) }
        }
    }

    final class TextCell: NSTableCellView {
        var isUnassigned = false
        var isRecording = false
        override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColor() } }

        func updateColor() {
            textField?.textColor = isRecording ? .labelColor : (backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : (isUnassigned ? .secondaryLabelColor : .labelColor))
        }
    }

    private final class ShortcutField: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? {
            isEditable ? super.hitTest(point) : nil
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var parent: ShortcutRecorderView
        weak var table: HotkeyTable?
        var isUpdating = false

        init(parent: ShortcutRecorderView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.hotkeys.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, parent.hotkeys.indices.contains(row) else { return nil }
            let hotkey = parent.hotkeys[row]
            if column.identifier.rawValue == "enabled" {
                let cell = NSTableCellView()
                let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(enableShortcut(_:)))
                checkbox.tag = row
                checkbox.state = hotkey.isEnabled ? .on : .off
                checkbox.isEnabled = parent.isEnabled
                checkbox.setAccessibilityLabel(hotkey.displayName)
                checkbox.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(checkbox)
                NSLayoutConstraint.activate([
                    checkbox.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
                return cell
            }
            let isShortcut = column.identifier.rawValue == "shortcut"
            let isRecording = isShortcut && parent.recordingHotkeyID == hotkey.id
            let value = isShortcut ? (isRecording ? "Type shortcut" : (hotkey.keyCode == nil ? "none" : hotkey.displayString)) : hotkey.displayName
            let cell = TextCell()
            cell.isUnassigned = isShortcut && hotkey.keyCode == nil
            cell.isRecording = isRecording
            let field = ShortcutField(labelWithString: value)
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.alignment = isShortcut ? .right : .left
            field.lineBreakMode = .byTruncatingTail
            field.isBezeled = isRecording
            field.isEditable = isRecording
            field.isSelectable = isRecording
            field.delegate = self
            field.bezelStyle = .roundedBezel
            field.drawsBackground = isRecording
            field.backgroundColor = .textBackgroundColor
            field.translatesAutoresizingMaskIntoConstraints = false
            if isShortcut {
                field.setAccessibilityLabel("\(hotkey.displayName) shortcut")
                field.setAccessibilityValue(isRecording ? "Recording" : value)
                field.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Change Shortcut") { [weak self] in
                    guard let self, self.parent.isEnabled else { return false }
                    self.parent.onRecord(hotkey.id)
                    return true
                }])
            }
            cell.textField = field
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: isShortcut ? 0 : 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: isShortcut ? -10 : 0),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.updateColor()
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table, let recording = parent.recordingHotkeyID else { return }
            if !parent.hotkeys.indices.contains(table.selectedRow) || parent.hotkeys[table.selectedRow].id != recording { parent.onStopRecording() }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if !isUpdating, parent.recordingHotkeyID != nil { parent.onStopRecording() }
        }

        @objc func enableShortcut(_ sender: NSButton) {
            guard parent.isEnabled, parent.hotkeys.indices.contains(sender.tag) else { return }
            parent.onEnable(parent.hotkeys[sender.tag].id, sender.state == .on)
        }

        @objc func editClickedShortcut(_ sender: NSTableView) {
            guard sender.clickedColumn == 2 else { return }
            edit(row: sender.clickedRow)
        }

        func edit(row: Int) {
            guard parent.isEnabled, parent.hotkeys.indices.contains(row) else { return }
            table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if let table { table.window?.makeFirstResponder(table) }
            parent.onRecord(parent.hotkeys[row].id)
        }

        func clear(row: Int) {
            guard parent.isEnabled, parent.hotkeys.indices.contains(row) else { return }
            parent.onClear(parent.hotkeys[row].id)
        }

        @objc func editSelectedShortcut(_ sender: Any?) { if let table { edit(row: table.selectedRow) } }
        @objc func clearSelectedShortcut(_ sender: Any?) { if let table { clear(row: table.selectedRow) } }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table else { return }
            if parent.hotkeys.indices.contains(table.clickedRow) { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
            let hasSelection = parent.isEnabled && parent.hotkeys.indices.contains(table.selectedRow)
            menu.items[0].isEnabled = hasSelection
            menu.items[1].isEnabled = hasSelection && parent.hotkeys[table.selectedRow].keyCode != nil
        }
    }
}
