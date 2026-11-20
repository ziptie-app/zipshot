import AppKit
import ImageIO
import ZipShotCore

// Headless checks for ZipShotCore.
//   swift run -c release zipshot-selftest [output-directory]
// Rendered samples are written to the output directory for a visual check.

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    do {
        if try !condition() {
            failures += 1
            print("  FAIL (line \(line)): \(message)")
        }
    } catch {
        failures += 1
        print("  FAIL (line \(line)): \(message): threw \(error)")
    }
}

func section(_ name: String, _ body: () throws -> Void) {
    print("- \(name)")
    do { try body() } catch {
        failures += 1
        print("  FAIL: threw \(error)")
    }
}

let outputDirectory: URL = {
    if CommandLine.arguments.count > 1 { return URL(fileURLWithPath: CommandLine.arguments[1]) }
    return FileManager.default.temporaryDirectory.appendingPathComponent("zipshot-selftest")
}()
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// MARK: Helpers

struct Frame {
    let width: Int
    let height: Int
    var pixels: [UInt32]  // 0x00RRGGBB

    init(width: Int, height: Int, fill: UInt32 = 0) {
        self.width = width
        self.height = height
        pixels = [UInt32](repeating: fill, count: width * height)
    }

    mutating func fillRect(x: Int, y: Int, w: Int, h: Int, color: UInt32) {
        for yy in max(0, y)..<min(height, y + h) {
            for xx in max(0, x)..<min(width, x + w) { pixels[yy * width + xx] = color }
        }
    }
}

struct DecodedGIF {
    var frames: [[UInt32]] = []
    var delays: [Double] = []
    var width = 0
    var height = 0
}

/// Decodes with ImageIO, an implementation independent of the encoder under test.
func decodeGIF(_ url: URL) -> DecodedGIF? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    var result = DecodedGIF()
    for i in 0..<CGImageSourceGetCount(source) {
        guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { return nil }
        result.width = image.width
        result.height = image.height
        var pixels = [UInt32](repeating: 0, count: image.width * image.height)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard ok else { return nil }
        result.frames.append(pixels.map { $0 & 0x00FF_FFFF })
        let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        result.delays.append((gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? -1)
    }
    return result
}

func maxChannelError(_ a: [UInt32], _ b: [UInt32]) -> Int {
    var worst = 0
    for i in 0..<min(a.count, b.count) where a[i] != b[i] {
        for shift in [0, 8, 16] {
            let d = abs(Int((a[i] >> UInt32(shift)) & 0xFF) - Int((b[i] >> UInt32(shift)) & 0xFF))
            worst = max(worst, d)
        }
    }
    return a.count == b.count ? worst : 255
}

func meanChannelError(_ a: [UInt32], _ b: [UInt32]) -> Double {
    var total = 0
    for i in 0..<min(a.count, b.count) {
        for shift in [0, 8, 16] {
            total += abs(Int((a[i] >> UInt32(shift)) & 0xFF) - Int((b[i] >> UInt32(shift)) & 0xFF))
        }
    }
    return Double(total) / Double(max(1, a.count * 3))
}

func encodeGIF(_ frames: [Frame], delays: [Double], name: String) throws -> URL {
    let url = outputDirectory.appendingPathComponent(name)
    let encoder = try GIFEncoder(url: url, width: frames[0].width, height: frames[0].height)
    for (frame, delay) in zip(frames, delays) {
        try frame.pixels.withUnsafeBufferPointer { try encoder.addFrame(bgra: $0.baseAddress!, delay: delay) }
    }
    try encoder.finish()
    return url
}

func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(
        data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Place the image so that pixel (x, y), counted from the top-left, lands on our one pixel.
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
}

func writePNG(_ image: CGImage, _ name: String) {
    if let data = PNGWriter.data(for: image, scale: 1) {
        try? data.write(to: outputDirectory.appendingPathComponent(name))
    }
}

var rng = SystemRandomNumberGenerator()

// MARK: Tests

