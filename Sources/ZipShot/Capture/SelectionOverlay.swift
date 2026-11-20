import AppKit
import Carbon.HIToolbox
import SwiftUI

enum SelectionPurpose { case screenshot, recording }
enum SelectionMode { case region, window }

enum SelectionResult {
    /// A rectangle in global screen coordinates (origin bottom-left), aligned to whole pixels.
    case region(CGRect, NSScreen)
    case window(WindowInfo)
    case screen(NSScreen)
    case cancelled
}

/// The full-screen overlay for choosing what to capture: drag out a region,
/// press Space to pick a window instead, Return for the whole screen.
///
/// For screenshots each display shows a still taken just before the overlay
/// appeared, so the result is exactly what was on screen when the shortcut
/// was pressed (open menus, hover states and all).
@MainActor
final class SelectionOverlay {
    let purpose: SelectionPurpose
    private(set) var mode: SelectionMode
    let frozen: [CGDirectDisplayID: CGImage]
    private let pickable: [WindowInfo]
    private(set) var hovered: WindowInfo?

    private var windows: [OverlayWindow] = []
    private var completion: ((SelectionResult) -> Void)?
    private var keyMonitor: Any?

    init(purpose: SelectionPurpose, mode: SelectionMode, frozen: [CGDirectDisplayID: CGImage], pickable: [WindowInfo]) {
        self.purpose = purpose
        self.mode = mode
        self.frozen = frozen
        self.pickable = pickable
    }

    /// `show: false` builds the overlay without putting it on screen, for automated checks.
    func begin(show: Bool = true, completion: @escaping (SelectionResult) -> Void) {
        self.completion = completion
        let mouseScreen = NSScreen.underMouse
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen, overlay: self)
            windows.append(window)
            if show { window.orderFrontRegardless() }
        }
        guard show else { return }
        NSApp.activate(ignoringOtherApps: true)
        (windows.first { $0.screen == mouseScreen } ?? windows.first)?.makeKeyAndOrderFront(nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
        updateHover()
    }

    /// One view per screen, in `NSScreen.screens` order.
    var overlayViews: [NSView] { windows.map(\.overlayView) }

    func handleKey(_ event: NSEvent) -> Bool {
        guard completion != nil else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            finish(.cancelled)
        case kVK_Space where purpose == .screenshot:
            mode = mode == .region ? .window : .region
            updateHover()
            windows.forEach { $0.overlayView.modeChanged() }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard purpose == .screenshot else { return true }
            finish(.screen(NSScreen.underMouse))
        default:
            break
        }
        // Swallow every key so nothing reaches the app underneath.
        return true
    }

    /// `point` is in global screen coordinates.
    func updateHover(at point: CGPoint = NSEvent.mouseLocation) {
        let previous = hovered
        if mode == .window {
            hovered = pickable.first { $0.frame.contains(point) }
        } else {
            hovered = nil
        }
        if hovered != previous { windows.forEach { $0.overlayView.refresh() } }
    }

    func finish(_ result: SelectionResult) {
        guard let completion else { return }
        self.completion = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let closing = windows
        windows.removeAll()
        closing.forEach { $0.orderOut(nil) }
        // This usually runs inside one of these windows' own event handlers, so
        // let that event finish before the windows go away.
        DispatchQueue.main.async { _ = closing }
        completion(result)
    }

    var hints: [Hint] {
        switch (purpose, mode) {
        case (.recording, _):
            return [Hint(lead: "Drag", text: "select the region to record"), Hint(key: "Esc", text: "cancel")]
        case (.screenshot, .region):
            return [
                Hint(lead: "Drag", text: "select region"), Hint(key: "Space", text: "pick a window"),
                Hint(key: "Return", text: "whole screen"), Hint(key: "Esc", text: "cancel"),
            ]
        case (.screenshot, .window):
            return [
                Hint(lead: "Click", text: "capture window"), Hint(key: "Space", text: "select a region"),
                Hint(key: "Return", text: "whole screen"), Hint(key: "Esc", text: "cancel"),
            ]
        }
    }
}

private final class OverlayWindow: NSWindow {
    let overlayView: OverlayView

