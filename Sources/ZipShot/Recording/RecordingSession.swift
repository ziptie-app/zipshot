import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI
import ZipShotCore

/// One GIF recording, from the chosen region to the saved file: the frame
/// around the region, the Start / Pause / Stop bar, and the recorder itself.
@MainActor
final class RecordingSession: ObservableObject {
    enum Phase { case ready, starting, recording, paused, saving }

    @Published private(set) var phase: Phase
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var progress: Double = 0

    /// In global screen coordinates (origin bottom-left).
    let region: CGRect
    let screen: NSScreen
    var onEnd: (() -> Void)?

    private let outputScale: CGFloat
    private var frameWindow: NSWindow?
    private var controlPanel: RecordingPanel?
    private var recorder: RegionRecorder?
    private var timer: Timer?

    init(region: CGRect, screen: NSScreen, phase: Phase = .ready) {
        self.region = region
        self.screen = screen
        self.phase = phase
        outputScale = Prefs.shared.gifRetina ? screen.backingScaleFactor : 1
    }

    /// Size of the GIF in pixels.
    var pixelSize: CGSize {
        CGSize(width: (region.width * outputScale).rounded(), height: (region.height * outputScale).rounded())
    }

    /// The region within its screen, measured from the top-left.
    var localRegion: CGRect {
        CGRect(x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY, width: region.width, height: region.height)
    }

    var hints: [Hint] {
        var hints: [Hint] = []
        if let shortcut = Prefs.shared.shortcutLabel(.record) { hints.append(Hint(key: shortcut, text: "start or stop")) }
        hints.append(Hint(key: "Space", text: "pause or resume"))
        hints.append(Hint(text: "Stop opens the trim editor", dimmed: true))
        return hints
    }

    // MARK: Windows

    func present() {
        // Dims everything but the region. Clicks pass straight through it, so
        // the apps underneath stay fully usable while recording.
        let frame = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        frame.setFrame(screen.frame, display: false)
        frame.level = .statusBar
        frame.isOpaque = false
        frame.backgroundColor = .clear
        frame.hasShadow = false
        frame.ignoresMouseEvents = true
        frame.isReleasedWhenClosed = false
        frame.animationBehavior = .none
        frame.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        frame.contentView = NSHostingView(rootView: RecordingFrameView(session: self))
        CaptureExclusion.add(frame)
        frame.orderFrontRegardless()
        frameWindow = frame

        let host = NSHostingView(rootView: RecordingControls(session: self))
        let size = CGSize(width: 420, height: 56)  // wide enough for every state; the bar centers itself
        let panel = RecordingPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.contentView = host
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        CaptureExclusion.add(panel)

        // Below the region if there is room, otherwise above it, otherwise inside.
        let area = screen.frame
        var y = region.minY - 16 - size.height
        if y < area.minY + 72 { y = region.maxY + 16 }
        if y + size.height > area.maxY - 30 { y = region.minY + 16 }
        let x = min(max(region.midX - size.width / 2, area.minX + 8), area.maxX - size.width - 8)
        panel.setFrameOrigin(CGPoint(x: x.rounded(), y: y.rounded()))
        panel.makeKeyAndOrderFront(nil)
        controlPanel = panel
        // The app we stepped in front of is taking focus back about now; take
        // the keyboard again so Space and Return reach the controls.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.phase == .ready else { return }
            self.controlPanel?.makeKey()
        }
    }

    /// Hands the keyboard back to the app being recorded. The controls take it
    /// again only when clicked, so typing lands where the user expects.
    private func yieldKeyboard() {
        guard let panel = controlPanel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch (Int(event.keyCode), phase) {
        case (kVK_Space, .recording), (kVK_Space, .paused):
            togglePause()
        case (kVK_Return, .ready), (kVK_ANSI_KeypadEnter, .ready):
            start()
        case (kVK_Escape, .ready):
            cancel()
        default:
            return false
        }
        return true
    }

    /// The global record shortcut while this session is up.
    func shortcutPressed() {
        switch phase {
        case .ready: start()
        case .recording, .paused: stop()
        case .starting, .saving: break
        }
    }

    // MARK: Recording

    func start() {
        guard phase == .ready else { return }
        phase = .starting
        Task { @MainActor in
            do {
                let content = try await ScreenGrab.content()
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                    throw CaptureError.displayNotFound
                }
                let filter = SCContentFilter(display: display, excludingWindows: CaptureExclusion.windows(in: content))
                let config = SCStreamConfiguration()
                config.sourceRect = localRegion
                config.width = Int(pixelSize.width)
                config.height = Int(pixelSize.height)
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, Prefs.shared.gifFPS)))
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = Prefs.shared.recordCursor
                config.colorSpaceName = CGColorSpace.sRGB
                config.queueDepth = 6

                let recorder = RegionRecorder()
                recorder.onInterrupted = { [weak self] in
                    MainActor.assumeIsolated { self?.stop() }
                }
                try await recorder.start(filter: filter, configuration: config)
                guard phase == .starting else {
                    _ = await recorder.stop()  // cancelled while starting
                    return
                }
                self.recorder = recorder
                phase = .recording
                yieldKeyboard()
                Sounds.recordStart()
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let recorder = self.recorder else { return }
                        self.elapsed = recorder.elapsed
                    }
                }
            } catch {
                finish()
                presentError(error, title: "ZipShot couldn't start recording")
            }
        }
    }

    func togglePause() {
        switch phase {
        case .recording:
            recorder?.pause()
            phase = .paused
        case .paused:
            recorder?.resume()
            phase = .recording
        default:
            break
        }
    }

    /// Stops, saves the whole recording to the Desktop, and opens it for trimming.
    func stop() {
        guard phase == .recording || phase == .paused, let recorder else { return }
        phase = .saving
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        let scale = outputScale
        Task { @MainActor in
            do {
                guard let frames = await recorder.stop(), frames.frameCount > 0 else { throw CaptureError.nothingRecorded }
                let url = CaptureNaming.uniqueURL(in: Library.desktop, ext: "gif")
                try await Task.detached(priority: .userInitiated) {
                    var last = 0.0
                    try GIFExporter.export(store: frames, to: url) { fraction in
                        if fraction - last >= 0.02 || fraction >= 1 {
                            last = fraction
                            DispatchQueue.main.async { self.progress = fraction }
                        }
                        return true
                    }
                }.value
                Sounds.recordEnd()
                let item = Library.shared.addRecording(frames: frames, url: url)
                item.scale = scale
                finish()
                EditorWindows.open(item)
            } catch {
                finish()
                presentError(error, title: "ZipShot couldn't save the recording")
            }
        }
    }

    /// Throws the recording away.
    func cancel() {
        guard phase != .saving else { return }
        let recorder = self.recorder
        self.recorder = nil
        if let recorder {
            Task { _ = await recorder.stop() }
        }
        finish()
    }

    private func finish() {
        phase = .ready
        timer?.invalidate()
        timer = nil
        // This often runs from a click on the controls themselves; keep the
        // windows (and this session) alive until that click has been handled.
        let closing: [NSWindow] = [frameWindow, controlPanel].compactMap { $0 }
        frameWindow = nil
        controlPanel = nil
        closing.forEach { $0.orderOut(nil) }
        DispatchQueue.main.async { [self] in _ = (closing, self) }
        let done = onEnd
        onEnd = nil
        done?()
    }
}