section("capture naming") {
    let name = CaptureNaming.fileName(ext: "png")
    check(name.hasPrefix("zipshot-") && name.hasSuffix(".png"), "shape of \(name)")
    let token = name.dropFirst(8).dropLast(4)
    check(token.count == 8 && token.allSatisfy { $0.isLetter || $0.isNumber }, "token \(token)")
    check(Set((0..<500).map { _ in CaptureNaming.randomToken() }).count == 500, "tokens repeat")
    let dir = outputDirectory.appendingPathComponent("naming-\(CaptureNaming.randomToken())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = CaptureNaming.uniqueURL(in: dir, ext: "gif")
    check(url.pathExtension == "gif" && url.deletingLastPathComponent().path == dir.path, "unique url \(url.path)")
    try FileManager.default.removeItem(at: dir)
}

section("geometry") {
    check(abs(distance(from: CGPoint(x: 5, y: 5), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)) - 5) < 1e-9, "distance to segment")
    check(abs(distance(from: CGPoint(x: -3, y: 4), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)) - 5) < 1e-9, "distance past the end")
    let snapped = snapTo45(CGPoint(x: 10, y: 1), from: .zero)
    check(abs(snapped.y) < 1e-9 && snapped.x > 10, "snap to horizontal: \(snapped)")
    let diagonal = snapTo45(CGPoint(x: 10, y: 9), from: .zero)
    check(abs(diagonal.x - diagonal.y) < 1e-9, "snap to diagonal: \(diagonal)")
    let r = CGRect(x: 10, y: 10, width: 20, height: 20)
    check(r.movingCorner(0, to: CGPoint(x: 0, y: 5)) == CGRect(x: 0, y: 5, width: 30, height: 25), "drag top-left")
    check(r.movingCorner(2, to: CGPoint(x: 5, y: 5)) == CGRect(x: 5, y: 5, width: 5, height: 5), "drag bottom-right past the anchor")
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    check(CGRect(x: -5.4, y: 10.6, width: 50, height: 200).pixelAligned(within: bounds) == CGRect(x: 0, y: 11, width: 45, height: 89), "pixel align")
    check(CGRect(x: 500, y: 500, width: 5, height: 5).pixelAligned(within: bounds).size == CGSize(width: 1, height: 1), "pixel align outside")

    var arrow = Annotation(shape: .arrow(ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), color: .red, thickness: 4)))
    check(arrow.hitTest(CGPoint(x: 50, y: 3), tolerance: 4), "arrow hit")
    check(!arrow.hitTest(CGPoint(x: 50, y: 30), tolerance: 4), "arrow miss")
    arrow.move(.arrowEnd, to: CGPoint(x: 0, y: 100))
    arrow.translate(by: CGSize(width: 5, height: 5))
    if case .arrow(let a) = arrow.shape {
        check(a.start == CGPoint(x: 5, y: 5) && a.end == CGPoint(x: 5, y: 105), "arrow move and translate")
    }
    let text = Annotation(shape: .text(TextShape(origin: CGPoint(x: 10, y: 10), text: "Hello\nworld", color: .red, fontSize: 20)))
    let oneLine = TextLayout.size(of: TextShape(origin: .zero, text: "Hello", color: .red, fontSize: 20))
    check(text.bounds.height > oneLine.height * 1.8, "two lines are about twice as tall as one")
    check(text.hitTest(CGPoint(x: 20, y: 20), tolerance: 4), "text hit")
}

section("gif: exact round trip of flat-color frames") {
    var frames: [Frame] = []
    for i in 0..<5 {
        var f = Frame(width: 64, height: 48, fill: 0x00F5F5F7)
        f.fillRect(x: 0, y: 0, w: 64, h: 6, color: 0x00DADCE0)
        f.fillRect(x: 4 + i * 9, y: 20, w: 8, h: 8, color: 0x00E5484D)
        frames.append(f)
    }
    let delays = [0.1, 0.1, 0.2, 0.1, 0.5]
    let url = try encodeGIF(frames, delays: delays, name: "roundtrip-flat.gif")
    guard let decoded = decodeGIF(url) else { return check(false, "ImageIO could not decode") }
    check(decoded.frames.count == 5, "frame count \(decoded.frames.count)")
    check(decoded.width == 64 && decoded.height == 48, "size")
    for i in 0..<min(5, decoded.frames.count) {
        check(decoded.frames[i] == frames[i].pixels, "frame \(i) differs by up to \(maxChannelError(decoded.frames[i], frames[i].pixels))")
        check(abs(decoded.delays[i] - delays[i]) < 0.011, "delay \(i) = \(decoded.delays[i])")
    }
}

