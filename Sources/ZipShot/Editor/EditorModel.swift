import AppKit
import Combine
import ZipShotCore

enum EditorTool: String, CaseIterable, Identifiable {
    case crop, border, arrow, text, blur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crop: return "Crop"
        case .border: return "Border"
        case .arrow: return "Arrow"
        case .text: return "Text"
        case .blur: return "Pixel blur"
        }
    }

    var icon: ZIcon.Kind {
        switch self {
        case .crop: return .crop
        case .border: return .border
        case .arrow: return .arrow
        case .text: return .text
        case .blur: return .pixels
        }
    }

    /// Single-key shortcut while the canvas has focus.
    var key: String {
        switch self {
        case .crop: return "c"
        case .border: return "b"
        case .arrow: return "a"
        case .text: return "t"
        case .blur: return "p"
        }
    }

    static func matching(_ shape: Shape) -> EditorTool {
        switch shape {
        case .arrow: return .arrow
        case .text: return .text
        case .blur: return .blur
        }
    }

    /// Whether a click with this tool picks up an existing annotation. Drawing
    /// tools only grab their own kind, so an arrow can start on top of a blur.
    func grabs(_ shape: Shape) -> Bool {
        switch self {
        case .crop: return false
        case .border: return true
        default: return self == Self.matching(shape)
        }
    }
}

/// Everything one editor window knows: the capture, the edits made to it, the
/// current tool and its settings, undo history, and saving.
///
/// Edits are written back to the capture's file on the Desktop automatically.
@MainActor
final class EditorModel: ObservableObject {
    let item: CaptureItem
    let renderer: Renderer
    /// Display scale of the capture (2 on Retina). Tool sizes are kept in
    /// points and multiplied by this, so they look the same on any display.
    let scale: CGFloat

    @Published private(set) var state: EditState
    @Published var tool: EditorTool = .arrow {
        didSet { if tool != oldValue { toolChanged(from: oldValue) } }
    }
    @Published var selection: UUID? {
        didSet { if selection != oldValue { adoptSelectionStyle() } }
    }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var saveError: String?
    @Published private(set) var justCopied = false

    @Published private(set) var arrowColor: RGBAColor
    @Published private(set) var arrowThickness: Double
    @Published private(set) var textColor: RGBAColor
    @Published private(set) var textSize: Double
    @Published private(set) var blurStyle: BlurStyle
    @Published private(set) var blurStrength: Double

