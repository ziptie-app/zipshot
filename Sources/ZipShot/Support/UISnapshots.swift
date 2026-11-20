import AppKit
import SwiftUI
import ZipShotCore

/// Developer aid: `ZipShot --ui-snapshots <folder>` draws each piece of UI to a
/// PNG, off screen, using sample content. Nothing is captured, saved to the
/// Desktop or copied to the clipboard.
@MainActor
enum UISnapshots {
    static func run(into folder: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let work = fm.temporaryDirectory.appendingPathComponent("zipshot-snapshots-\(CaptureNaming.randomToken())")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // A sample screenshot, as if captured on a Retina display.
        let shot = sampleScreenshot(width: 1040, height: 600, frame: 0)
        let png = CaptureItem(kind: .image, url: work.appendingPathComponent("zipshot-k4x9qm2a.png"), pixelSize: CGSize(width: 1040, height: 600))
        png.renderer = Renderer(base: shot)
        png.scale = 2
        png.thumbnail = Thumbnail.make(from: shot)
        try? PNGWriter.data(for: shot, scale: 2)?.write(to: png.url)

        // A sample recording.
        let gif = CaptureItem(kind: .gif, url: work.appendingPathComponent("zipshot-p7d2wn8c.gif"), pixelSize: CGSize(width: 520, height: 300))
        if let store = try? FrameStore(width: 520, height: 300, directory: work) {
            for i in 0..<40 {
                appendFrame(sampleScreenshot(width: 520, height: 300, frame: i), to: store, time: Double(i) * 0.2)
            }
            store.finish(duration: 8)
            _ = try? GIFExporter.export(store: store, to: gif.url)
            gif.frames = store
            gif.trim = 1.2...6.8
            if let first = store.image(at: 0) { gif.thumbnail = Thumbnail.make(from: first) }
        }
        Library.shared.insertForPreview([png, gif])

        let menu = MenuModel()
        menu.highlighted = .capture(.region)
        save(MenuView(model: menu, library: Library.shared, prefs: Prefs.shared), "1-menu", in: folder)
        save(HintBar(hints: [
            Hint(lead: "Drag", text: "select region"), Hint(key: "Space", text: "pick a window"),
            Hint(key: "Return", text: "whole screen"), Hint(key: "Esc", text: "cancel"),
        ]).padding(12).background(Color(hex: 0x4A5560)), "2-hints", in: folder)
        if let screen = NSScreen.screens.first {
            // The region overlay mid-drag, over a still of the sample window.
            let pixels = CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
            let still = sampleScreenshot(width: Int(pixels.width), height: Int(pixels.height), frame: 3)
            let overlay = SelectionOverlay(purpose: .screenshot, mode: .region, frozen: [screen.displayID: still], pickable: [])
            overlay.begin(show: false) { _ in }
            let view = overlay.overlayViews[0]
            view.layoutSubtreeIfNeeded()
            func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                )!
            }
            let h = screen.frame.height
            view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 180, y: h - 130)))
            view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 700, y: h - 430)))
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            saveLayer(of: view, "2-region-select", in: folder)
            overlay.finish(.cancelled)
        }
        save(ToastView(item: png), "3-toast", in: folder)
        save(ToastView(item: gif), "3-toast-gif", in: folder)

        if let renderer = png.renderer {
            let model = EditorModel(item: png, renderer: renderer)
            model.apply { s in
                s.annotations = [
                    Annotation(shape: .blur(BlurShape(rect: CGRect(x: 60, y: 250, width: 420, height: 150), style: .pixelate, strength: 20))),
                    Annotation(shape: .arrow(ArrowShape(start: CGPoint(x: 800, y: 210), end: CGPoint(x: 520, y: 330), color: Theme.annotationRed, thickness: 8))),
                    Annotation(shape: .text(TextShape(origin: CGPoint(x: 730, y: 130), text: "Hide this", color: Theme.annotationRed, fontSize: 40))),
                ]
            }
            model.setBorderColor(Theme.accentRGBA)
            model.tool = .border
            let size = CGSize(width: 1120, height: 720)
            save(EditorView(model: model), "4-editor-border", in: folder, size: size)
            model.setBorderFill(.blur)
            save(EditorView(model: model), "4-editor-border-blur", in: folder, size: size)
            model.setBorderFill(.color)
            model.selection = model.state.annotations[1].id
            save(EditorView(model: model), "4-editor-arrow", in: folder, size: size)
            model.selection = model.state.annotations[2].id
            save(EditorView(model: model), "4-editor-text", in: folder, size: size)
            model.selection = model.state.annotations[0].id
            save(EditorView(model: model), "4-editor-blur", in: folder, size: size)
            model.tool = .crop
            model.apply { $0.crop = CGRect(x: 40, y: 60, width: 800, height: 440) }
            save(EditorView(model: model), "4-editor-crop", in: folder, size: size)
        }

        if let screen = NSScreen.screens.first {
            let region = CGRect(x: screen.frame.minX + 180, y: screen.frame.maxY - 110 - 300, width: 520, height: 300)
            let phases: [(RecordingSession.Phase, String)] = [(.ready, "ready"), (.recording, "recording"), (.paused, "paused"), (.saving, "saving")]
            for (phase, name) in phases {
                let session = RecordingSession(region: region, screen: screen, phase: phase)
                save(RecordingControls(session: session).frame(width: 420).padding(16).background(Color(hex: 0x4A5560)), "5-record-\(name)", in: folder)
                if phase == .recording {
                    save(
                        RecordingFrameView(session: session).background(Color(hex: 0xECEDEF)),
                        "5-record-frame", in: folder, size: CGSize(width: 960, height: 600)
                    )
                }
            }
        }

        if let frames = gif.frames {
            save(TrimView(model: TrimModel(item: gif, frames: frames)), "6-trim", in: folder, size: CGSize(width: 1120, height: 720), settle: 1.0)
        }
        save(SettingsView(prefs: Prefs.shared, recorder: ShortcutRecorder.shared, menu: MenuModel()), "7-settings", in: folder)
        let crowded = MenuModel()
        crowded.iconHidden = true
        save(SettingsView(prefs: Prefs.shared, recorder: ShortcutRecorder.shared, menu: crowded), "7b-settings-icon-hidden", in: folder)

        for (name, image) in [
            ("8-status-icon", IconPaths.statusImage(color: .white)),
            ("8-status-icon-open", IconPaths.statusImage(color: .zAccent)),
            ("8-status-icon-recording", IconPaths.statusImage(color: NSColor(hex: 0xFF6B5E), recording: true)),
        ] {
            save(
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 72, height: 72).padding(12).background(Color(hex: 0x15161A)),
                name, in: folder
            )
        }
        Library.shared.releaseAll()
    }

    private static func save<V: View>(_ view: V, _ name: String, in folder: URL, size: CGSize? = nil, settle: TimeInterval = 0.35) {
        let host = NSHostingView(rootView: view)
        let size = size ?? host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Give SwiftUI and any background loading a moment to settle.
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        window.contentView = nil
    }

    /// For views built from Core Animation layers, which view caching does not see.
    private static func saveLayer(of view: NSView, _ name: String, in folder: URL) {
        guard let layer = view.layer else { return }
        let scale: CGFloat = 2
        let w = Int(view.bounds.width * scale)
        let h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: folder.appendingPathComponent(name + ".png"))
    }

    private static func appendFrame(_ image: CGImage, to store: FrameStore, time: TimeInterval) {
        var pixels = [UInt32](repeating: 0, count: store.width * store.height)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: store.width, height: store.height, bitsPerComponent: 8,
                bytesPerRow: store.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            ) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: store.width, height: store.height))
            _ = try? store.append(bgra: raw.baseAddress!, bytesPerRow: store.width * 4, time: time)
        }
    }

    /// A stand-in app window: title bar, a heading, lines of "text", a progress bar.
    private static func sampleScreenshot(width: Int, height: Int, frame: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let u = CGFloat(width) / 520
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: u, y: -u)
        func fill(_ hex: UInt32, _ rect: CGRect, radius: CGFloat = 0) {
            ctx.setFillColor(NSColor(hex: hex).cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        fill(0xECEDEF, CGRect(x: 0, y: 0, width: 520, height: 300))
        fill(0xDADCE0, CGRect(x: 0, y: 0, width: 520, height: 28))
        for (i, color) in [0xFF6159, 0xFFBD2E, 0x28C941].enumerated() {
            fill(UInt32(color), CGRect(x: 12 + i * 16, y: 9, width: 10, height: 10), radius: 5)
        }
        fill(0x4A4E55, CGRect(x: 30, y: 52, width: 150, height: 12), radius: 3)
        for (row, w) in [300, 380, 240].enumerated() {
            fill(0xCFD2D7, CGRect(x: 30, y: 84 + row * 22, width: w, height: 10), radius: 3)
        }
        for row in 0..<3 {
            for word in 0..<6 {
                fill(0x868B94, CGRect(x: 34 + word * 34, y: 134 + row * 20, width: 12 + (word * 7 + row * 5) % 16, height: 8), radius: 2)
            }
        }
        fill(0xD9DCE1, CGRect(x: 30, y: 216, width: 460, height: 56), radius: 6)
        fill(0x3E7BFA, CGRect(x: 44, y: 238, width: 20 + (frame * 11) % 420, height: 12), radius: 6)
        return ctx.makeImage()!
    }
}