section("gif: unchanged frames extend the previous delay") {
    let a = Frame(width: 40, height: 30, fill: 0x00336699)
    var b = a
    b.fillRect(x: 10, y: 10, w: 5, h: 5, color: 0x00FFFFFF)
    let url = try encodeGIF([a, a, a, b, b], delays: [0.1, 0.1, 0.1, 0.25, 0.25], name: "dedupe.gif")
    guard let decoded = decodeGIF(url) else { return check(false, "decode") }
    check(decoded.frames.count == 2, "frame count \(decoded.frames.count)")
    if decoded.frames.count == 2 {
        check(abs(decoded.delays[0] - 0.3) < 0.011 && abs(decoded.delays[1] - 0.5) < 0.011, "delays \(decoded.delays)")
        check(decoded.frames[0] == a.pixels && decoded.frames[1] == b.pixels, "pixels")
    }
}

section("gif: delays do not drift") {
    // 15 fps is 6.67cs a frame, which no single GIF delay can express.
    var frames: [Frame] = []
    for i in 0..<45 {
        var f = Frame(width: 16, height: 16, fill: 0)
        f.fillRect(x: i % 16, y: 0, w: 1, h: 16, color: 0x00FFFFFF)
        frames.append(f)
    }
    let url = try encodeGIF(frames, delays: [Double](repeating: 1.0 / 15, count: 45), name: "timing.gif")
    guard let decoded = decodeGIF(url) else { return check(false, "decode") }
    let total = decoded.delays.reduce(0, +)
    check(abs(total - 3.0) < 0.011, "45 frames at 15fps last \(total)s, expected 3.0")
}

section("gif: noise (dictionary resets, many colors)") {
    var frames: [Frame] = []
    for _ in 0..<3 {
        var f = Frame(width: 201, height: 151)
        for i in f.pixels.indices { f.pixels[i] = UInt32.random(in: 0...0x00FF_FFFF, using: &rng) }
        frames.append(f)
    }
    let url = try encodeGIF(frames, delays: [0.1, 0.1, 0.1], name: "noise.gif")
    guard let decoded = decodeGIF(url) else { return check(false, "decode") }
    check(decoded.frames.count == 3, "frame count \(decoded.frames.count)")
    for i in 0..<min(3, decoded.frames.count) {
        let error = meanChannelError(decoded.frames[i], frames[i].pixels)
        // 256 colors cannot represent noise well; this only has to be sane, not good.
        check(error < 40, "frame \(i) mean error \(error)")
    }
}

section("gif: 256-color noise is exact (long LZW streams)") {
    // Exactly 256 distinct colors, far apart, in random order: stresses the
    // LZW table (fills and resets many times) while staying lossless.
    let palette: [UInt32] = (0..<256).map { (i: Int) -> UInt32 in
        let r = UInt32(i & 0x7) << 21
        let g = UInt32((i >> 3) & 0x7) << 13
        let b = UInt32((i >> 6) & 0x3) << 6
        return r | g | b
    }
    var frames: [Frame] = []
    for _ in 0..<2 {
        var f = Frame(width: 257, height: 199)
        for i in f.pixels.indices { f.pixels[i] = palette[Int.random(in: 0..<256, using: &rng)] }
        frames.append(f)
    }
    let url = try encodeGIF(frames, delays: [0.1, 0.1], name: "noise256.gif")
    guard let decoded = decodeGIF(url) else { return check(false, "decode") }
    check(decoded.frames.count == 2, "frame count \(decoded.frames.count)")
    if decoded.frames.count == 2 {
        // The second frame needs 256 colors plus transparency, so one color merges.
        check(decoded.frames[0] == frames[0].pixels, "first frame differs by up to \(maxChannelError(decoded.frames[0], frames[0].pixels))")
        check(meanChannelError(decoded.frames[1], frames[1].pixels) < 1, "second frame mean error \(meanChannelError(decoded.frames[1], frames[1].pixels))")
    }
}

