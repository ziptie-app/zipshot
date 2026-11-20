import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound
    case windowNotFound
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "That display is no longer available."
        case .windowNotFound: return "That window is no longer on screen."
        case .nothingRecorded: return "Nothing was recorded."
        }
    }
}

/// ZipShot's own floating windows (toast, recording controls, menu), which
/// must never show up in a capture.
@MainActor
enum CaptureExclusion {
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    static func add(_ window: NSWindow) { windows.add(window) }

    static var windowIDs: Set<CGWindowID> {
        Set(windows.allObjects.filter { $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
    }

    static func windows(in content: SCShareableContent) -> [SCWindow] {
        let ids = windowIDs
        return content.windows.filter { ids.contains($0.windowID) }
    }
}

/// A window the user can pick, in Cocoa screen coordinates (origin bottom-left).
struct WindowInfo: Equatable {
    let id: CGWindowID
    let frame: CGRect
    let ownerName: String
}

@MainActor
enum ScreenGrab {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// A still of one display at its native resolution.
    static func displayImage(_ display: SCDisplay, in content: SCShareableContent) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: CaptureExclusion.windows(in: content))
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Stills of every display, taken together.
    static func allDisplayImages() async throws -> [CGDirectDisplayID: CGImage] {
        let content = try await content()
        var images: [CGDirectDisplayID: CGImage] = [:]
        try await withThrowingTaskGroup(of: (CGDirectDisplayID, CGImage).self) { group in
            for display in content.displays {
                group.addTask { @MainActor in
                    (display.displayID, try await displayImage(display, in: content))
                }
            }
            for try await (id, image) in group { images[id] = image }
        }
        return images
    }

    static func displayImage(for screen: NSScreen) async throws -> CGImage {
        let content = try await content()
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.displayNotFound
        }
        return try await displayImage(display, in: content)
    }

    /// A single window on its own: no shadow, see-through outside its rounded corners.
    static func windowImage(id: CGWindowID) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await content()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Ordinary windows of other apps, front to back.
    static func pickableWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [WindowInfo] = []
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 40, bounds.height >= 40
            else { continue }
            // Quartz window bounds have a top-left origin; flip to Cocoa's bottom-left.
            let frame = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            result.append(WindowInfo(id: CGWindowID(number), frame: frame, ownerName: entry[kCGWindowOwnerName as String] as? String ?? ""))
        }
        return result
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The screen the pointer is on.
    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }
}

// MARK: - Screen recording permission

@MainActor
enum Permission {
    /// True when captures can go ahead. Otherwise the user has been asked.
    static func ensureScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // The first call shows the system's own prompt and lists ZipShot in
        // System Settings; after that it does nothing, so add our own pointer.
        let firstAsk = !UserDefaults.standard.bool(forKey: "askedForScreenAccess")
        UserDefaults.standard.set(true, forKey: "askedForScreenAccess")
        CGRequestScreenCaptureAccess()
        if firstAsk { return false }

        let alert = NSAlert()
        alert.messageText = "ZipShot needs permission to record the screen"
        alert.informativeText = "Turn on ZipShot under Privacy & Security › Screen & System Audio Recording, then let macOS quit and reopen it."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}

@MainActor
enum Sounds {
    private static let folder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    private static var cache: [String: NSSound] = [:]

    static func capture() { play("Screen Capture.aif") }
    static func recordStart() { play("begin_record.caf") }
    static func recordEnd() { play("end_record.caf") }

    private static func play(_ name: String) {
        guard Prefs.shared.playSounds else { return }
        if cache[name] == nil { cache[name] = NSSound(contentsOfFile: folder + name, byReference: true) }
        guard let sound = cache[name] else { return }
        sound.stop()
        sound.play()
    }
}

@MainActor
func presentError(_ error: Error, title: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
}
