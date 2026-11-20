import AppKit
import Carbon.HIToolbox
import ZipShotCore

/// Developer aid: `ZipShot --ui-check` drives the editors with synthetic mouse
/// and key events, off screen, and verifies what they did. Works on temporary
/// files only and never touches the Desktop or the clipboard.
@MainActor
enum UICheck {
    private static var failures = 0
    private static var checks = 0

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("  FAIL (line \(line)): \(message())")
        }
    }

    private static func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    static func run() -> Bool {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("zipshot-uicheck-\(CaptureNaming.randomToken())")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        editor(in: work)
        trim(in: work)
        selectionOverlay()

        print(failures == 0 ? "All \(checks) UI checks passed." : "\(failures) of \(checks) UI checks FAILED.")
        return failures == 0
    }

    // MARK: Capture editor

    private static func editor(in work: URL) {
        print("- capture editor")
        // A 1040x600 capture at 2x, in an 800x600 canvas: it shows at half size,
        // centered, so image point (x, y) sits at view point (140 + x/2, 150 + y/2).
        let ctx = CGContext(
            data: nil, width: 1040, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1040, height: 600))
        let image = ctx.makeImage()!
        let item = CaptureItem(kind: .image, url: work.appendingPathComponent("zipshot-check.png"), pixelSize: CGSize(width: 1040, height: 600))
        item.scale = 2
        let renderer = Renderer(base: image)
        item.renderer = renderer
        try? PNGWriter.data(for: image, scale: 2)?.write(to: item.url)

        // Start from known tool settings, whatever was used last.
        let model = EditorModel(item: item, renderer: renderer)
        model.setArrowThickness(4)
        model.setTextSize(20)
        model.setBlurStrength(10)
        model.setBlurStyle(.pixelate)

        let canvas = CanvasView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        canvas.layoutSubtreeIfNeeded()

        func v(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 140 + x / 2, y: 150 + y / 2) }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            // The canvas is flipped; window coordinates are not.
            NSEvent.mouseEvent(
                with: type, location: CGPoint(x: p.x, y: 600 - p.y), modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            )!
        }
        func drag(_ a: CGPoint, _ b: CGPoint, flags: NSEvent.ModifierFlags = []) {
            canvas.mouseDown(with: mouse(.leftMouseDown, a, flags: flags))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), flags: flags))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, b, flags: flags))
            canvas.mouseUp(with: mouse(.leftMouseUp, b, flags: flags))
        }
        func click(_ p: CGPoint, clicks: Int = 1) {
            canvas.mouseDown(with: mouse(.leftMouseDown, p, clicks: clicks))
            canvas.mouseUp(with: mouse(.leftMouseUp, p, clicks: clicks))
        }
        func key(_ code: Int, _ characters: String = "") {
            canvas.keyDown(with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
            )!)
        }
        func arrow(_ index: Int) -> ArrowShape? {
            guard model.state.annotations.indices.contains(index), case .arrow(let a) = model.state.annotations[index].shape else { return nil }
            return a
        }
        func blur(_ index: Int) -> BlurShape? {
            guard model.state.annotations.indices.contains(index), case .blur(let b) = model.state.annotations[index].shape else { return nil }
            return b
        }
        func text(_ index: Int) -> TextShape? {
            guard model.state.annotations.indices.contains(index), case .text(let t) = model.state.annotations[index].shape else { return nil }
            return t
        }
        func typeText(_ string: String) {
            guard let field = canvas.subviews.compactMap({ $0 as? NSTextView }).first else {
                return expect(false, "no text field to type \"\(string)\" into")
            }
            field.string = string
            field.didChangeText()
        }

        // Arrows
        model.tool = .arrow
        drag(v(100, 100), v(300, 200))
        expect(model.state.annotations.count == 1, "dragging with the arrow tool adds an arrow")
        if let a = arrow(0) {
            expect(near(a.start, CGPoint(x: 100, y: 100)) && near(a.end, CGPoint(x: 300, y: 200)), "arrow runs where it was dragged: \(a.start) -> \(a.end)")
            expect(a.thickness == 8, "4pt arrow is 8px on a 2x capture: \(a.thickness)")
        }
        expect(model.selection == model.state.annotations.first?.id, "a new arrow is selected")
        expect(model.canUndo, "adding an arrow can be undone")

        click(v(700, 500))
        expect(model.state.annotations.count == 1, "a click without a drag adds nothing")

        drag(v(400, 400), v(600, 410), flags: .shift)
        if let a = arrow(1) { expect(abs(a.end.y - 400) < 0.01 && a.end.x > 600, "shift keeps the arrow level: \(a.end)") } else { expect(false, "shift-drag adds an arrow") }

        // Move the first arrow by its shaft, then drag one end.
        drag(v(200, 150), v(240, 170))
        if let a = arrow(0) {
            expect(near(a.start, CGPoint(x: 140, y: 120)) && near(a.end, CGPoint(x: 340, y: 220)), "dragging an arrow moves it: \(a.start) -> \(a.end)")
        }
        expect(model.state.annotations.count == 2, "moving does not add an arrow")
        drag(v(340, 220), v(500, 300))
        if let a = arrow(0) {
            expect(near(a.start, CGPoint(x: 140, y: 120)) && near(a.end, CGPoint(x: 500, y: 300)), "dragging an end handle moves just that end: \(a.start) -> \(a.end)")
        }

        // Each drag is one undo step.
        model.undo()
        if let a = arrow(0) { expect(near(a.end, CGPoint(x: 340, y: 220)), "undo reverts the handle drag as a whole: \(a.end)") }
        model.redo()
        if let a = arrow(0) { expect(near(a.end, CGPoint(x: 500, y: 300)), "redo restores it: \(a.end)") }

        // Changing a setting restyles the selected arrow.
        model.setArrowColor(RGBAColor(hex: 0x3E7BFA))
        if let a = arrow(0) { expect(a.color.matches(RGBAColor(hex: 0x3E7BFA)), "the color applies to the selected arrow") }
        if let a = arrow(1) { expect(!a.color.matches(RGBAColor(hex: 0x3E7BFA)), "and not to the other one") }

        // Pixel blur
        model.tool = .blur
        expect(model.selection == nil, "switching tools drops a selection of another kind")
        drag(v(50, 300), v(250, 400))
        if let b = blur(2) {
            expect(b.rect == CGRect(x: 50, y: 300, width: 200, height: 100), "blur covers the dragged area: \(b.rect)")
            expect(b.strength == 20 && b.style == .pixelate, "blur uses the current settings: \(b.strength) \(b.style)")
        } else {
            expect(false, "dragging with the blur tool adds a blur")
        }
        // Drag its top-left corner past the bottom-right one.
        drag(v(50, 300), v(300, 450))
        if let b = blur(2) { expect(b.rect == CGRect(x: 250, y: 400, width: 50, height: 50), "a corner can cross its opposite: \(b.rect)") }
        // An arrow may start on top of a blur: the arrow tool ignores blurs.
        model.tool = .arrow
        drag(v(275, 425), v(450, 520))
        expect(model.state.annotations.count == 4 && arrow(3) != nil, "the arrow tool draws over a blur instead of grabbing it")
        if let b = blur(2) { expect(b.rect == CGRect(x: 250, y: 400, width: 50, height: 50), "and leaves the blur where it was") }
        // A blur dragged off the capture is clipped to it.
        model.tool = .blur
        drag(v(900, 500), v(1200, 700))
        if let b = blur(4) { expect(b.rect == CGRect(x: 900, y: 500, width: 140, height: 100), "blur stops at the capture's edge: \(b.rect)") } else { expect(false, "edge blur added") }

        // Text
        model.tool = .text
        click(v(600, 100))
        expect(canvas.subviews.contains { $0 is NSTextView }, "clicking with the text tool opens a text field")
        expect(model.state.annotations.count == 5, "nothing is added until text is typed")
        typeText("Hello")
        canvas.finishEditing()
        expect(!canvas.subviews.contains { $0 is NSTextView }, "finishing removes the text field")
        if let t = text(5) {
            expect(t.text == "Hello" && t.fontSize == 40, "typed text is added at 20pt (40px): \"\(t.text)\" \(t.fontSize)")
            expect(abs(t.origin.x - 600) < 0.01 && abs(t.origin.y + TextLayout.size(of: t).height / 2 - 100) < 1.5, "centered on the click: \(t.origin)")
        } else {
            expect(false, "typed text becomes an annotation")
        }
        click(v(700, 300))
        typeText("   ")
        canvas.finishEditing()
        expect(model.state.annotations.count == 6, "blank text is discarded")
        // Double-click to edit; Esc finishes.
        if let t = text(5) {
            let inside = CGPoint(x: t.origin.x + 10, y: t.origin.y + 10)
            click(v(inside.x, inside.y), clicks: 2)
            typeText("Hello there\nworld")
            canvas.finishEditing()
        }
        expect(text(5)?.text == "Hello there\nworld", "double-click edits existing text: \(text(5)?.text ?? "nil")")
        model.undo()
        expect(text(5)?.text == "Hello", "undo restores the earlier text")
        model.redo()

        // Delete and arrow keys act on the selection.
        model.selection = model.state.annotations[5].id
        let before = text(5)?.origin ?? .zero
        key(kVK_RightArrow)
        expect(near(text(5)?.origin ?? .zero, CGPoint(x: before.x + 2, y: before.y)), "arrow keys nudge by a point (2px here)")
        key(kVK_Delete)
        expect(model.state.annotations.count == 5 && model.selection == nil, "Delete removes the selection")
        key(kVK_ANSI_B, "b")
        expect(model.tool == .border, "B switches to the border tool")

        // Border
        expect(model.outputSize == CGSize(width: 1040, height: 600), "no border until one is chosen")
        model.setBorderColor(Theme.accentRGBA)
        expect(model.state.border.thickness == 48 && model.outputSize == CGSize(width: 1136, height: 696), "choosing a color adds a 24pt border: \(model.outputSize)")
        // With the border showing, the capture sits 24pt further in.
        click(CGPoint(x: 400, y: 300))
        // In the border tool a click selects whatever is under it and switches to its tool.
        let arrowMid = arrow(1).map { CGPoint(x: ($0.start.x + $0.end.x) / 2, y: ($0.start.y + $0.end.y) / 2) } ?? .zero
        let zoom = min(0.5, (800 - 64) / 1136.0)
        let origin = CGPoint(x: ((800 - 1136 * zoom) / 2).rounded(), y: ((600 - 696 * zoom) / 2).rounded())
        click(CGPoint(x: origin.x + (arrowMid.x + 48) * zoom, y: origin.y + (arrowMid.y + 48) * zoom))
        expect(model.selection == model.state.annotations[1].id && model.tool == .arrow, "clicking an arrow from the border tool selects it and shows its settings")
        model.beginGesture()
        model.setBorderThickness(0)
        model.setBorderThickness(96)
        model.endGesture()
        model.undo()
        expect(model.state.border.thickness == 48, "a slider drag undoes in one step: \(model.state.border.thickness)")
        model.setBorderThickness(0)

        // Crop: the whole capture is shown again at (140, 150), half size.
        key(kVK_ANSI_C, "c")
        expect(model.tool == .crop && model.selection == nil, "C switches to crop")
        drag(v(1040, 300), v(800, 300))
        expect(model.state.crop == CGRect(x: 0, y: 0, width: 800, height: 600), "dragging the right edge crops: \(model.state.crop)")
        drag(v(400, 300), v(700, 320))
        expect(model.state.crop == CGRect(x: 240, y: 0, width: 800, height: 600), "dragging inside moves the frame, kept on the capture: \(model.state.crop)")
        drag(v(240, 0), v(340, 100))
        expect(model.state.crop == CGRect(x: 340, y: 100, width: 700, height: 500), "dragging a corner moves two edges: \(model.state.crop)")
        drag(v(100, 50), v(102, 52))
        expect(model.state.crop == CGRect(x: 340, y: 100, width: 700, height: 500), "a tiny new frame is ignored: \(model.state.crop)")
        drag(v(20, 30), v(220, 180))
        expect(model.state.crop == CGRect(x: 20, y: 30, width: 200, height: 150), "dragging outside the frame starts a new one: \(model.state.crop)")
        key(kVK_Return)
        expect(model.tool == .arrow, "Return leaves crop for the previous tool: \(model.tool)")
        expect(model.outputSize == CGSize(width: 200, height: 150), "output is the cropped size: \(model.outputSize)")

        // Saving
        model.flush()
        if let source = CGImageSourceCreateWithURL(item.url as CFURL, nil), let saved = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            expect(saved.width == 200 && saved.height == 150, "the file on disk has the edits: \(saved.width)x\(saved.height)")
        } else {
            expect(false, "the edited file can be read back")
        }
        expect(item.editState == model.state && item.pixelSize == CGSize(width: 200, height: 150), "the capture remembers its edits for reopening")

        // Reopening continues from the same edits, and everything can still be undone.
        let reopened = EditorModel(item: item, renderer: renderer)
        expect(reopened.state == model.state, "reopening restores the edits")
        var steps = 0
        while model.canUndo && steps < 500 {
            model.undo()
            steps += 1
        }
        expect(model.state.annotations.isEmpty && model.state.crop == CGRect(x: 0, y: 0, width: 1040, height: 600), "undoing everything returns to the plain capture (\(steps) steps)")
        model.flush()
        if let source = CGImageSourceCreateWithURL(item.url as CFURL, nil), let saved = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            expect(saved.width == 1040 && saved.height == 600, "and that is saved too: \(saved.width)x\(saved.height)")
        }
        window.contentView = nil
    }

    // MARK: Selection overlay

    private static func selectionOverlay() {
        print("- selection overlay")
        guard let screen = NSScreen.screens.first else { return print("  (no screen; skipped)") }
        let frame = screen.frame
        let height = frame.height
        let picked = WindowInfo(id: 7, frame: CGRect(x: frame.minX + 300, y: frame.minY + 200, width: 400, height: 300), ownerName: "Sample")

        func make(_ purpose: SelectionPurpose, _ mode: SelectionMode) -> (SelectionOverlay, NSView, () -> SelectionResult?) {
            var result: SelectionResult?
            let overlay = SelectionOverlay(purpose: purpose, mode: mode, frozen: [:], pickable: [picked])
            overlay.begin(show: false) { result = $0 }
            let view = overlay.overlayViews[0]
            view.layoutSubtreeIfNeeded()
            return (overlay, view, { result })
        }
        // Overlay views use window coordinates directly (origin bottom-left).
        func mouse(_ view: NSView, _ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        func key(_ code: Int) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)
            )!
        }

        // Drag out a region: 520x300 with its top-left corner 180 right and 130 down.
        do {
            let (overlay, view, result) = make(.screenshot, .region)
            defer { withExtendedLifetime(overlay) {} }
            let a = CGPoint(x: 180, y: height - 130)
            let b = CGPoint(x: 700, y: height - 430)
            view.mouseDown(with: mouse(view, .leftMouseDown, a))
            view.mouseDragged(with: mouse(view, .leftMouseDragged, CGPoint(x: 400, y: height - 300)))
            expect(result() == nil, "nothing is captured mid-drag")
            view.mouseDragged(with: mouse(view, .leftMouseDragged, b))
            view.mouseUp(with: mouse(view, .leftMouseUp, b))
            if case .region(let rect, let on)? = result() {
                let want = CGRect(x: frame.minX + 180, y: frame.minY + height - 430, width: 520, height: 300)
                expect(rect == want && on == screen, "the dragged region comes back in screen coordinates: \(rect) vs \(want)")
            } else {
                expect(false, "releasing the drag finishes with a region")
            }
        }
        // Esc in the middle of a drag cancels; the mouse-up that follows, after
        // the overlay's owner has let go of it, must be harmless.
        do {
            var (overlay, view, result): (SelectionOverlay?, NSView, () -> SelectionResult?) = make(.screenshot, .region)
            view.mouseDown(with: mouse(view, .leftMouseDown, CGPoint(x: 100, y: 100)))
            view.mouseDragged(with: mouse(view, .leftMouseDragged, CGPoint(x: 300, y: 300)))
            _ = overlay?.handleKey(key(kVK_Escape))
            if case .cancelled? = result() {} else { expect(false, "Esc cancels mid-drag") }
            overlay = nil
            view.mouseDragged(with: mouse(view, .leftMouseDragged, CGPoint(x: 320, y: 320)))
            view.mouseUp(with: mouse(view, .leftMouseUp, CGPoint(x: 320, y: 320)))
            if case .cancelled? = result() {} else { expect(false, "a late mouse-up changes nothing") }
        }
        // A click without a drag keeps the overlay up; Esc cancels.
        do {
            let (overlay, view, result) = make(.screenshot, .region)
            view.mouseDown(with: mouse(view, .leftMouseDown, CGPoint(x: 300, y: 300)))
            view.mouseUp(with: mouse(view, .leftMouseUp, CGPoint(x: 300, y: 300)))
            expect(result() == nil, "a plain click selects nothing")
            expect(overlay.handleKey(key(kVK_ANSI_A)) && result() == nil, "stray keys are swallowed")
            _ = overlay.handleKey(key(kVK_Escape))
            if case .cancelled? = result() {} else { expect(false, "Esc cancels") }
        }
        // Space switches to picking a window; clicking one finishes with it.
        do {
            let (overlay, view, result) = make(.screenshot, .region)
            _ = overlay.handleKey(key(kVK_Space))
            expect(overlay.mode == .window, "Space switches to window picking")
            let inside = CGPoint(x: 350, y: 250)
            view.mouseMoved(with: mouse(view, .mouseMoved, inside))
            expect(overlay.hovered == picked, "the window under the pointer is highlighted")
            view.mouseMoved(with: mouse(view, .mouseMoved, CGPoint(x: 20, y: 20)))
            expect(overlay.hovered == nil, "and not when the pointer leaves it")
            view.mouseDown(with: mouse(view, .leftMouseDown, CGPoint(x: 20, y: 20)))
            view.mouseUp(with: mouse(view, .leftMouseUp, CGPoint(x: 20, y: 20)))
            expect(result() == nil, "clicking empty space picks nothing")
            view.mouseDown(with: mouse(view, .leftMouseDown, inside))
            view.mouseUp(with: mouse(view, .leftMouseUp, inside))
            if case .window(let info)? = result() { expect(info == picked, "clicking a window picks it") } else { expect(false, "clicking a window finishes with it") }
        }
        // Return takes the whole screen.
        do {
            let (overlay, _, result) = make(.screenshot, .region)
            _ = overlay.handleKey(key(kVK_Return))
            if case .screen? = result() {} else { expect(false, "Return captures the whole screen") }
        }
        // Choosing a region to record: no window picking, no whole-screen shortcut.
        do {
            let (overlay, _, result) = make(.recording, .region)
            _ = overlay.handleKey(key(kVK_Space))
            _ = overlay.handleKey(key(kVK_Return))
            expect(overlay.mode == .region && result() == nil, "Space and Return do nothing when choosing a region to record")
            overlay.finish(.cancelled)
        }
    }

    // MARK: Trim editor

    private static func trim(in work: URL) {
        print("- trim editor")
        guard let store = try? FrameStore(width: 64, height: 48, directory: work) else { return expect(false, "frame store") }
        var pixels = [UInt32](repeating: 0xFF20_2020, count: 64 * 48)
        for i in 0..<40 {
            pixels[i] = 0xFFC6_F24E  // one more lit pixel per frame
            pixels.withUnsafeBytes { _ = try? store.append(bgra: $0.baseAddress!, bytesPerRow: 64 * 4, time: Double(i) * 0.2) }
        }
        store.finish(duration: 8)
        let item = CaptureItem(kind: .gif, url: work.appendingPathComponent("zipshot-check.gif"), pixelSize: CGSize(width: 64, height: 48))
        item.frames = store
        _ = try? GIFExporter.export(store: store, to: item.url)

        let model = TrimModel(item: item, frames: store)
        model.copiesAfterSaving = false
        expect(model.start == 0 && model.end == 8 && !model.isTrimmed && !model.hasUnsavedTrim, "opens on the whole recording")

        model.setStart(1.2, minLength: 0.5)
        model.setEnd(6.8, minLength: 0.5)
        expect(model.start == 1.2 && model.end == 6.8 && model.isTrimmed && model.hasUnsavedTrim, "handles set the range: \(model.start)...\(model.end)")
        model.setStart(7.5, minLength: 0.5)
        expect(abs(model.start - 6.3) < 1e-9, "start cannot pass the end: \(model.start)")
        model.setEnd(0, minLength: 0.5)
        expect(abs(model.end - 6.8) < 1e-9, "end cannot pass the start: \(model.end)")
        model.setStart(-3, minLength: 0.5)
        model.setEnd(99, minLength: 0.5)
        expect(model.start == 0 && model.end == 8, "handles stop at the ends")
        model.setStart(1.2, minLength: 0.5)
        model.setEnd(6.8, minLength: 0.5)
        model.scrub(to: 0.3)
        expect(model.playhead == 1.2, "scrubbing stays inside the range: \(model.playhead)")
        model.scrub(to: 4)
        expect(model.playhead == 4 && model.frameImage != nil, "scrubbing shows a frame")

        model.togglePlay()
        expect(model.isPlaying, "plays")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        expect(model.playhead > 4.2 && model.playhead < 4.8, "playback advances in real time: \(model.playhead)")
        model.togglePlay()
        expect(!model.isPlaying, "pauses")

        model.save()
        let deadline = Date().addingTimeInterval(10)
        while model.isSaving && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        expect(!model.isSaving && model.errorText == nil, "saving finishes: \(model.errorText ?? "ok")")
        expect(item.trim == 1.2...6.8 && !model.hasUnsavedTrim, "the capture remembers its trim")
        if let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) {
            let count = CGImageSourceGetCount(source)
            var total = 0.0
            for i in 0..<count {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                total += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0
            }
            expect(count == 28, "the saved GIF holds the 28 frames in range: \(count)")
            expect(abs(total - 5.6) < 0.011, "and lasts 5.6s: \(total)")
        } else {
            expect(false, "the trimmed GIF can be read back")
        }

        // The original frames are kept, so a trim can be undone after saving.
        let reopened = TrimModel(item: item, frames: store)
        expect(reopened.start == 1.2 && reopened.end == 6.8 && reopened.duration == 8, "reopening shows the saved trim on the full recording")
        model.reset()
        expect(model.start == 0 && model.end == 8 && model.hasUnsavedTrim, "reset returns to the full recording")
    }
}