section("gif: every palette size and tiny images") {
    // Code widths change at different points for each palette size.
    for colors in [1, 2, 3, 4, 5, 15, 16, 17, 100, 255, 256] {
        var f = Frame(width: 97, height: 53)
        for i in f.pixels.indices {
            let c = UInt32(i * 7919 % colors)
            let hi: UInt32 = (c & 0xF) << 20
            let lo: UInt32 = ((c >> 4) & 0xF) << 12
            f.pixels[i] = hi | lo | 0x40
        }
        let url = try encodeGIF([f], delays: [0.1], name: "palette-\(colors).gif")
        let decoded = decodeGIF(url)
        check(decoded?.frames.first == f.pixels, "\(colors) colors")
    }
    for (w, h) in [(1, 1), (1, 7), (7, 1), (2, 2)] {
        var f = Frame(width: w, height: h, fill: 0x00123456)
        f.pixels[w * h - 1] = 0x00FEDCBA
        var g = f
        g.pixels[0] = 0x00FFFFFF
        let url = try encodeGIF([f, g], delays: [0.1, 0.1], name: "tiny-\(w)x\(h).gif")
        let decoded = decodeGIF(url)
        check(decoded?.frames.count == 2 && decoded?.frames[0] == f.pixels && decoded?.frames[1] == g.pixels, "\(w)x\(h)")
    }
}

section("gif: gradients stay close") {
    var f = Frame(width: 256, height: 256)
    for y in 0..<256 {
        for x in 0..<256 {
            let r = UInt32(x) << 16
            let g = UInt32(y) << 8
            f.pixels[y * 256 + x] = r | g | UInt32((x + y) / 2)
        }
    }
    var g = f
    g.fillRect(x: 100, y: 100, w: 60, h: 40, color: 0x00FFFFFF)
    let url = try encodeGIF([f, g], delays: [0.5, 0.5], name: "gradient.gif")
    guard let decoded = decodeGIF(url), decoded.frames.count == 2 else { return check(false, "decode") }
    check(maxChannelError(decoded.frames[0], f.pixels) <= 24, "max error \(maxChannelError(decoded.frames[0], f.pixels))")
    check(meanChannelError(decoded.frames[0], f.pixels) < 5, "mean error \(meanChannelError(decoded.frames[0], f.pixels))")
    check(meanChannelError(decoded.frames[1], g.pixels) < 5, "second frame mean error \(meanChannelError(decoded.frames[1], g.pixels))")
}

section("gif: only the changed area is stored") {
    var frames: [Frame] = []
    var base = Frame(width: 640, height: 400)
    for i in base.pixels.indices { base.pixels[i] = UInt32.random(in: 0...0x00FF_FFFF, using: &rng) }
    for i in 0..<10 {
        var f = base
        f.fillRect(x: 10 + i * 20, y: 10, w: 12, h: 12, color: 0x00FF0000)
        frames.append(f)
    }
    let one = try encodeGIF([frames[0]], delays: [0.1], name: "diff-one.gif")
    let ten = try encodeGIF(frames, delays: [Double](repeating: 0.1, count: 10), name: "diff-ten.gif")
    let sizeOne = (try FileManager.default.attributesOfItem(atPath: one.path)[.size] as? Int) ?? 0
    let sizeTen = (try FileManager.default.attributesOfItem(atPath: ten.path)[.size] as? Int) ?? 0
    check(sizeTen < sizeOne + sizeOne / 4, "10 frames with a small moving square took \(sizeTen) bytes against \(sizeOne) for one frame")
    check(decodeGIF(ten)?.frames.count == 10, "frame count")
}

