import AppKit
import Carbon.HIToolbox
import Combine
import ZipShotCore

/// The editor's drawing surface: shows the capture as it will be saved and
/// turns pointer and key input into edits on the model.
@MainActor
final class CanvasView: NSView, NSTextViewDelegate {
    private let model: EditorModel
    private var observers = Set<AnyCancellable>()
    private var lastTool: EditorTool

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    private enum Drag {
        case newArrow(UUID)
        /// Sizing a blur rectangle from a fixed corner; `isNew` when it was just created.
        case blurRect(UUID, anchor: CGPoint, isNew: Bool)
        case move(UUID, last: CGPoint)
        case arrowEnd(UUID, Handle)
        case cropMove(offset: CGSize)
        case cropEdges(Edges, original: CGRect)
        case cropNew(anchor: CGPoint)
    }
    private var drag: Drag?

    private struct TextEdit {
        let id: UUID
        let isNew: Bool
        var shape: TextShape
        let view: NSTextView
    }
    private var textEdit: TextEdit?

    /// A scaled-down copy of the capture for drawing large images quickly.
    private var proxy: (image: CGImage, width: Int)?

    init(model: EditorModel) {
        self.model = model
        lastTool = model.tool
        super.init(frame: .zero)
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.modelChanged() }
            .store(in: &observers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func modelChanged() {
        if model.tool != lastTool {
            lastTool = model.tool
            commitText()
            window?.invalidateCursorRects(for: self)
        }
        if var edit = textEdit {
            // Color and size changes apply to the text being typed.
            edit.shape.color = model.textColor
            edit.shape.fontSize = CGFloat(model.textSize) * model.scale
            textEdit = edit
            layoutTextEditor()
        }
        needsDisplay = true
    }

    // MARK: Geometry

    /// How the scene (the image, or the image inside its border) sits in the view.
    private struct Layout {
        var zoom: CGFloat          // view points per image pixel
        var origin: CGPoint        // view position of the scene's top-left corner
        var sceneSize: CGSize      // in image pixels
        var offset: CGPoint        // image coordinates of the scene's top-left corner

        var sceneRect: CGRect {
            CGRect(x: origin.x, y: origin.y, width: sceneSize.width * zoom, height: sceneSize.height * zoom)
        }
    }

    private var layoutInfo: Layout {
        let state = model.state
        let sceneSize: CGSize
        let offset: CGPoint
        if model.tool == .crop {
            // Cropping shows the whole capture, so nothing jumps while the frame moves.
            sceneSize = model.renderer.size
            offset = .zero
        } else {
            let inset = state.border.inset
            sceneSize = CGSize(width: state.crop.width + 2 * inset, height: state.crop.height + 2 * inset)
            offset = CGPoint(x: state.crop.minX - inset, y: state.crop.minY - inset)
        }
        let pad: CGFloat = 32
        let fit = min(
            (bounds.width - 2 * pad) / max(1, sceneSize.width),
            (bounds.height - 2 * pad) / max(1, sceneSize.height)
        )
        // Never larger than life: one image pixel per screen pixel at most.
        let zoom = max(0.01, min(1 / model.scale, fit))
        let origin = CGPoint(
            x: ((bounds.width - sceneSize.width * zoom) / 2).rounded(),
            y: ((bounds.height - sceneSize.height * zoom) / 2).rounded()
        )
        return Layout(zoom: zoom, origin: origin, sceneSize: sceneSize, offset: offset)
    }

    private func imagePoint(_ v: CGPoint, _ l: Layout) -> CGPoint {
        CGPoint(x: (v.x - l.origin.x) / l.zoom + l.offset.x, y: (v.y - l.origin.y) / l.zoom + l.offset.y)
    }

    private func viewPoint(_ p: CGPoint, _ l: Layout) -> CGPoint {
        CGPoint(x: (p.x - l.offset.x) * l.zoom + l.origin.x, y: (p.y - l.offset.y) * l.zoom + l.origin.y)
    }

    private func viewRect(_ r: CGRect, _ l: Layout) -> CGRect {
        let o = viewPoint(r.origin, l)
        return CGRect(x: o.x, y: o.y, width: r.width * l.zoom, height: r.height * l.zoom)
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        let b = model.imageBounds
        return CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    override func layout() {
        super.layout()
        layoutTextEditor()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.zWindow.setFill()
        bounds.fill()

        let l = layoutInfo
        let scene = l.sceneRect

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 32, color: CGColor(gray: 0, alpha: 0.4))
        ctx.setFillColor(NSColor.zWindow.cgColor)
        ctx.fill(scene)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: scene)
        ctx.translateBy(x: l.origin.x, y: l.origin.y)
        ctx.scaleBy(x: l.zoom, y: l.zoom)
        ctx.interpolationQuality = .high
        let stand = proxyImage(zoom: l.zoom)
        if model.tool == .crop {
            model.renderer.drawContent(model.state, in: ctx, skipping: textEdit?.id, proxy: stand)
        } else {
            model.renderer.drawScene(model.state, in: ctx, skipping: textEdit?.id, proxy: stand)
        }
        ctx.restoreGState()

        if model.tool == .crop {
            drawCropFrame(ctx, l)
        } else {
            drawSelection(ctx, l)
        }
        if let edit = textEdit {
            drawDashedBox(edit.view.frame.insetBy(dx: -8, dy: -4), ctx)
        }
    }

