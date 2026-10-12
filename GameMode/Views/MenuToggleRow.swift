//
//  MenuToggleRow.swift
//  GameMode
//
//  Created by Nikita Moshyn on 10/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit

/// Presentation stays on the main thread even if the settings worker has already
/// finished. A pending mouse request never relabels Game Mode as "Enabling…".
struct MenuModePresentation {
    var gameModeEnabled: Bool
    var mouseProfileEnabled: Bool
    var isTransitioning: Bool
    var gameModeTarget: Bool
    var mouseProfileTarget: Bool?
    var requiresRecovery: Bool

    var gameModeSwitchIsOn: Bool { isTransitioning ? gameModeTarget : gameModeEnabled }
    var mouseSwitchIsOn: Bool { mouseProfileTarget ?? mouseProfileEnabled }

    var status: String {
        if requiresRecovery { return "Recovery Required" }
        let onlyMouseIsChanging = mouseProfileTarget != nil && gameModeTarget == gameModeEnabled
        if isTransitioning && !onlyMouseIsChanging { return gameModeTarget ? "Enabling…" : "Disabling…" }
        return gameModeEnabled ? "Enabled" : "Disabled"
    }
}

/// NSMenu supplies the material; custom menu views draw their own selection.
/// Busy controls keep their appearance while refusing another activation.
final class MenuToggleRow: NSView {
    private let titleLabel: NSTextField
    private let statusLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    let toggle = MenuRowSwitch()
    var onToggle: (() -> Void)?
    private var pointerInside = false
    private var menuHighlighted = false
    private var hoverTrackingArea: NSTrackingArea?
    private var isBusy = false
    private var presentationAllowsActivation = true

    var isHighlighted: Bool { presentationAllowsActivation && toggle.isEnabled && (pointerInside || menuHighlighted) }

    init(title: String, showsStatus: Bool) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: showsStatus ? 36 : 28))
        autoresizingMask = [.width]
        titleLabel.font = .systemFont(ofSize: 13, weight: showsStatus ? .semibold : .regular)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = !showsStatus
        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.textColor = .tertiaryLabelColor
        toggle.controlSize = showsStatus ? .regular : .small
        toggle.target = self
        toggle.action = #selector(switchChanged)
        toggle.setAccessibilityLabel(title)
        [titleLabel, statusLabel, shortcutLabel].forEach {
            $0.setAccessibilityElement(false)
            addSubview($0)
        }
        addSubview(toggle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: bounds.width - toggle.frame.width - 14, y: (bounds.height - toggle.frame.height) / 2)
        let titleWidth = toggle.frame.minX - 28
        titleLabel.frame = NSRect(x: 14, y: statusLabel.isHidden ? 6 : 18, width: titleWidth, height: 17)
        statusLabel.frame = NSRect(x: 14, y: 3, width: titleWidth, height: 14)
        // Shortcut remains available visually without crowding the primary label.
        shortcutLabel.sizeToFit()
        shortcutLabel.frame.origin = NSPoint(x: toggle.frame.minX - shortcutLabel.frame.width - 10, y: 3)
        if !statusLabel.isHidden {
            statusLabel.frame.size.width = max(80, shortcutLabel.frame.minX - 22)
        }
    }

    func update(isOn: Bool, isEnabled: Bool, isBusy: Bool = false, status: String? = nil, shortcut: String? = nil) {
        let state: NSControl.StateValue = isOn ? .on : .off
        // Reassigning the same state interrupts an in-flight native switch animation.
        if toggle.state != state {
            if window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    toggle.animator().state = state
                }
            } else {
                toggle.state = state
            }
        }
        if toggle.isEnabled != isEnabled { toggle.isEnabled = isEnabled }
        self.isBusy = isBusy
        toggle.acceptsActivation = !isBusy && presentationAllowsActivation
        if statusLabel.stringValue != (status ?? "") { statusLabel.stringValue = status ?? "" }
        let shortcutText = statusLabel.isHidden ? "" : (shortcut ?? "")
        if shortcutLabel.stringValue != shortcutText {
            shortcutLabel.stringValue = shortcutText
            needsLayout = true
        }
        let toolTip = shortcut.map { "\(titleLabel.stringValue) (\($0))" } ?? titleLabel.stringValue
        if toggle.toolTip != toolTip { toggle.toolTip = toolTip }
        let help = [status, isBusy ? "Updating settings" : nil, shortcut].compactMap { $0 }.joined(separator: ". ")
        if toggle.accessibilityHelp() != help { toggle.setAccessibilityHelp(help) }
        updateColors()
    }

    func setPresentationInteractive(_ interactive: Bool) {
        guard presentationAllowsActivation != interactive else { return }
        presentationAllowsActivation = interactive
        toggle.acceptsActivation = interactive && !isBusy
        setAccessibilityHidden(!interactive)
        if !interactive { setMenuHighlighted(false, clearPointer: true) }
        else { updateColors() }
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            pointerInside = false
            menuHighlighted = false
            updateColors()
        }
    }

    override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    override func mouseMoved(with event: NSEvent) { setPointerInside(true) }
    override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    func setMenuHighlighted(_ highlighted: Bool, clearPointer: Bool = false) {
        menuHighlighted = highlighted
        if clearPointer { pointerInside = false }
        updateColors()
    }

    private func setPointerInside(_ inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        updateColors()
    }

    private func updateColors() {
        titleLabel.textColor = isHighlighted ? .selectedMenuItemTextColor : (toggle.isEnabled ? .labelColor : .secondaryLabelColor)
        statusLabel.textColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        shortcutLabel.textColor = isHighlighted ? .selectedMenuItemTextColor : .tertiaryLabelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let view = super.hitTest(point) else { return nil }
        return view is NSTextField ? self : view
    }

    // Consume row clicks here so AppKit does not dispatch a second menu action.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard toggle.isEnabled, toggle.acceptsActivation,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle?()
    }

    @objc private func switchChanged() {
        guard toggle.isEnabled, toggle.acceptsActivation else { return }
        onToggle?()
    }
}