section("frame store") {
    let w = 37, h = 23
    let store = try FrameStore(width: w, height: h, directory: outputDirectory)
    let path = store.url.path
    var a = Frame(width: w, height: h, fill: 0xFF102030)
    a.fillRect(x: 3, y: 3, w: 10, h: 10, color: 0xFFAABBCC)
    var b = a
    b.fillRect(x: 20, y: 5, w: 4, h: 4, color: 0xFF000000)
    var noise = Frame(width: w, height: h)
    for i in noise.pixels.indices { noise.pixels[i] = UInt32.random(in: 0...UInt32.max, using: &rng) }

    check(try a.pixels.withUnsafeBytes { try store.append(bgra: $0.baseAddress!, bytesPerRow: w * 4, time: 0) }, "first frame stored")
    check(try !a.pixels.withUnsafeBytes { try store.append(bgra: $0.baseAddress!, bytesPerRow: w * 4, time: 0.5) }, "duplicate dropped")
    // A source with row padding, as pixel buffers from the system often have.
    let padded = w * 4 + 20
    var wide = [UInt8](repeating: 0xEE, count: padded * h)
    b.pixels.withUnsafeBytes { src in
        for y in 0..<h {
            wide.withUnsafeMutableBytes { dst in
                _ = memcpy(dst.baseAddress! + y * padded, src.baseAddress! + y * w * 4, w * 4)
            }
        }
    }
    check(try wide.withUnsafeBytes { try store.append(bgra: $0.baseAddress!, bytesPerRow: padded, time: 1.0) }, "padded frame stored")
    check(try noise.pixels.withUnsafeBytes { try store.append(bgra: $0.baseAddress!, bytesPerRow: w * 4, time: 2.0) }, "incompressible frame stored")
    store.finish(duration: 3.0)

    check(store.frameCount == 3 && store.duration == 3.0, "count \(store.frameCount), duration \(store.duration)")
    var out = [UInt32](repeating: 0, count: w * h)
    for (i, expected) in [a, b, noise].enumerated() {
        try out.withUnsafeMutableBytes { try store.read(i, into: $0.baseAddress!) }
        check(out == expected.pixels, "frame \(i) reads back")
    }
    check(store.frameIndex(at: 0) == 0 && store.frameIndex(at: 0.99) == 0 && store.frameIndex(at: 1.0) == 1
        && store.frameIndex(at: 2.5) == 2 && store.frameIndex(at: 99) == 2 && store.frameIndex(at: -1) == 0, "frame lookup by time")
    check(store.image(at: 1)?.width == w, "frame as image")
    check(FileManager.default.fileExists(atPath: path), "backing file exists while in use")
}

section("gif export plan (trimming)") {
    typealias Step = GIFExporter.Step
    let times = [0.0, 1.0, 2.0, 3.0]
    func approx(_ a: [Step], _ b: [Step]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.frame == $1.frame && abs($0.delay - $1.delay) < 1e-9 }
    }
    check(approx(GIFExporter.plan(times: times, duration: 4, range: 0...4),
                 [Step(frame: 0, delay: 1), Step(frame: 1, delay: 1), Step(frame: 2, delay: 1), Step(frame: 3, delay: 1)]), "full range")
    check(approx(GIFExporter.plan(times: times, duration: 4, range: 0.5...2.5),
                 [Step(frame: 0, delay: 0.5), Step(frame: 1, delay: 1), Step(frame: 2, delay: 0.5)]), "trim both ends mid-frame")
    check(approx(GIFExporter.plan(times: times, duration: 4, range: 1...2), [Step(frame: 1, delay: 1)]), "trim on frame boundaries")
    check(approx(GIFExporter.plan(times: times, duration: 4, range: 3.5...10), [Step(frame: 3, delay: 0.5)]), "tail of the last frame")
    check(GIFExporter.plan(times: times, duration: 4, range: 2...2).isEmpty, "empty range")
    check(GIFExporter.plan(times: [], duration: 4, range: 0...4).isEmpty, "no frames")
    // Edges that land on a frame boundary, give or take floating-point error,
    // must not leave a sliver of the neighbouring frame.
    let fifths = (0..<40).map { Double($0) * 0.2 }
    let trimmed = GIFExporter.plan(times: fifths, duration: 8, range: 1.2...6.8)
    check(trimmed.count == 28 && trimmed.first?.frame == 6 && trimmed.last?.frame == 33, "boundary trim: \(trimmed.count) steps, \(trimmed.first?.frame ?? -1)...\(trimmed.last?.frame ?? -1)")
    check(abs(trimmed.reduce(0) { $0 + $1.delay } - 5.6) < 1e-6, "boundary trim keeps its length")
    // A recording whose first frame arrives late still starts at the range start.
    check(approx(GIFExporter.plan(times: [0.2, 1.0], duration: 2, range: 0...2),
                 [Step(frame: 0, delay: 0.8), Step(frame: 1, delay: 1)]), "late first frame")
}