private final class RecordingPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Keys the controls don't use are dropped quietly rather than beeped at.
        _ = onKey?(event)
    }

    override func cancelOperation(_ sender: Any?) {}
}

// MARK: - Views

/// The dimmed screen with the region cut out, its dashed outline and size label.
struct RecordingFrameView: View {
    @ObservedObject var session: RecordingSession

    var body: some View {
        GeometryReader { geo in
            let hole = session.localRegion
            let size = session.pixelSize
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRect(hole)
                }
                .fill(Theme.scrim, style: FillStyle(eoFill: true))

                // Drawn just outside the region so it can never be part of the GIF.
                Rectangle()
                    .strokeBorder(
                        session.phase == .recording ? Theme.record : Theme.muted,
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .frame(width: hole.width + 4, height: hole.height + 4)
                    .offset(x: hole.minX - 2, y: hole.minY - 2)

                Text(verbatim: "\(Int(size.width)) × \(Int(size.height)) · GIF")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.ink))
                    .offset(x: hole.minX, y: hole.minY >= 40 ? hole.minY - 34 : hole.minY + 10)

                HintBar(hints: session.hints)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 28)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

/// The floating Start / Pause / Stop bar.
struct RecordingControls: View {
    @ObservedObject var session: RecordingSession

    var body: some View {
        HStack(spacing: 12) {
            switch session.phase {
            case .ready, .starting:
                Text(session.phase == .starting ? "Starting…" : "Ready to record").foregroundStyle(Theme.muted)
                Button { session.start() } label: {
                    HStack(spacing: 8) { ZIcon(kind: .dot, size: 12); Text("Start") }
                }
                .buttonStyle(ZButtonStyle(kind: .record, radius: 9, padding: 16))
                .disabled(session.phase == .starting)
                Button { session.cancel() } label: {
                    ZIcon(kind: .close, size: 14).frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text)
                .help("Cancel")
                .accessibilityLabel("Cancel recording")

            case .recording:
                Circle().fill(Theme.record).frame(width: 10, height: 10)
                timeLabel
                Button { session.togglePause() } label: {
                    HStack(spacing: 8) { ZIcon(kind: .pause, size: 12); Text("Pause") }
                }
                .buttonStyle(ZButtonStyle(kind: .outlined, radius: 9, padding: 14))
                stopButton

            case .paused:
                Circle().fill(Theme.idle).frame(width: 10, height: 10)
                timeLabel
                Text("Paused").foregroundStyle(Theme.muted)
                Button { session.togglePause() } label: {
                    HStack(spacing: 8) { ZIcon(kind: .play, size: 12); Text("Resume") }
                }
                .buttonStyle(ZButtonStyle(kind: .accent, radius: 9, padding: 14))
                stopButton

            case .saving:
                ProgressView().controlSize(.small)
                Text("Saving GIF… \(Int(session.progress * 100))%")
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                    .padding(.trailing, 8)
            }
        }
        .font(.system(size: 13))
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: 1))
        .fixedSize()
        .frame(maxWidth: .infinity)
        .preferredColorScheme(.dark)
    }

    private var timeLabel: some View {
        let seconds = Int(session.elapsed)
        return Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
            .font(Theme.mono(14))
            .foregroundStyle(Theme.text)
            .frame(minWidth: 52, alignment: .leading)
    }

    private var stopButton: some View {
        Button { session.stop() } label: {
            HStack(spacing: 8) { ZIcon(kind: .stop, size: 12); Text("Stop") }
        }
        .buttonStyle(ZButtonStyle(kind: .record, radius: 9, padding: 16))
    }
}
