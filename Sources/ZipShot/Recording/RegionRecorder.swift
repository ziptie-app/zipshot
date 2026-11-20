import AppKit
import CoreMedia
import ScreenCaptureKit
import ZipShotCore

/// Streams one region of a display into a FrameStore, with pause and resume.
///
/// The system only delivers a frame when the screen changes, so a still screen
/// costs nothing; each stored frame simply stays up until the next one.
final class RegionRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "zipshot.recorder", qos: .userInitiated)
    private var stream: SCStream?

    // Touched only on `queue`.
    private var store: FrameStore?
    private var startTime: Double?
    private var pausedTotal: Double = 0
    private var pauseBegan: Double?
    private var latest: CVPixelBuffer?
    private var finished = false

    /// Called on the main queue if the system ends the stream (for example the
    /// user stops sharing from the menu bar).
    var onInterrupted: (() -> Void)?

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func pause() {
        queue.async {
            if self.pauseBegan == nil { self.pauseBegan = CACurrentMediaTime() }
        }
    }

    func resume() {
        queue.async {
            guard let began = self.pauseBegan else { return }
            let now = CACurrentMediaTime()
            self.pausedTotal += now - began
            self.pauseBegan = nil
            // Whatever changed while paused should be on screen from the first instant.
            if let latest = self.latest, let start = self.startTime {
                self.write(latest, at: now - start - self.pausedTotal)
            }
        }
    }

    /// Recorded time so far, not counting pauses.
    var elapsed: TimeInterval { queue.sync { elapsedOnQueue() } }

    private func elapsedOnQueue() -> TimeInterval {
        guard let start = startTime else { return 0 }
        return max(0, (pauseBegan ?? CACurrentMediaTime()) - start - pausedTotal)
    }

    /// Ends the recording and hands back the frames, or nil if none arrived.
    func stop() async -> FrameStore? {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return queue.sync {
            finished = true
            store?.finish(duration: elapsedOnQueue())
            latest = nil
            return store
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !finished, sampleBuffer.isValid, let buffer = sampleBuffer.imageBuffer else { return }
        // Skip "nothing changed" notifications; only complete frames carry pixels.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete
        else { return }

        let now = CACurrentMediaTime()
        latest = buffer
        if startTime == nil { startTime = now }
        guard pauseBegan == nil, let start = startTime else { return }
        write(buffer, at: now - start - pausedTotal)
    }

    private func write(_ buffer: CVPixelBuffer, at time: TimeInterval) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        // Size the store from the first real frame rather than what was asked for.
        if store == nil { store = try? FrameStore(width: width, height: height) }
        guard let store, store.width == width, store.height == height else { return }
        _ = try? store.append(bgra: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), time: max(0, time))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onInterrupted?() }
    }
}
