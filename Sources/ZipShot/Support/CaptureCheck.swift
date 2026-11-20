import AppKit
import ScreenCaptureKit
import ZipShotCore

/// Developer aid: `ZipShot --capture-check <folder>` exercises the real capture
/// paths (a display still, a window still, a short region recording) and prints
/// what came back. Files go to the given folder, never the Desktop, and nothing
/// touches the clipboard. Does nothing unless screen recording is already
/// allowed for whatever launched it, so it never raises a permission prompt.
@MainActor
enum CaptureCheck {
    static func run(into folder: URL) async -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            print("screen recording: not permitted for this process; skipping")
            return false
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var ok = true
        do {
            let screen = NSScreen.underMouse
            let scale = screen.backingScaleFactor
            let expected = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)

            let display = try await ScreenGrab.displayImage(for: screen)
            print("display: \(display.width)x\(display.height) (expected \(Int(expected.width))x\(Int(expected.height))), colorspace \(display.colorSpace?.name as String? ?? "?")")
            ok = ok && display.width == Int(expected.width) && display.height == Int(expected.height)

            let all = try await ScreenGrab.allDisplayImages()
            print("all displays: \(all.count) of \(NSScreen.screens.count)")
            ok = ok && all.count == NSScreen.screens.count

            let windows = ScreenGrab.pickableWindows()
            print("pickable windows: \(windows.count)")
            if let first = windows.first {
                let (image, windowScale) = try await ScreenGrab.windowImage(id: first.id)
                let want = CGSize(width: first.frame.width * windowScale, height: first.frame.height * windowScale)
                print("window: \(image.width)x\(image.height) at \(windowScale)x (frame says \(Int(want.width))x\(Int(want.height))), alpha \(image.alphaInfo.rawValue)")
                ok = ok && abs(CGFloat(image.width) - want.width) <= 2 && abs(CGFloat(image.height) - want.height) <= 2
            }

            // Record 320x200 points from the top-left of the screen for two seconds.
            let content = try await ScreenGrab.content()
            guard let scDisplay = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                throw CaptureError.displayNotFound
            }
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: 0, width: 320, height: 200)
            config.width = 320
            config.height = 200
            config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.colorSpaceName = CGColorSpace.sRGB
            config.queueDepth = 6
            let recorder = RegionRecorder()
            try await recorder.start(filter: SCContentFilter(display: scDisplay, excludingWindows: []), configuration: config)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            recorder.pause()
            try await Task.sleep(nanoseconds: 500_000_000)
            let pausedAt = recorder.elapsed
            try await Task.sleep(nanoseconds: 500_000_000)
            let stillPaused = recorder.elapsed
            recorder.resume()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard let frames = await recorder.stop() else {
                print("recording: no frames arrived")
                return false
            }
            print("recording: \(frames.frameCount) frames, \(frames.width)x\(frames.height), \(String(format: "%.2f", frames.duration))s, \(frames.fileSize) bytes stored; paused clock \(String(format: "%.2f", pausedAt)) -> \(String(format: "%.2f", stillPaused))")
            ok = ok && frames.frameCount >= 1 && frames.width == 320 && frames.height == 200
            ok = ok && abs(stillPaused - pausedAt) < 0.01 && frames.duration > 1.6 && frames.duration < 2.6

            let url = folder.appendingPathComponent("check.gif")
            try GIFExporter.export(store: frames, to: url)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            print("gif: \(size) bytes, \(source.map(CGImageSourceGetCount) ?? 0) frames")
            ok = ok && (source.map(CGImageSourceGetCount) ?? 0) >= 1
        } catch {
            print("failed: \(error)")
            ok = false
        }
        print(ok ? "capture check passed" : "capture check FAILED")
        return ok
    }
}