    private func proxyImage(zoom: CGFloat) -> CGImage? {
        let backing = window?.backingScaleFactor ?? 2
        let ratio = zoom * backing  // screen pixels per image pixel
        guard ratio < 0.7 else {
            proxy = nil
            return nil
        }
        let size = model.renderer.size
        let w = max(1, Int(size.width * ratio))
        if let proxy, abs(proxy.width - w) <= max(2, w / 40) { return proxy.image }
        let h = max(1, Int(size.height * ratio))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: model.renderer.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(model.renderer.base, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { return nil }
        proxy = (image, w)
        return image
    }

    private func drawSelection(_ ctx: CGContext, _ l: Layout) {
        guard let selected = model.annotation(model.selection), selected.id != textEdit?.id else { return }
        switch selected.shape {
        case .arrow:
            break
        case .blur(let b):
            drawDashedBox(viewRect(b.rect, l), ctx)
        case .text:
            drawDashedBox(viewRect(selected.bounds, l).insetBy(dx: -8, dy: -4), ctx)
        }
        for handle in selected.handles { drawHandle(at: viewPoint(handle.point, l), ctx) }
    }

    private func drawDashedBox(_ rect: CGRect, _ ctx: CGContext) {
        let r = rect.integral.insetBy(dx: 0.75, dy: 0.75)
        ctx.saveGState()
        // A light line under dark dashes stays visible on any background.
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        ctx.stroke(r)
        ctx.setStrokeColor(NSColor.zWindow.cgColor)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.stroke(r)
        ctx.restoreGState()
    }

    private func drawHandle(at p: CGPoint, _ ctx: CGContext) {
        let r = CGRect(x: p.x.rounded() - 4.5, y: p.y.rounded() - 4.5, width: 9, height: 9).insetBy(dx: 0.75, dy: 0.75)
        ctx.saveGState()
        ctx.setFillColor(NSColor.zInk.cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(NSColor.zAccent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(r)
        ctx.restoreGState()
    }

    private func cropHandlePoints(_ r: CGRect) -> [CGPoint] {
        [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
        ]
    }

    private func drawCropFrame(_ ctx: CGContext, _ l: Layout) {
        let frame = viewRect(model.state.crop, l)
        ctx.saveGState()
        ctx.addRect(l.sceneRect)
        ctx.addRect(frame)
        ctx.setFillColor(NSColor.zScrim.cgColor)
        ctx.fillPath(using: .evenOdd)

        if drag != nil, frame.width > 30, frame.height > 30 {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
            ctx.setLineWidth(1)
            for i in 1...2 {
                let x = (frame.minX + frame.width * CGFloat(i) / 3).rounded() + 0.5
                let y = (frame.minY + frame.height * CGFloat(i) / 3).rounded() + 0.5
                ctx.move(to: CGPoint(x: x, y: frame.minY)); ctx.addLine(to: CGPoint(x: x, y: frame.maxY))
                ctx.move(to: CGPoint(x: frame.minX, y: y)); ctx.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            ctx.strokePath()
        }
        ctx.setStrokeColor(NSColor.zAccent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(frame.insetBy(dx: -0.75, dy: -0.75))
        ctx.restoreGState()
        for p in cropHandlePoints(frame) { drawHandle(at: p, ctx) }
    }

    // MARK: Pointer

    override func resetCursorRects() {
        let cursor: NSCursor
        switch model.tool {
        case .arrow, .blur, .crop: cursor = .crosshair
        case .text: cursor = .iBeam
        case .border: cursor = .arrow
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if textEdit != nil {
            // The first click away from text being typed just finishes it.
            commitText()
            window?.makeFirstResponder(self)
            return
        }
        window?.makeFirstResponder(self)
        let l = layoutInfo
        let p = imagePoint(v, l)

        if model.tool == .crop {
            beginCropDrag(at: v, p, l)
            return
        }

        let slop = 7 / l.zoom
        if let selected = model.annotation(model.selection) {
            for handle in selected.handles where hypot(handle.point.x - p.x, handle.point.y - p.y) <= slop * 1.3 {
                model.beginGesture()
                switch (selected.shape, handle.handle) {
                case (.blur(let b), .corner(let i)):
                    drag = .blurRect(selected.id, anchor: b.rect.corners[(i + 2) % 4], isNew: false)
                default:
                    drag = .arrowEnd(selected.id, handle.handle)
                }
                return
            }
        }

        if let hit = model.state.annotations.last(where: { model.tool.grabs($0.shape) && $0.hitTest(p, tolerance: slop) }) {
            model.selection = hit.id
            if event.clickCount >= 2, case .text = hit.shape {
                beginTextEdit(id: hit.id, isNew: false)
                return
            }
            model.beginGesture()
            drag = .move(hit.id, last: p)
            return
        }

        switch model.tool {
        case .arrow:
            let arrow = Annotation(shape: .arrow(ArrowShape(
                start: p, end: p, color: model.arrowColor, thickness: CGFloat(model.arrowThickness) * model.scale
            )))
            model.selection = nil
            model.beginGesture()
            model.apply { $0.annotations.append(arrow) }
            drag = .newArrow(arrow.id)
        case .blur:
            let start = clamped(p)
            let blur = Annotation(shape: .blur(BlurShape(
                rect: CGRect(origin: start, size: .zero), style: model.blurStyle,
                strength: CGFloat(model.blurStrength) * model.scale
            )))
            model.selection = nil
            model.beginGesture()
            model.apply { $0.annotations.append(blur) }
            drag = .blurRect(blur.id, anchor: start, isNew: true)
        case .text:
            guard model.state.crop.contains(p) else {
                model.selection = nil
                return
            }
            let size = CGFloat(model.textSize) * model.scale
            let line = TextLayout.size(of: TextShape(origin: .zero, text: " ", color: model.textColor, fontSize: size)).height
            let shape = TextShape(origin: CGPoint(x: p.x, y: p.y - line / 2), text: "", color: model.textColor, fontSize: size)
            beginTextEdit(id: UUID(), isNew: true, shape: shape)
        case .border, .crop:
            model.selection = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let l = layoutInfo
        let p = imagePoint(convert(event.locationInWindow, from: nil), l)
        let constrain = event.modifierFlags.contains(.shift)

        switch drag {
        case .newArrow(let id):
            model.apply { s in
                guard let i = s.index(of: id), case .arrow(var a) = s.annotations[i].shape else { return }
                a.end = constrain ? snapTo45(p, from: a.start) : p
                s.annotations[i].shape = .arrow(a)
            }
        case .arrowEnd(let id, let handle):
            model.apply { s in
                guard let i = s.index(of: id), case .arrow(let a) = s.annotations[i].shape else { return }
                let anchor = handle == .arrowStart ? a.end : a.start
                s.annotations[i].move(handle, to: constrain ? snapTo45(p, from: anchor) : p)
            }
        case .blurRect(let id, let anchor, _):
            let rect = CGRect(corner: anchor, opposite: clamped(p))
            model.apply { s in
                guard let i = s.index(of: id), case .blur(var b) = s.annotations[i].shape else { return }
                b.rect = rect
                s.annotations[i].shape = .blur(b)
            }
        case .move(let id, let last):
            model.apply { s in
                if let i = s.index(of: id) {
                    s.annotations[i].translate(by: CGSize(width: p.x - last.x, height: p.y - last.y))
                }
            }
            self.drag = .move(id, last: p)
        case .cropMove(let offset):
            let b = model.imageBounds
            var r = model.state.crop
            r.origin.x = min(max(p.x - offset.width, b.minX), b.maxX - r.width)
            r.origin.y = min(max(p.y - offset.height, b.minY), b.maxY - r.height)
            model.apply { $0.crop = r }
        case .cropEdges(let edges, let original):
            let q = clamped(p)
            var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
            if edges.contains(.left) { minX = q.x }
            if edges.contains(.right) { maxX = q.x }
            if edges.contains(.top) { minY = q.y }
            if edges.contains(.bottom) { maxY = q.y }
            let r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
            model.apply { $0.crop = r }
        case .cropNew(let anchor):
            let r = CGRect(corner: anchor, opposite: clamped(p))
            model.apply { $0.crop = r }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        needsDisplay = true
        let minimum = 4 * model.scale

        switch drag {
        case .newArrow(let id):
            if case .arrow(let a)? = model.annotation(id)?.shape, a.length >= minimum {
                model.endGesture()
                model.selection = id
            } else {
                model.cancelGesture()  // a click, not a drag: nothing to keep
            }
        case .blurRect(let id, _, let isNew):
            guard case .blur(let b)? = model.annotation(id)?.shape else { return model.cancelGesture() }
            let rect = b.rect.pixelAligned(within: model.imageBounds)
            if b.rect.width >= minimum, b.rect.height >= minimum {
                model.apply { s in
                    guard let i = s.index(of: id), case .blur(var blur) = s.annotations[i].shape else { return }
                    blur.rect = rect
                    s.annotations[i].shape = .blur(blur)
                }
                model.endGesture()
                model.selection = id
            } else {
                model.cancelGesture()
                if isNew { model.selection = nil }
            }
        case .move, .arrowEnd:
            model.endGesture()
        case .cropMove, .cropEdges, .cropNew:
            let crop = model.state.crop
            if crop.width >= 8, crop.height >= 8 {
                let aligned = crop.pixelAligned(within: model.imageBounds)
                model.apply { $0.crop = aligned }
                model.endGesture()
            } else {
                model.cancelGesture()
            }
        }
    }

    private func beginCropDrag(at v: CGPoint, _ p: CGPoint, _ l: Layout) {
        let crop = model.state.crop
        let frame = viewRect(crop, l)
        let reach: CGFloat = 8
        var edges: Edges = []
        if frame.insetBy(dx: -reach, dy: -reach).contains(v) {
            if abs(v.x - frame.minX) <= reach { edges.insert(.left) }
            if abs(v.x - frame.maxX) <= reach { edges.insert(.right) }
            if abs(v.y - frame.minY) <= reach { edges.insert(.top) }
            if abs(v.y - frame.maxY) <= reach { edges.insert(.bottom) }
        }
        model.beginGesture()
        if !edges.isEmpty {
            drag = .cropEdges(edges, original: crop)
        } else if frame.contains(v) {
            drag = .cropMove(offset: CGSize(width: p.x - crop.minX, height: p.y - crop.minY))
        } else {
            drag = .cropNew(anchor: clamped(p))
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = flags.contains(.shift) ? 10 * model.scale : model.scale
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            if model.selection != nil { return model.deleteSelection() }
        case kVK_Escape:
            if model.tool == .crop { model.leaveCrop() } else { model.selection = nil }
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if model.tool == .crop { return model.leaveCrop() }
        case kVK_LeftArrow where model.selection != nil:
            return model.nudgeSelection(dx: -step, dy: 0)
        case kVK_RightArrow where model.selection != nil:
            return model.nudgeSelection(dx: step, dy: 0)
        case kVK_UpArrow where model.selection != nil:
            return model.nudgeSelection(dx: 0, dy: -step)
        case kVK_DownArrow where model.selection != nil:
            return model.nudgeSelection(dx: 0, dy: step)
        default:
            break
        }
        if flags.isDisjoint(with: [.command, .control, .option]),
           let typed = event.charactersIgnoringModifiers?.lowercased(),
           let tool = EditorTool.allCases.first(where: { $0.key == typed }) {
            model.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Typing text

    private func beginTextEdit(id: UUID, isNew: Bool, shape: TextShape? = nil) {
        let existing: TextShape? = {
            if case .text(let t)? = model.annotation(id)?.shape { return t }
            return nil
        }()
        guard let shape = shape ?? existing else { return }

        let view = NSTextView(frame: .zero)
        view.isRichText = false
        view.drawsBackground = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = CGSize(width: 100_000, height: 100_000)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.maxSize = CGSize(width: 100_000, height: 100_000)
        view.string = shape.text
        view.delegate = self
        addSubview(view)

        textEdit = TextEdit(id: id, isNew: isNew, shape: shape, view: view)
        if isNew { model.selection = nil }
        layoutTextEditor()
        window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (shape.text as NSString).length, length: 0))
        needsDisplay = true
    }

    /// Keeps the text field over the spot, and at the size, its text will render at.
    private func layoutTextEditor() {
        guard let edit = textEdit else { return }
        let l = layoutInfo
        let font = TextLayout.font(size: edit.shape.fontSize * l.zoom)
        let color = NSColor(edit.shape.color)
        edit.view.font = font
        edit.view.textColor = color
        edit.view.insertionPointColor = color
        edit.view.typingAttributes = [.font: font, .foregroundColor: color]
        guard let manager = edit.view.layoutManager, let container = edit.view.textContainer else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let extra = manager.extraLineFragmentRect
        let line = manager.defaultLineHeight(for: font)
        let origin = viewPoint(edit.shape.origin, l)
        edit.view.frame = CGRect(
            x: origin.x, y: origin.y,
            width: max(ceil(used.width) + 8, 16),
            height: max(ceil(max(used.maxY, extra.maxY)), ceil(line))
        )
    }

    private func commitText() {
        guard let edit = textEdit else { return }
        textEdit = nil
        var text = edit.view.string
        while let last = text.last, last.isWhitespace || last.isNewline { text.removeLast() }
        edit.view.delegate = nil
        edit.view.removeFromSuperview()

        var shape = edit.shape
        shape.text = text
        if edit.isNew {
            if !text.isEmpty {
                let annotation = Annotation(id: edit.id, shape: .text(shape))
                model.apply { $0.annotations.append(annotation) }
                model.selection = annotation.id
            }
        } else if text.isEmpty {
            model.selection = nil
            model.apply { $0.annotations.removeAll { $0.id == edit.id } }
        } else {
            model.apply { s in
                if let i = s.index(of: edit.id) { s.annotations[i].shape = .text(shape) }
            }
        }
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        layoutTextEditor()
        needsDisplay = true
    }

    func textDidEndEditing(_ notification: Notification) {
        commitText()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        commitText()
        window?.makeFirstResponder(self)
        return true
    }

    /// Finishes any text being typed, so it is part of what gets saved or copied.
    func finishEditing() {
        commitText()
    }

    // MARK: Edit menu

    // The text field's commands pass through here on their way up the responder
    // chain, so undo has to tell typing apart from editing the capture.

    @objc func undo(_ sender: Any?) {
        if let edit = textEdit { edit.view.undoManager?.undo() } else { model.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if let edit = textEdit { edit.view.undoManager?.redo() } else { model.redo() }
    }

    @objc func copy(_ sender: Any?) {
        model.copyToClipboard()
    }

    @objc func delete(_ sender: Any?) {
        model.deleteSelection()
    }
}

extension CanvasView: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            return textEdit?.view.undoManager?.canUndo ?? model.canUndo
        case #selector(redo(_:)):
            return textEdit?.view.undoManager?.canRedo ?? model.canRedo
        case #selector(delete(_:)):
            return model.selection != nil
        default:
            return true
        }
    }
}
