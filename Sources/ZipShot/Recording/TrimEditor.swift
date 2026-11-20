import AppKit
import Carbon.HIToolbox
import SwiftUI
import ZipShotCore

/// Trimming a recording: where it starts and ends, previewing, and saving.
/// The original frames are kept, so a saved trim can still be changed.
@MainActor
final class TrimModel: ObservableObject {
    let item: CaptureItem
    let frames: FrameStore
    let duration: TimeInterval

    @Published private(set) var start: TimeInterval
    @Published private(set) var end: TimeInterval
    @Published private(set) var playhead: TimeInterval
    @Published private(set) var isPlaying = false
    @Published private(set) var frameImage: CGImage?
    @Published private(set) var thumbnails: [CGImage?]
    @Published private(set) var isSaving = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var justSaved = false
    @Published private(set) var errorText: String?

    static let thumbnailCount = 16
    /// Off only for automated checks, which must leave the clipboard alone.
    var copiesAfterSaving = true
    private var shownFrame = -1
    private var timer: Timer?
    private var lastTick: TimeInterval = 0

    init(item: CaptureItem, frames: FrameStore) {
        self.item = item
        self.frames = frames
        duration = max(frames.duration, 0.01)
        let range = item.trim ?? 0...max(frames.duration, 0.01)
        start = range.lowerBound
        end = min(range.upperBound, max(frames.duration, 0.01))
        playhead = range.lowerBound
        thumbnails = [CGImage?](repeating: nil, count: Self.thumbnailCount)
        show(playhead)
        loadThumbnails()
    }

    var isTrimmed: Bool { start > 0.0001 || end < duration - 0.0001 }
    var length: TimeInterval { end - start }

    /// True when Start/End differ from what is in the file on the Desktop.
    var hasUnsavedTrim: Bool {
        let saved = item.trim ?? 0...duration
        return abs(saved.lowerBound - start) > 0.0001 || abs(saved.upperBound - end) > 0.0001
    }

    private func show(_ time: TimeInterval) {
        let index = frames.frameIndex(at: time)
        guard index != shownFrame else { return }
        shownFrame = index
        frameImage = frames.image(at: index)
    }

    private func loadThumbnails() {
        let frames = self.frames
        let duration = self.duration
        let count = Self.thumbnailCount
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for i in 0..<count {
                let time = (Double(i) + 0.5) / Double(count) * duration
                guard let full = frames.image(at: frames.frameIndex(at: time)) else { continue }
                let scale = min(1, 112 / CGFloat(full.height))
                let w = max(1, Int(CGFloat(full.width) * scale))
                let h = max(1, Int(CGFloat(full.height) * scale))
                guard let ctx = CGContext(
                    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { continue }
                ctx.interpolationQuality = .medium
                ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
                let small = ctx.makeImage()
                DispatchQueue.main.async { self?.thumbnails[i] = small }
            }
        }
    }

    // MARK: Editing

    /// `minLength` keeps the two handles from crossing.
    func setStart(_ time: TimeInterval, minLength: TimeInterval) {
        pause()
        start = min(max(0, time), max(0, end - minLength))
        playhead = start
        show(playhead)
    }

    func setEnd(_ time: TimeInterval, minLength: TimeInterval) {
        pause()
        end = max(min(duration, time), min(duration, start + minLength))
        playhead = end
        // Preview the last frame that will be kept.
        show(max(start, end - 0.001))
    }

    func scrub(to time: TimeInterval) {
        pause()
        playhead = min(max(time, start), end)
        show(min(playhead, max(start, end - 0.001)))
    }

