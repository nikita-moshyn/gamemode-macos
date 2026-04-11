//
//  RefreshRateLock.swift
//  GameMode
//
//  Created by Nikita Moshyn on 08/04/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import AppKit
import QuartzCore

/// Forces ProMotion displays to maintain 120Hz by continuously submitting
/// frames via a tiny, invisible overlay window with a CVDisplayLink.
///
/// ProMotion determines refresh rate based on whether new frames are being
/// submitted to the WindowServer. A constant stream of 120fps frame
/// submissions prevents the display from downclocking to 60Hz.
///
/// Limitations:
/// - Does NOT work when Low Power Mode is enabled (hardware-level 60Hz cap)
/// - Increases battery consumption while active
/// - Thermal throttling can still reduce refresh rate
class RefreshRateLock {

    private var overlayWindow: NSWindow?
    private var displayLink: CVDisplayLink?
    private var flipLayer: CALayer?
    private var isFlipState = false

    /// Thread-safe active state. Set eagerly in start()/stop() to prevent races.
    private(set) var isActive = false

    // MARK: - ProMotion Detection

    /// Whether the current main screen supports ProMotion (120Hz+).
    /// Checks `minimumRefreshInterval` — ProMotion screens report ~0.00833 (1/120).
    static var isProMotionAvailable: Bool {
        guard let screen = NSScreen.main else { return false }
        if #available(macOS 12.0, *) {
            return screen.minimumRefreshInterval <= 0.00834
        }
        return false
    }

    /// The maximum refresh rate of the main screen in Hz.
    static var maxRefreshRate: Int {
        guard let screen = NSScreen.main else { return 60 }
        if #available(macOS 12.0, *) {
            let interval = screen.minimumRefreshInterval
            guard interval > 0 else { return 60 }
            return Int(round(1.0 / interval))
        }
        return 60
    }

    // MARK: - Start / Stop

    func start() {
        guard !isActive else {
            Log.debug("Refresh rate lock already active", category: "Display")
            return
        }

        guard RefreshRateLock.isProMotionAvailable else {
            Log.warning("ProMotion not available on current display, skipping refresh rate lock", category: "Display")
            return
        }

        isActive = true
        Log.info("Refresh rate lock starting (max rate: \(RefreshRateLock.maxRefreshRate)Hz)", category: "Display")

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            self.createOverlayAndStartDisplayLink()
        }
    }

    func stop() {
        guard isActive else { return }

        isActive = false
        Log.info("Refresh rate lock stopping", category: "Display")

        DispatchQueue.main.async { [weak self] in
            self?.tearDown()
        }
    }

    // MARK: - Internal

    private func createOverlayAndStartDisplayLink() {
        // Create a 1x1 borderless, transparent, click-through window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.level = .screenSaver + 1
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hasShadow = false

        // Create a tiny layer that we'll flip colors on
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        contentView.wantsLayer = true
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        layer.backgroundColor = NSColor.black.cgColor
        contentView.layer?.addSublayer(layer)
        window.contentView = contentView

        self.overlayWindow = window
        self.flipLayer = layer
        self.isFlipState = false

        window.orderFrontRegardless()

        // Create CVDisplayLink for the main display
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)

        guard let displayLink = link else {
            Log.error("Failed to create CVDisplayLink", category: "Display")
            tearDown()
            return
        }

        // The callback flips the pixel directly on the CVDisplayLink thread
        // using CATransaction — avoids flooding the main queue at 120Hz.
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo else { return kCVReturnSuccess }
            let engine = Unmanaged<RefreshRateLock>.fromOpaque(userInfo).takeUnretainedValue()
            engine.flipPixel()
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)

        self.displayLink = displayLink
        Log.info("Refresh rate lock overlay and display link active", category: "Display")
    }

    /// Flip the pixel color. Called directly from the CVDisplayLink thread.
    /// CATransaction commits are safe from any thread.
    private func flipPixel() {
        guard let layer = flipLayer else { return }
        isFlipState.toggle()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = isFlipState
            ? CGColor(gray: 0.01, alpha: 1.0)
            : CGColor(gray: 0.0, alpha: 1.0)
        CATransaction.commit()
    }

    private func tearDown() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }

        flipLayer?.removeFromSuperlayer()
        flipLayer = nil

        overlayWindow?.orderOut(nil)
        overlayWindow = nil

        Log.info("Refresh rate lock overlay and display link torn down", category: "Display")
    }

    deinit {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
    }
}