    init(screen: NSScreen, overlay: SelectionOverlay) {
        overlayView = OverlayView(screen: screen, overlay: overlay)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = overlayView
        makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class OverlayView: NSView {
    // Weak: a mouse-up can still arrive after the overlay has finished (Esc
    // pressed mid-drag) and been released by its owner.
    private weak var overlay: SelectionOverlay?
    private let screen: NSScreen
    private let scale: CGFloat

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private var handleLayers: [CAShapeLayer] = []
    private let pillLayer = CALayer()
    private let pillText = CATextLayer()
    private var hintHost: NSHostingView<HintBar>?

    private var dragStart: CGPoint?
    private var selection: CGRect?

    init(screen: NSScreen, overlay: SelectionOverlay) {
        self.screen = screen
        self.overlay = overlay
        scale = screen.backingScaleFactor
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        guard let root = layer else { return }

        if let image = overlay.frozen[screen.displayID] {
            imageLayer.contents = image
            imageLayer.contentsGravity = .resize
            root.addSublayer(imageLayer)
        }
        dimLayer.fillRule = .evenOdd
        root.addSublayer(dimLayer)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.zAccent.cgColor
        borderLayer.lineWidth = 1.5
        root.addSublayer(borderLayer)

        for _ in 0..<4 {
            let handle = CAShapeLayer()
            handle.fillColor = NSColor.zInk.cgColor
            handle.strokeColor = NSColor.zAccent.cgColor
            handle.lineWidth = 1.5
            handle.path = CGPath(rect: CGRect(x: 0.75, y: 0.75, width: 7.5, height: 7.5), transform: nil)
            handle.bounds = CGRect(x: 0, y: 0, width: 9, height: 9)
            handleLayers.append(handle)
            root.addSublayer(handle)
        }

        pillLayer.backgroundColor = NSColor.zAccent.cgColor
        pillLayer.cornerRadius = 5
        pillText.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        pillText.fontSize = 12
        pillText.foregroundColor = NSColor.zOnAccent.cgColor
        pillText.alignmentMode = .center
        pillText.contentsScale = scale
        pillLayer.addSublayer(pillText)
        root.addSublayer(pillLayer)

        let host = NSHostingView(rootView: HintBar(hints: overlay.hints))
        addSubview(host)
        hintHost = host

        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole surface is one target; the hint bar on top is only a label.
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
        dimLayer.frame = bounds
        borderLayer.frame = bounds
        if let host = hintHost {
            let size = host.fittingSize
            host.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: 28, width: size.width, height: size.height)
        }
        refresh()
    }

    func modeChanged() {
        guard let overlay else { return }
        dragStart = nil
        selection = nil
        hintHost?.rootView = HintBar(hints: overlay.hints)
        needsLayout = true
        window?.invalidateCursorRects(for: self)
        refresh()
    }

    /// The clear rectangle: the dragged selection, or the window under the pointer.
    private var hole: CGRect? {
        guard let overlay else { return nil }
        if overlay.mode == .region { return selection }
        guard let frame = overlay.hovered?.frame else { return nil }
        let local = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).intersection(bounds)
        return local.isNull || local.isEmpty ? nil : local
    }

    func refresh() {
        guard let overlay else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let hole = self.hole
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole { path.addRect(hole) }
        dimLayer.path = path
        // Lighter until something is selected, so the screen stays readable.
        dimLayer.fillColor = (hole == nil ? NSColor.zScrim.withAlphaComponent(0.3) : NSColor.zScrim).cgColor

        guard let hole else {
            borderLayer.isHidden = true
            pillLayer.isHidden = true
            handleLayers.forEach { $0.isHidden = true }
            return
        }
        borderLayer.isHidden = false
        borderLayer.path = CGPath(rect: hole, transform: nil)

        let corners = [
            CGPoint(x: hole.minX, y: hole.minY), CGPoint(x: hole.maxX, y: hole.minY),
            CGPoint(x: hole.maxX, y: hole.maxY), CGPoint(x: hole.minX, y: hole.maxY),
        ]
        for (handle, corner) in zip(handleLayers, corners) {
            handle.isHidden = overlay.mode != .region
            handle.position = corner
        }

        // What the capture will measure, in pixels.
        let label = "\(Int((hole.width * scale).rounded())) × \(Int((hole.height * scale).rounded()))"
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let width = ceil(textSize.width) + 16
        var origin = CGPoint(x: hole.minX, y: hole.maxY + 8)
        if origin.y + 24 > bounds.maxY - 4 { origin.y = hole.maxY - 32 }
        origin.x = min(max(origin.x, 4), bounds.maxX - width - 4)
        pillLayer.isHidden = false
        pillLayer.frame = CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width, height: 24)
        pillText.string = label
        pillText.frame = CGRect(x: 0, y: ((24 - ceil(textSize.height)) / 2).rounded(), width: width, height: ceil(textSize.height))
    }

    // MARK: Pointer

    private var cursor: NSCursor { overlay?.mode == .window ? .pointingHand : .crosshair }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func mouseMoved(with event: NSEvent) {
        overlay?.updateHover(at: globalPoint(event))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        guard let overlay, overlay.mode == .region else { return }
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let overlay, overlay.mode == .region, let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        let clamped = CGPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
        selection = aligned(CGRect(
            x: min(start.x, clamped.x), y: min(start.y, clamped.y),
            width: abs(clamped.x - start.x), height: abs(clamped.y - start.y)
        ))
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        guard let overlay else { return }
        switch overlay.mode {
        case .window:
            overlay.updateHover(at: globalPoint(event))
            if let window = overlay.hovered { overlay.finish(.window(window)) }
        case .region:
            dragStart = nil
            guard let rect = selection, rect.width >= 4, rect.height >= 4 else {
                // A click without a drag: stay put and let the user try again.
                selection = nil
                refresh()
                return
            }
            overlay.finish(.region(rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), screen))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        overlay?.finish(.cancelled)
    }

    /// Snaps to the display's pixel grid.
    private func aligned(_ r: CGRect) -> CGRect {
        let x0 = (r.minX * scale).rounded() / scale
        let y0 = (r.minY * scale).rounded() / scale
        let x1 = (r.maxX * scale).rounded() / scale
        let y1 = (r.maxY * scale).rounded() / scale
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