    private(set) var previousTool: EditorTool = .arrow
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private var gestureStart: EditState?
    private var savedState: EditState
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "zipshot.editor.save", qos: .userInitiated)
    private let prefs = Prefs.shared

    init(item: CaptureItem, renderer: Renderer) {
        self.item = item
        self.renderer = renderer
        scale = max(1, item.scale)

        arrowColor = prefs.color("arrowColor", default: Theme.annotationRed)
        arrowThickness = prefs.number("arrowThickness", default: 4)
        textColor = prefs.color("textColor", default: Theme.annotationRed)
        textSize = prefs.number("textSize", default: 20)
        blurStyle = BlurStyle(rawValue: prefs.string("blurStyle") ?? "") ?? .pixelate
        blurStrength = prefs.number("blurStrength", default: 10)

        let initial: EditState
        if let existing = item.editState {
            initial = existing
        } else {
            // A new capture has no border until one is asked for, but remembers
            // how the last one looked.
            var fresh = EditState(imageSize: renderer.size)
            fresh.border = Border(
                fill: BorderFill(rawValue: prefs.string("borderFill") ?? "") ?? .color,
                color: prefs.color("borderColor", default: Theme.accentRGBA),
                thickness: 0,
                blurStrength: prefs.number("borderBlur", default: 40)
            )
            initial = fresh
        }
        state = initial
        savedState = initial
    }

    var outputSize: CGSize { renderer.outputSize(for: state) }
    var imageBounds: CGRect { renderer.bounds }

    func annotation(_ id: UUID?) -> Annotation? {
        guard let id else { return nil }
        return state.annotations.first { $0.id == id }
    }

    // MARK: Changing the edit state

    /// Starts a continuous change (a drag, a slider) that should undo as one step.
    func beginGesture() {
        if gestureStart == nil { gestureStart = state }
    }

    func endGesture() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        if start != state {
            pushUndo(start)
            scheduleSave()
        }
    }

    /// Abandons the running gesture, putting everything back as it was.
    func cancelGesture() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        if state != start { state = start }
    }

    /// Makes a change: its own undo step, or part of the running gesture.
    func apply(_ change: (inout EditState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        if gestureStart == nil { pushUndo(state) }
        state = next
        if gestureStart == nil { scheduleSave() }
    }

    private func pushUndo(_ previous: EditState) {
        undoStack.append(previous)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshUndoFlags()
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        cancelGesture()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        restore(previous)
    }

    func redo() {
        cancelGesture()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        restore(next)
    }

    private func restore(_ target: EditState) {
        state = target
        if let selection, target.index(of: selection) == nil { self.selection = nil }
        refreshUndoFlags()
        scheduleSave()
    }

    func deleteSelection() {
        guard let id = selection else { return }
        selection = nil
        apply { $0.annotations.removeAll { $0.id == id } }
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let id = selection else { return }
        apply { s in
            if let i = s.index(of: id) { s.annotations[i].translate(by: CGSize(width: dx, height: dy)) }
        }
    }

    // MARK: Tools and their settings

    private func toolChanged(from old: EditorTool) {
        if old != .crop { previousTool = old }
        if let selected = annotation(selection), !tool.grabs(selected.shape) || tool == .border {
            selection = nil
        }
    }

    func leaveCrop() {
        if tool == .crop { tool = previousTool }
    }

    /// Selecting something shows its settings and switches to its tool.
    private func adoptSelectionStyle() {
        guard let selected = annotation(selection) else { return }
        switch selected.shape {
        case .arrow(let a):
            arrowColor = a.color
            arrowThickness = Double(a.thickness / scale)
        case .text(let t):
            textColor = t.color
            textSize = Double(t.fontSize / scale)
        case .blur(let b):
            blurStyle = b.style
            blurStrength = Double(b.strength / scale)
        }
        let matching = EditorTool.matching(selected.shape)
        if tool != matching { tool = matching }
    }

    private func updateSelected(_ change: (inout Shape) -> Void) {
        guard let id = selection else { return }
        apply { s in
            if let i = s.index(of: id) { change(&s.annotations[i].shape) }
        }
    }

    func setArrowColor(_ color: RGBAColor) {
        arrowColor = color
        prefs.setColor(color, "arrowColor")
        updateSelected { if case .arrow(var a) = $0 { a.color = color; $0 = .arrow(a) } }
    }

    func setArrowThickness(_ points: Double) {
        arrowThickness = points
        prefs.setNumber(points, "arrowThickness")
        updateSelected { if case .arrow(var a) = $0 { a.thickness = CGFloat(points) * self.scale; $0 = .arrow(a) } }
    }

    func setTextColor(_ color: RGBAColor) {
        textColor = color
        prefs.setColor(color, "textColor")
        updateSelected { if case .text(var t) = $0 { t.color = color; $0 = .text(t) } }
    }

    func setTextSize(_ points: Double) {
        textSize = points
        prefs.setNumber(points, "textSize")
        updateSelected { if case .text(var t) = $0 { t.fontSize = CGFloat(points) * self.scale; $0 = .text(t) } }
    }

    func setBlurStyle(_ style: BlurStyle) {
        blurStyle = style
        prefs.setString(style.rawValue, "blurStyle")
        updateSelected { if case .blur(var b) = $0 { b.style = style; $0 = .blur(b) } }
    }

    func setBlurStrength(_ points: Double) {
        blurStrength = points
        prefs.setNumber(points, "blurStrength")
        updateSelected { if case .blur(var b) = $0 { b.strength = CGFloat(points) * self.scale; $0 = .blur(b) } }
    }

    /// Picking a fill or color with no border yet gives it a visible thickness.
    private var starterThickness: CGFloat { 24 * scale }

    func setBorderFill(_ fill: BorderFill) {
        prefs.setString(fill.rawValue, "borderFill")
        apply {
            $0.border.fill = fill
            if $0.border.thickness <= 0 { $0.border.thickness = starterThickness }
        }
    }

    func setBorderColor(_ color: RGBAColor) {
        prefs.setColor(color, "borderColor")
        prefs.setString(BorderFill.color.rawValue, "borderFill")
        apply {
            $0.border.color = color
            $0.border.fill = .color
            if $0.border.thickness <= 0 { $0.border.thickness = starterThickness }
        }
    }

    func setBorderThickness(_ pixels: Double) {
        apply { $0.border.thickness = CGFloat(pixels) }
    }

    func setBorderBlur(_ strength: Double) {
        prefs.setNumber(strength, "borderBlur")
        apply { $0.border.blurStrength = CGFloat(strength) }
    }

    func resetCrop() {
        apply { $0.crop = imageBounds }
    }

    // MARK: Saving and copying

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save(wait: false) }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes any unsaved edits now and waits for the file. Used when the window closes.
    func flush() {
        cancelGesture()
        save(wait: true)
    }

    private func save(wait: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = state
        guard snapshot != savedState else {
            if wait { saveQueue.sync {} }
            return
        }
        savedState = snapshot

        let renderer = self.renderer
        let url = item.url
        let scale = self.scale
        let work: () -> Result<CGImage, Error> = {
            guard let image = renderer.render(snapshot), let data = PNGWriter.data(for: image, scale: scale) else {
                return .failure(CocoaError(.fileWriteUnknown))
            }
            do {
                try data.write(to: url, options: .atomic)
                return .success(image)
            } catch {
                return .failure(error)
            }
        }
        if wait {
            finishSave(saveQueue.sync(execute: work), snapshot: snapshot)
        } else {
            saveQueue.async {
                let result = work()
                DispatchQueue.main.async { self.finishSave(result, snapshot: snapshot) }
            }
        }
    }

    private func finishSave(_ result: Result<CGImage, Error>, snapshot: EditState) {
        switch result {
        case .success(let image):
            saveError = nil
            item.editState = snapshot
            item.pixelSize = CGSize(width: image.width, height: image.height)
            item.thumbnail = Thumbnail.make(from: image)
        case .failure(let error):
            saveError = error.localizedDescription
            savedState = EditState(imageSize: .zero)  // so the next change retries
        }
    }

    func copyToClipboard() {
        let snapshot = state
        let renderer = self.renderer
        let scale = self.scale
        saveQueue.async {
            guard let image = renderer.render(snapshot), let data = PNGWriter.data(for: image, scale: scale) else { return }
            DispatchQueue.main.async {
                Clipboard.copy(png: data, image: image)
                self.justCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.justCopied = false }
            }
        }
    }
}