section("gif export from a frame store, trimmed, replacing a file") {
    let w = 48, h = 32
    let store = try FrameStore(width: w, height: h, directory: outputDirectory)
    var frames: [Frame] = []
    for i in 0..<8 {
        var f = Frame(width: w, height: h, fill: 0xFF202020)
        f.fillRect(x: i * 5, y: 10, w: 6, h: 6, color: 0xFFC6F24E)
        frames.append(f)
        try f.pixels.withUnsafeBytes { _ = try store.append(bgra: $0.baseAddress!, bytesPerRow: w * 4, time: Double(i) * 0.5) }
    }
    store.finish(duration: 4.0)
    let url = outputDirectory.appendingPathComponent("export.gif")
    try? FileManager.default.removeItem(at: url)

    var lastProgress = 0.0
    check(try GIFExporter.export(store: store, to: url) { lastProgress = $0; return true }, "full export")
    check(lastProgress == 1.0, "progress reached \(lastProgress)")
    guard let full = decodeGIF(url) else { return check(false, "decode full") }
    check(full.frames.count == 8 && abs(full.delays.reduce(0, +) - 4.0) < 0.011, "full: \(full.frames.count) frames, \(full.delays.reduce(0, +))s")

    check(try GIFExporter.export(store: store, range: 1.25...2.75, to: url), "trimmed export over the existing file")
    guard let trimmed = decodeGIF(url) else { return check(false, "decode trimmed") }
    check(trimmed.frames.count == 4, "trimmed frame count \(trimmed.frames.count)")
    check(abs(trimmed.delays.reduce(0, +) - 1.5) < 0.011, "trimmed length \(trimmed.delays.reduce(0, +))")
    if trimmed.frames.count == 4 {
        check(trimmed.frames[0] == frames[2].pixels.map { $0 & 0x00FF_FFFF }, "trim starts on the frame showing at 1.25s")
        check(trimmed.frames[3] == frames[5].pixels.map { $0 & 0x00FF_FFFF }, "trim ends on the frame showing at 2.75s")
    }

    check(try !GIFExporter.export(store: store, to: url) { _ in false }, "cancelled export reports false")
    check(decodeGIF(url)?.frames.count == 4, "cancelling leaves the existing file alone")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path))?.filter { $0.hasSuffix(".tmp") } ?? []
    check(leftovers.isEmpty, "temporary files left behind: \(leftovers)")
}