    func reset() {
        pause()
        start = 0
        end = duration
        playhead = 0
        show(0)
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    private func play() {
        guard !isSaving else { return }
        if playhead >= end - 0.01 || playhead < start { playhead = start }
        isPlaying = true
        lastTick = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var next = playhead + (now - lastTick)
        lastTick = now
        if next >= end { next = start }  // loops, as the GIF will
        playhead = next
        show(next)
    }

    // MARK: Saving

    func save() {
        guard !isSaving else { return }
        pause()
        isSaving = true
        progress = 0
        errorText = nil
        let range = start...end
        let frames = self.frames
        let url = item.url
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    var last = 0.0
                    try GIFExporter.export(store: frames, range: range, to: url) { fraction in
                        if fraction - last >= 0.02 || fraction >= 1 {
                            last = fraction
                            DispatchQueue.main.async { self.progress = fraction }
                        }
                        return true
                    }
                }.value
                item.trim = range
                if let first = frames.image(at: frames.frameIndex(at: range.lowerBound)) {
                    item.thumbnail = Thumbnail.make(from: first)
                }
                if copiesAfterSaving { Clipboard.copy(gifAt: url) }
                justSaved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.justSaved = false }
            } catch {
                errorText = (error as? GIFError)?.description ?? error.localizedDescription
            }
            isSaving = false
        }
    }
}

func trimTimeLabel(_ t: TimeInterval) -> String {
    let tenths = Int((max(0, t) * 10).rounded())
    return String(format: "%02d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
}

struct TrimView: View {
    @ObservedObject var model: TrimModel
    var titlebarHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip(title: model.item.fileName, height: titlebarHeight).hairline(.bottom)
            preview
            controls
        }
        .background(Theme.window)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var preview: some View {
        ZStack {
            Theme.window
            if let image = model.frameImage {
                let scale = max(1, model.item.scale)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: CGFloat(image.width) / scale, maxHeight: CGFloat(image.height) / scale)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 12)
                    .padding(32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Button { model.togglePlay() } label: {
                    ZIcon(kind: model.isPlaying ? .pause : .play, size: 14)
                        .offset(x: model.isPlaying ? 0 : 1)
                        .foregroundStyle(Theme.window)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.text))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Play the trimmed clip (Space)")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play trimmed clip")

                HStack(spacing: 20) {
                    stat("Start", trimTimeLabel(model.start))
                    stat("End", trimTimeLabel(model.end))
                    stat("Length", String(format: "%.1f s of %.1f s", model.length, model.duration))
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button("Reset") { model.reset() }
                        .buttonStyle(ZButtonStyle(kind: .outlined, padding: 14))
                        .disabled(!model.isTrimmed || model.isSaving)
                    Button(saveTitle) { model.save() }
                        .buttonStyle(ZButtonStyle(kind: .accent, padding: 16))
                        .disabled(model.isSaving)
                }
            }
            .font(.system(size: 13))

            TrimTimeline(model: model)

            HStack {
                if let error = model.errorText {
                    Text("Couldn't save: \(error)").foregroundStyle(Theme.record)
                } else {
                    Text("Full recording already saved to Desktop. Saving replaces it with the trimmed clip.")
                }
                Spacer(minLength: 8)
                Text(verbatim: "\(model.frames.width) × \(model.frames.height) · GIF").font(Theme.mono(12))
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .background(Theme.panel)
        .hairline(.top)
    }

    private var saveTitle: String {
        if model.isSaving { return "Saving… \(Int(model.progress * 100))%" }
        return model.justSaved ? "Saved and copied" : "Save and copy"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Theme.muted)
            Text(value).font(Theme.mono(13)).foregroundStyle(Theme.text)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The filmstrip with its draggable start and end handles and the playhead.
struct TrimTimeline: View {
    @ObservedObject var model: TrimModel
    @State private var target: Target?

    private enum Target { case start, end, scrub }
    private let handle: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let xs = CGFloat(model.start / model.duration) * width
            let xe = CGFloat(model.end / model.duration) * width
            let xp = CGFloat(model.playhead / model.duration) * width
            // Enough time between the handles that they never overlap on screen.
            let minLength = min(model.duration, max(0.1, Double((handle * 2 + 6) / width) * model.duration))

            let count = TrimModel.thumbnailCount
            let cell = max(1, (width - CGFloat(count - 1) * 2) / CGFloat(count))

