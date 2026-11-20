import AppKit
import ZipShotCore

/// Runs the four capture actions, from shortcut or menu to saved file.
@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private var overlay: SelectionOverlay?
    private var busy = false
    private(set) var recording: RecordingSession?

    var isRecordingActive: Bool { recording != nil }

    func perform(_ action: CaptureAction) {
        switch action {
        case .region: beginScreenshotSelection(mode: .region)
        case .window: beginScreenshotSelection(mode: .window)
        case .screen: captureScreen()
        case .record: toggleRecording()
        }
    }

    // MARK: Screenshots

    private func beginScreenshotSelection(mode: SelectionMode) {
        guard !busy, recording == nil else { return NSSound.beep() }
        guard Permission.ensureScreenAccess() else { return }
        busy = true
        let previous = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            do {
                // Freeze the screen first, while the frontmost app still looks frontmost.
                let frozen = try await ScreenGrab.allDisplayImages()
                let overlay = SelectionOverlay(purpose: .screenshot, mode: mode, frozen: frozen, pickable: ScreenGrab.pickableWindows())
                self.overlay = overlay
                overlay.begin { [weak self] result in
                    self?.finishScreenshotSelection(result, frozen: frozen, previous: previous)
                }
            } catch {
                busy = false
                presentError(error, title: "ZipShot couldn't capture the screen")
            }
        }
    }

    private func finishScreenshotSelection(_ result: SelectionResult, frozen: [CGDirectDisplayID: CGImage], previous: NSRunningApplication?) {
        overlay = nil
        reactivate(previous)
        switch result {
        case .cancelled:
            busy = false

        case .screen(let screen):
            guard let image = frozen[screen.displayID] else { busy = false; return }
            deliver(image, scale: CGFloat(image.width) / screen.frame.width, on: screen)

        case .region(let rect, let screen):
            guard let full = frozen[screen.displayID] else { busy = false; return }
            let sx = CGFloat(full.width) / screen.frame.width
            let sy = CGFloat(full.height) / screen.frame.height
            // Screen coordinates are bottom-up; image rows are top-down.
            let pixels = CGRect(
                x: (rect.minX - screen.frame.minX) * sx, y: (screen.frame.maxY - rect.maxY) * sy,
                width: rect.width * sx, height: rect.height * sy
            ).pixelAligned(within: CGRect(x: 0, y: 0, width: full.width, height: full.height))
            guard let cropped = full.cropping(to: pixels) else { busy = false; return }
            deliver(cropped, scale: sx, on: screen)

        case .window(let info):
            let screen = NSScreen.screens.first { $0.frame.intersects(info.frame) } ?? NSScreen.underMouse
            Task { @MainActor in
                // Give the app we stepped in front of a moment to look active again.
                try? await Task.sleep(nanoseconds: 280_000_000)
                do {
                    let (image, scale) = try await ScreenGrab.windowImage(id: info.id)
                    deliver(image, scale: scale, on: screen)
                } catch {
                    busy = false
                    presentError(error, title: "ZipShot couldn't capture that window")
                }
            }
        }
    }

    private func captureScreen() {
        guard !busy, recording == nil else { return NSSound.beep() }
        guard Permission.ensureScreenAccess() else { return }
        busy = true
        let screen = NSScreen.underMouse
        Task { @MainActor in
            do {
                let image = try await ScreenGrab.displayImage(for: screen)
                deliver(image, scale: CGFloat(image.width) / screen.frame.width, on: screen)
            } catch {
                busy = false
                presentError(error, title: "ZipShot couldn't capture the screen")
            }
        }
    }

    /// Saves to the Desktop, copies to the clipboard, and says so.
    private func deliver(_ image: CGImage, scale: CGFloat, on screen: NSScreen) {
        Sounds.capture()
        Task { @MainActor in
            defer { busy = false }
            do {
                let item = try await Library.shared.addScreenshot(image, scale: scale)
                if Prefs.shared.showToast { ToastController.shared.show(item, on: screen) }
            } catch {
                presentError(error, title: "ZipShot couldn't save the capture to your Desktop")
            }
        }
    }

    private func reactivate(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated, app != NSRunningApplication.current else { return }
        app.activate()
    }

    // MARK: Recording

    /// The record shortcut: pick a region, then start, then stop.
    private func toggleRecording() {
        if let recording {
            recording.shortcutPressed()
            return
        }
        guard !busy else { return NSSound.beep() }
        guard Permission.ensureScreenAccess() else { return }
        busy = true
        let previous = NSWorkspace.shared.frontmostApplication
        let overlay = SelectionOverlay(purpose: .recording, mode: .region, frozen: [:], pickable: [])
        self.overlay = overlay
        overlay.begin { [weak self] result in
            guard let self else { return }
            self.overlay = nil
            self.busy = false
            self.reactivate(previous)
            guard case .region(let rect, let screen) = result else { return }
            guard rect.width >= 16, rect.height >= 16 else { return NSSound.beep() }
            let session = RecordingSession(region: rect, screen: screen)
            session.onEnd = { [weak self] in
                self?.recording = nil
                StatusItemController.shared.refreshIcon()
            }
            self.recording = session
            session.present()
            StatusItemController.shared.refreshIcon()
        }
    }

    func stopRecording() {
        recording?.stop()
    }
}
