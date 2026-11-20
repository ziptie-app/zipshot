import AppKit
import ZipShotCore

/// One saved capture and whatever is needed to keep editing it.
@MainActor
final class CaptureItem: ObservableObject, Identifiable {
    enum Kind { case image, gif }

    let id = UUID()
    let kind: Kind
    let url: URL
    @Published var thumbnail: NSImage?
    /// Size of the file's image in pixels.
    @Published var pixelSize: CGSize

    // Screenshots: the untouched capture plus the edits made so far.
    var renderer: Renderer?
    var scale: CGFloat = 1
    var editState: EditState?

    // Recordings: the original frames plus the saved trim.
    var frames: FrameStore?
    var trim: ClosedRange<TimeInterval>?

    var fileName: String { url.lastPathComponent }
    var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    init(kind: Kind, url: URL, pixelSize: CGSize) {
        self.kind = kind
        self.url = url
        self.pixelSize = pixelSize
    }
}

/// Saves captures to the Desktop, copies them to the clipboard, and remembers
/// the most recent ones for the menu.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()
    static let maxItems = 6
    /// Uncompressed captures kept in memory for further editing, beyond the newest.
    private static let memoryBudget = 400 * 1024 * 1024

    @Published private(set) var items: [CaptureItem] = []

    static var desktop: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    /// Writes the PNG, puts it on the clipboard and lists it under Recent.
    func addScreenshot(_ image: CGImage, scale: CGFloat) async throws -> CaptureItem {
        let url = CaptureNaming.uniqueURL(in: Self.desktop, ext: "png")
        let data = try await Task.detached(priority: .userInitiated) { () throws -> Data in
            guard let data = PNGWriter.data(for: image, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            return data
        }.value
        Clipboard.copy(png: data, image: image)

        let item = CaptureItem(kind: .image, url: url, pixelSize: CGSize(width: image.width, height: image.height))
        item.renderer = Renderer(base: image)
        item.scale = scale
        item.thumbnail = Thumbnail.make(from: image)
        insert(item)
        return item
    }

    /// Lists a recording whose GIF is already at `url`.
    func addRecording(frames: FrameStore, url: URL) -> CaptureItem {
        let item = CaptureItem(kind: .gif, url: url, pixelSize: CGSize(width: frames.width, height: frames.height))
        item.frames = frames
        if let first = frames.image(at: 0) { item.thumbnail = Thumbnail.make(from: first) }
        Clipboard.copy(gifAt: url)
        insert(item)
        return item
    }

    private func insert(_ item: CaptureItem) {
        items.insert(item, at: 0)
        while items.count > Self.maxItems { items.removeLast() }
        // Keep the newest captures editable; older ones reopen from their file.
        var used = 0
        for (i, entry) in items.enumerated() {
            guard let renderer = entry.renderer else { continue }
            used += renderer.base.bytesPerRow * renderer.base.height
            if i > 0, used > Self.memoryBudget, !EditorWindows.isOpen(entry) {
                entry.renderer = nil
                entry.editState = nil
            }
        }
    }

    /// Lists captures without saving or copying anything (UI snapshots only).
    func insertForPreview(_ preview: [CaptureItem]) {
        items = preview
    }

    func remove(_ item: CaptureItem) {
        items.removeAll { $0.id == item.id }
    }

    /// Drops recordings' temporary frame files.
    func releaseAll() {
        items.removeAll()
    }
}

enum Thumbnail {
    static func make(from image: CGImage, maxSide: CGFloat = 240) -> NSImage? {
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale))
        let h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        return NSImage(cgImage: small, size: NSSize(width: w, height: h))
    }
}

@MainActor
enum Clipboard {
    /// PNG now, with TIFF made only if an app asks for it (it is large).
    static func copy(png: Data, image: CGImage) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let provider = TIFFProvider(image: image)
        item.setDataProvider(provider, forTypes: [.tiff])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        tiffProvider = provider
    }

    /// The GIF both as a file (for Finder, Slack, Mail, Messages…) and as raw
    /// GIF data (for apps that paste images).
    static func copy(gifAt url: URL) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        tiffProvider = nil
    }

    private static var tiffProvider: TIFFProvider?

    private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
        let image: CGImage

        init(image: CGImage) { self.image = image }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == .tiff, let data = NSBitmapImageRep(cgImage: image).tiffRepresentation else { return }
            item.setData(data, forType: .tiff)
        }
    }
}