            ZStack(alignment: .topLeading) {
                HStack(spacing: 2) {
                    ForEach(0..<count, id: \.self) { i in
                        ZStack {
                            Color(hex: i % 2 == 0 ? 0x5B5F67 : 0x666A72)
                            if let image = model.thumbnails[i] {
                                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(width: cell, height: 56)
                        .clipped()
                    }
                }
                .frame(width: width, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .offset(y: 4)

                Color(hex: 0x1E1F22, opacity: 0.75)
                    .frame(width: max(0, xs + 8), height: 56)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6))
                    .offset(y: 4)
                Color(hex: 0x1E1F22, opacity: 0.75)
                    .frame(width: max(0, width - xe + 8), height: 56)
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6))
                    .offset(x: xe - 8, y: 4)

                TrimFrame(handle: handle)
                    .fill(Theme.accent, style: FillStyle(eoFill: true))
                    .frame(width: max(handle * 2, xe - xs), height: 64)
                    .offset(x: xs)
                grip.offset(x: xs + (handle - 2) / 2, y: 22)
                grip.offset(x: xe - handle + (handle - 2) / 2, y: 22)

                Capsule()
                    .fill(Theme.text)
                    .frame(width: 2, height: 72)
                    .offset(x: min(max(xp, 0), width) - 1, y: -4)
                    .opacity(xp > xs + handle && xp < xe - handle ? 1 : 0)
            }
            .frame(width: width, height: 64, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if target == nil {
                            let toStart = abs(g.startLocation.x - (xs + handle / 2))
                            let toEnd = abs(g.startLocation.x - (xe - handle / 2))
                            if min(toStart, toEnd) <= handle {
                                target = toStart <= toEnd ? .start : .end
                            } else {
                                target = .scrub
                            }
                        }
                        let time = Double(g.location.x / width) * model.duration
                        let half = Double(handle / 2 / width) * model.duration
                        switch target {
                        case .start: model.setStart(time - half, minLength: minLength)
                        case .end: model.setEnd(time + half, minLength: minLength)
                        case .scrub: model.scrub(to: time)
                        case nil: break
                        }
                    }
                    .onEnded { _ in target = nil }
            )
        }
        .frame(height: 64)
        .accessibilityElement()
        .accessibilityLabel("Trim range")
        .accessibilityValue("\(trimTimeLabel(model.start)) to \(trimTimeLabel(model.end))")
    }

    private var grip: some View {
        Capsule().fill(Theme.onAccent).frame(width: 2, height: 20)
    }
}

/// The accent frame around the kept range: thin top and bottom, thick ends to grab.
private struct TrimFrame: SwiftUI.Shape {
    let handle: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 8)
        let inner = rect.insetBy(dx: handle, dy: 3)
        if inner.width > 0 { path.addRoundedRect(in: inner, cornerSize: CGSize(width: 3, height: 3)) }
        return path
    }
}

@MainActor
final class TrimWindowController: NSWindowController, NSWindowDelegate {
    let model: TrimModel
    private var keyMonitor: Any?

    init(item: CaptureItem, frames: FrameStore) {
        model = TrimModel(item: item, frames: frames)
        let scale = max(1, item.scale)
        let natural = CGSize(width: CGFloat(frames.width) / scale, height: CGFloat(frames.height) / scale)
        let screen = NSScreen.underMouse.visibleFrame
        let content = CGSize(
            width: min(max(natural.width + 64, 900), screen.width * 0.9),
            height: min(max(natural.height + 64 + 230, 600), screen.height * 0.9)
        )
        let window = ZWindow.make(title: item.fileName, contentSize: content, minSize: CGSize(width: 760, height: 480))
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: TrimView(model: model, titlebarHeight: window.titlebarHeight))

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.window, Int(event.keyCode) == kVK_Space,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
                else { return false }
                self.model.togglePlay()
                return true
            }
            return handled ? nil : event
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        model.pause()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        EditorWindows.closed(model.item)
    }
}