/// Expands the existing menu item rather than inserting a full-height row in one
/// frame. The row keeps its own size; the container reveals and fades its content.
final class MenuRowRevealView: NSView {
    private struct Transition {
        var startedAt: TimeInterval
        var duration: TimeInterval
        var from: CGFloat
        var to: CGFloat
    }

    let row: MenuToggleRow
    private weak var item: NSMenuItem?
    private let rowHeight: CGFloat
    private let clock: () -> TimeInterval
    private let reduceMotion: () -> Bool
    private var transition: Transition?
    private var timer: Timer?
    private(set) var isExpanded = false
    private(set) var revealProgress: CGFloat = 0
    var isAnimating: Bool { transition != nil }
    override var isFlipped: Bool { true }

    init(row: MenuToggleRow, item: NSMenuItem, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.row = row
        self.item = item
        self.rowHeight = row.frame.height
        self.clock = clock
        self.reduceMotion = reduceMotion
        super.init(frame: NSRect(x: 0, y: 0, width: row.frame.width, height: 0))
        autoresizingMask = [.width]
        clipsToBounds = true
        addSubview(row)
        row.alphaValue = 0
        row.setPresentationInteractive(false)
        item.view = self
        item.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        row.frame = NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded || (!animated && isAnimating) else { return }
        // Sample the current position before reversing an unfinished reveal.
        advanceAnimation()
        timer?.invalidate()
        timer = nil
        transition = nil
        isExpanded = expanded
        row.setPresentationInteractive(false)
        let target: CGFloat = expanded ? 1 : 0
        guard animated, !reduceMotion(), revealProgress != target else {
            finishAnimation()
            return
        }

        if item?.isHidden == true { item?.isHidden = false }
        transition = Transition(startedAt: clock(), duration: 0.2 * Double(abs(target - revealProgress)), from: revealProgress, to: target)
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.advanceAnimation() }
        timer.tolerance = 0.002
        self.timer = timer
        // A normal default-mode timer stops while NSMenu is tracking the pointer.
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func advanceAnimation() {
        guard let transition else { return }
        let elapsed = max(0, clock() - transition.startedAt)
        guard elapsed < transition.duration, !reduceMotion() else {
            finishAnimation()
            return
        }
        let fraction = CGFloat(elapsed / transition.duration)
        let eased = fraction * fraction * (3 - 2 * fraction)
        applyProgress(transition.from + (transition.to - transition.from) * eased)
    }

    func finishAnimation() {
        timer?.invalidate()
        timer = nil
        transition = nil
        applyProgress(isExpanded ? 1 : 0)
        // Collapse to zero before hiding, so hiding cannot move the remaining items.
        if item?.isHidden != !isExpanded { item?.isHidden = !isExpanded }
        row.setPresentationInteractive(isExpanded)
    }

    private func applyProgress(_ progress: CGFloat) {
        revealProgress = progress
        let scale = window?.backingScaleFactor ?? 2
        let height = (rowHeight * progress * scale).rounded() / scale
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
        if row.alphaValue != progress { row.alphaValue = progress }
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isExpanded, !isAnimating else { return nil }
        return super.hitTest(point)
    }

    deinit { timer?.invalidate() }
}

/// Temporarily block interaction without flashing the switch's disabled artwork.
final class MenuRowSwitch: NSSwitch {
    var acceptsActivation = true

    override func mouseDown(with event: NSEvent) {
        guard acceptsActivation else { return }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard acceptsActivation else { return }
        super.keyDown(with: event)
    }

    override func isAccessibilityEnabled() -> Bool { isEnabled && acceptsActivation }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, acceptsActivation else { return false }
        return super.accessibilityPerformPress()
    }
}
