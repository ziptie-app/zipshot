import AppKit
import SwiftUI
import ZipShotCore

/// Windows in ZipShot's style: dark, with the content drawn up under the title bar.
@MainActor
enum ZWindow {
    static func make(title: String, contentSize: CGSize, minSize: CGSize, resizable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize), styleMask: style, backing: .buffered, defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .zPanel
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = minSize
        window.center()
        return window
    }
}

extension NSWindow {
    var titlebarHeight: CGFloat { max(28, frame.height - contentLayoutRect.height) }
}

/// ZipShot lives in the menu bar; it only shows up in the Dock and app
/// switcher while one of its real windows is open.
@MainActor
enum AppWindows {
    private static var open = 0

    static func present(_ window: NSWindow) {
        open += 1
        NSApp.setActivationPolicy(.regular)
        // Activate on the next turn so the menu bar picks up the policy change.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    static func closed() {
        open = max(0, open - 1)
        if open == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSUserInterfaceValidations {
    let model: EditorModel
    private weak var canvas: CanvasView?

    init(item: CaptureItem, renderer: Renderer) {
        model = EditorModel(item: item, renderer: renderer)

        // Open at the capture's on-screen size where that fits.
        let natural = CGSize(width: renderer.size.width / model.scale, height: renderer.size.height / model.scale)
        let screen = NSScreen.underMouse.visibleFrame
        let content = CGSize(
            width: min(max(natural.width + 64 + 280, 900), screen.width * 0.9),
            height: min(max(natural.height + 64 + 130, 560), screen.height * 0.9)
        )
        let window = ZWindow.make(title: item.fileName, contentSize: content, minSize: CGSize(width: 820, height: 480))
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: EditorView(
            model: model, titlebarHeight: window.titlebarHeight,
            onCanvas: { [weak self] canvas in
                self?.canvas = canvas
                DispatchQueue.main.async { canvas.window?.makeFirstResponder(canvas) }
            }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // Menu commands, reached through the responder chain. While text is being
    // typed the text view is first responder and handles these itself.

    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }

    @objc func copy(_ sender: Any?) {
        canvas?.finishEditing()
        model.copyToClipboard()
    }

    @objc func delete(_ sender: Any?) { model.deleteSelection() }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return model.canUndo
        case #selector(redo(_:)): return model.canRedo
        case #selector(delete(_:)): return model.selection != nil
        default: return true
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Tool keys, Delete and the Edit menu all go through the canvas.
        if let window, let canvas, !(window.firstResponder is NSTextView), window.firstResponder !== canvas {
            window.makeFirstResponder(canvas)
        }
    }

    func windowWillClose(_ notification: Notification) {
        canvas?.finishEditing()
        model.flush()
        ColorPanelBridge.shared.detach()
        NSColorPanel.shared.orderOut(nil)
        EditorWindows.closed(model.item)
    }

    func flush() {
        canvas?.finishEditing()
        model.flush()
    }
}

/// Opens the right editor for a capture and keeps one window per capture.
@MainActor
enum EditorWindows {
    private static var controllers: [UUID: NSWindowController] = [:]

    static func isOpen(_ item: CaptureItem) -> Bool { controllers[item.id] != nil }

    static func open(_ item: CaptureItem) {
        if let existing = controllers[item.id], let window = existing.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard item.fileExists || item.renderer != nil || item.frames != nil else {
            Library.shared.remove(item)
            NSSound.beep()
            return
        }

        let controller: NSWindowController
        switch item.kind {
        case .image:
            if item.renderer == nil {
                // An older capture, no longer held in memory: continue from the saved file.
                guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else { return NSSound.beep() }
                item.renderer = Renderer(base: image)
                item.editState = nil
            }
            guard let renderer = item.renderer else { return }
            controller = EditorWindowController(item: item, renderer: renderer)
        case .gif:
            guard let frames = item.frames else {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                return
            }
            controller = TrimWindowController(item: item, frames: frames)
        }
        controllers[item.id] = controller
        if let window = controller.window { AppWindows.present(window) }
    }

    static func closed(_ item: CaptureItem) {
        guard let controller = controllers.removeValue(forKey: item.id) else { return }
        // Called while the window is still closing; release it afterwards.
        DispatchQueue.main.async { _ = controller }
        AppWindows.closed()
    }

    /// Writes out anything unsaved, for when the app quits.
    static func flushAll() {
        for controller in controllers.values { (controller as? EditorWindowController)?.flush() }
    }
}