section("renderer") {
    // A synthetic "screenshot": light background, a header, rows of text-like bars.
    let w = 520, h = 300
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(CGColor(srgbRed: 0.925, green: 0.929, blue: 0.937, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.45, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: 36))
    for row in 0..<6 {
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.35, alpha: 1))
        for word in 0..<8 {
            ctx.fill(CGRect(x: 30 + word * 44, y: 70 + row * 30, width: 14 + (word * 7 + row * 5) % 22, height: 10))
        }
    }
    let base = ctx.makeImage()!
    let renderer = Renderer(base: base)

    var state = EditState(imageSize: renderer.size)
    check(renderer.outputSize(for: state) == CGSize(width: w, height: h), "untouched size")
    if let plain = renderer.render(state) {
        let p = pixel(plain, 10, 10)
        check(abs(p.r - 51) <= 2 && abs(p.b - 230) <= 2, "untouched render keeps the header color: \(p)")
        let q = pixel(plain, 10, 290)
        check(abs(q.r - 236) <= 2 && abs(q.g - 237) <= 2, "and is the right way up: \(q)")
    } else {
        check(false, "render failed")
    }

    let pixelRect = CGRect(x: 30, y: 60, width: 200, height: 64)
    state.annotations = [
        Annotation(shape: .blur(BlurShape(rect: pixelRect, style: .pixelate, strength: 16))),
        Annotation(shape: .blur(BlurShape(rect: CGRect(x: 30, y: 190, width: 200, height: 64), style: .gaussian, strength: 8))),
        Annotation(shape: .arrow(ArrowShape(start: CGPoint(x: 430, y: 110), end: CGPoint(x: 260, y: 92), color: .red, thickness: 6))),
        Annotation(shape: .text(TextShape(origin: CGPoint(x: 330, y: 120), text: "Hide this", color: .red, fontSize: 26))),
    ]
    guard let annotated = renderer.render(state) else { return check(false, "render failed") }
    writePNG(annotated, "render-annotated.png")
    // Inside one 16px pixelation block every pixel is the same.
    let p1 = pixel(annotated, 34, 64), p2 = pixel(annotated, 42, 72)
    check(p1 == p2, "pixelated block is flat: \(p1) vs \(p2)")
    // The bars under the pixelated area are no longer at full contrast.
    let onBar = pixel(annotated, 37, 75)
    check(onBar.r > 100, "pixelation hides the dark bar: \(onBar)")
    let mid = pixel(annotated, 345, 101)
    check(mid.r > 200 && mid.g < 120 && mid.b < 120, "arrow shaft is red: \(mid)")
    let untouched = pixel(annotated, 500, 280)
    check(abs(untouched.r - 236) <= 2, "the rest is untouched: \(untouched)")
    let blurred = pixel(annotated, 37, 205)
    check(blurred.r > 110 && blurred.r < 236, "gaussian blur softens the bar: \(blurred)")

    state.crop = CGRect(x: 20, y: 40, width: 440, height: 230)
    state.border = Border(fill: .color, color: RGBAColor(r: 0.776, g: 0.949, b: 0.306), thickness: 24)
    check(renderer.outputSize(for: state) == CGSize(width: 488, height: 278), "size with crop and border")
    guard let bordered = renderer.render(state) else { return check(false, "render failed") }
    writePNG(bordered, "render-border-color.png")
    check(bordered.width == 488 && bordered.height == 278, "bordered image size \(bordered.width)x\(bordered.height)")
    let corner = pixel(bordered, 3, 3)
    check(abs(corner.r - 198) <= 2 && abs(corner.g - 242) <= 2 && abs(corner.b - 78) <= 2, "border color \(corner)")
    // Crop origin (20, 40) lands at (24, 24): image pixel (30, 50) shows at (34, 34).
    let inside = pixel(bordered, 34, 34)
    check(abs(inside.r - 236) <= 2, "content is offset by the border: \(inside)")
    let arrowAfterCrop = pixel(bordered, 345 - 20 + 24, 101 - 40 + 24)
    check(arrowAfterCrop.r > 200 && arrowAfterCrop.g < 120, "annotations keep their place after cropping: \(arrowAfterCrop)")

    state.border = Border(fill: .blur, color: .white, thickness: 40, blurStrength: 40)
    guard let blurBorder = renderer.render(state) else { return check(false, "render failed") }
    writePNG(blurBorder, "render-border-blur.png")
    check(blurBorder.width == 520 && blurBorder.height == 310, "blur-bordered size \(blurBorder.width)x\(blurBorder.height)")
    let edge = pixel(blurBorder, 5, 150)
    check(edge.a == 255, "blur border is opaque: \(edge)")

    state.border.thickness = 0
    check(renderer.outputSize(for: state) == CGSize(width: 440, height: 230), "zero thickness means no border")

    if let data = PNGWriter.data(for: annotated, scale: 2),
       let source = CGImageSourceCreateWithData(data as CFData, nil),
       let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
        check((properties[kCGImagePropertyDPIWidth] as? Double) == 144, "retina PNG is tagged 144 dpi: \(String(describing: properties[kCGImagePropertyDPIWidth]))")
        check((properties[kCGImagePropertyPixelWidth] as? Int) == w, "PNG keeps its pixel size")
    } else {
        check(false, "PNG encode/decode")
    }
}

print(failures == 0 ? "\nAll \(checks) checks passed." : "\n\(failures) of \(checks) checks FAILED.")
print("Samples: \(outputDirectory.path)")
exit(failures == 0 ? 0 : 1)
