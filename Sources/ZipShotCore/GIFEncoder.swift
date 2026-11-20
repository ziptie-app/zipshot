import Foundation

public enum GIFError: Error, CustomStringConvertible {
    case invalidSize
    case cannotCreateFile(String)
    case noFrames

    public var description: String {
        switch self {
        case .invalidSize: return "GIF dimensions must be between 1 and 65535 pixels."
        case .cannotCreateFile(let path): return "Could not create \(path)."
        case .noFrames: return "There are no frames to save."
        }
    }
}

/// A streaming GIF89a writer made for screen recordings.
///
/// Each frame stores only the rectangle that changed since the previous one,
/// with unchanged pixels inside it left transparent, and frames that did not
/// change at all just extend the previous frame's delay. Frames go to disk as
/// they are added, so memory use does not grow with the recording's length.
///
/// Pixels are 32-bit little-endian BGRA (the value 0x00RRGGBB); alpha is ignored.
public final class GIFEncoder {
    public let width: Int
    public let height: Int
    public private(set) var frameCount = 0

    private let handle: FileHandle
    private var buffer = Data()
    private var previous: [UInt32]
    private var current: [UInt32]
    private var hasPrevious = false
    private var indices: [UInt8]

    /// The newest frame, held back until its delay is known.
    private var pending: Data?
    private var pendingTransparentIndex: Int?
    /// End time, in seconds, of the newest frame added.
    private var time: Double = 0
    private var emittedCentiseconds = 0

    private let quantizer = Quantizer()
    private let lzw = LZWEncoder()

    public init(url: URL, width: Int, height: Int, loopCount: Int = 0) throws {
        guard (1...65535).contains(width), (1...65535).contains(height) else { throw GIFError.invalidSize }
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: url.path)
        else { throw GIFError.cannotCreateFile(url.path) }
        self.handle = handle
        self.width = width
        self.height = height
        previous = [UInt32](repeating: 0, count: width * height)
        current = [UInt32](repeating: 0, count: width * height)
        indices = [UInt8](repeating: 0, count: width * height)

        buffer.append(contentsOf: Array("GIF89a".utf8))
        appendLE16(width)
        appendLE16(height)
        // No global color table (every frame brings its own), 8 bits of color resolution.
        buffer.append(contentsOf: [0x70, 0x00, 0x00])
        // NETSCAPE2.0 looping extension.
        buffer.append(contentsOf: [0x21, 0xFF, 0x0B])
        buffer.append(contentsOf: Array("NETSCAPE2.0".utf8))
        buffer.append(contentsOf: [0x03, 0x01])
        appendLE16(loopCount)
        buffer.append(0x00)
    }

    /// Adds a frame shown for `delay` seconds.
    public func addFrame(bgra pixels: UnsafePointer<UInt32>, delay: Double) throws {
        let count = width * height
        current.withUnsafeMutableBufferPointer { dst in
            for i in 0..<count { dst[i] = pixels[i] & 0x00FF_FFFF }
        }
        let start = time
        time += max(0, delay)

        if hasPrevious {
            // Nothing changed: the frame on screen simply stays up longer.
            guard let box = changedBox() else { return }
            try flushPending(until: start)
            encode(x: box.x, y: box.y, w: box.w, h: box.h, diff: true)
        } else {
            encode(x: 0, y: 0, w: width, h: height, diff: false)
        }
        swap(&previous, &current)
        hasPrevious = true
    }

    public func finish() throws {
        guard hasPrevious else {
            try? handle.close()
            throw GIFError.noFrames
        }
        try flushPending(until: time)
        buffer.append(0x3B)
        try handle.write(contentsOf: buffer)
        buffer.removeAll()
        try handle.close()
    }

    // MARK: Frames

    private func changedBox() -> (x: Int, y: Int, w: Int, h: Int)? {
        let width = self.width
        let height = self.height
        var minX = width, maxX = -1, minY = -1, maxY = -1
        previous.withUnsafeBufferPointer { p in
            current.withUnsafeBufferPointer { c in
                for y in 0..<height {
                    let rowP = p.baseAddress! + y * width
                    let rowC = c.baseAddress! + y * width
                    if memcmp(rowP, rowC, width * 4) == 0 { continue }
                    var x0 = 0
                    while rowP[x0] == rowC[x0] { x0 += 1 }
                    var x1 = width - 1
                    while rowP[x1] == rowC[x1] { x1 -= 1 }
                    minX = min(minX, x0)
                    maxX = max(maxX, x1)
                    if minY < 0 { minY = y }
                    maxY = y
                }
            }
        }
        guard maxY >= 0 else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    private func encode(x: Int, y: Int, w: Int, h: Int, diff: Bool) {
        let stride = width
        var transparentIndex: Int?
        var palette: [UInt8] = []

        previous.withUnsafeBufferPointer { p in
            current.withUnsafeBufferPointer { c in
                indices.withUnsafeMutableBufferPointer { idx in
                    // Pass 1: the palette covers only the pixels that will be drawn.
                    quantizer.begin()
                    for row in 0..<h {
                        let rowC = c.baseAddress! + (y + row) * stride + x
                        let rowP = p.baseAddress! + (y + row) * stride + x
                        if diff {
                            for col in 0..<w where rowC[col] != rowP[col] { quantizer.add(rowC[col]) }
                        } else {
                            for col in 0..<w { quantizer.add(rowC[col]) }
                        }
                    }
                    palette = quantizer.makePalette(maxColors: diff ? 255 : 256)
                    let colorCount = palette.count / 3
                    if diff { transparentIndex = colorCount }
                    let transparent = UInt8(truncatingIfNeeded: colorCount)

                    // Pass 2: palette indices.
                    var o = 0
                    for row in 0..<h {
                        let rowC = c.baseAddress! + (y + row) * stride + x
                        let rowP = p.baseAddress! + (y + row) * stride + x
                        if diff {
                            for col in 0..<w {
                                idx[o] = rowC[col] == rowP[col] ? transparent : quantizer.index(for: rowC[col])
                                o += 1
                            }
                        } else {
                            for col in 0..<w {
                                idx[o] = quantizer.index(for: rowC[col])
                                o += 1
                            }
                        }
                    }
                    quantizer.end()
                }
            }
        }

        let entries = palette.count / 3 + (diff ? 1 : 0)
        var bits = 1
        while (1 << bits) < entries { bits += 1 }

        var data = Data()
        data.append(0x2C)
        Self.appendLE16(x, to: &data)
        Self.appendLE16(y, to: &data)
        Self.appendLE16(w, to: &data)
        Self.appendLE16(h, to: &data)
        data.append(0x80 | UInt8(bits - 1))  // local color table of 2^bits entries
        data.append(contentsOf: palette)
        data.append(contentsOf: [UInt8](repeating: 0, count: (1 << bits) * 3 - palette.count))
        let minCodeSize = max(2, bits)
        data.append(UInt8(minCodeSize))
        indices.withUnsafeBufferPointer { idx in
            lzw.encode(UnsafeBufferPointer(rebasing: idx[0..<(w * h)]), minCodeSize: minCodeSize, into: &data)
        }
        data.append(0x00)

        pending = data
        pendingTransparentIndex = transparentIndex
    }

    private func flushPending(until end: Double) throws {
        guard let frame = pending else { return }
        // Delays are whole centiseconds; track the running total so rounding
        // never accumulates. Below 2cs most viewers substitute a slow default.
        var centis = Int((end * 100).rounded()) - emittedCentiseconds
        centis = min(max(centis, 2), 65535)
        emittedCentiseconds += centis

        // Graphic control extension: leave each frame in place for the next to draw over.
        buffer.append(contentsOf: [0x21, 0xF9, 0x04])
        buffer.append(0x04 | (pendingTransparentIndex == nil ? 0x00 : 0x01))
        appendLE16(centis)
        buffer.append(UInt8(pendingTransparentIndex ?? 0))
        buffer.append(0x00)
        buffer.append(frame)
        pending = nil
        frameCount += 1

        if buffer.count > 1 << 20 {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private func appendLE16(_ value: Int) { Self.appendLE16(value, to: &buffer) }

    private static func appendLE16(_ value: Int, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }
}

// MARK: - Color quantization

/// Reduces a frame to at most 256 colors with a median cut over an 18-bit
/// (6 bits per channel) histogram.
final class Quantizer {
    private static let binCount = 1 << 18

    private let counts: UnsafeMutablePointer<UInt32>
    private let sums: UnsafeMutablePointer<UInt64>  // r, g, b per bin
    private let lut: UnsafeMutablePointer<UInt8>
    private var touched: [Int32] = []

    init() {
        counts = .allocate(capacity: Self.binCount)
        counts.initialize(repeating: 0, count: Self.binCount)
        sums = .allocate(capacity: Self.binCount * 3)
        sums.initialize(repeating: 0, count: Self.binCount * 3)
        lut = .allocate(capacity: Self.binCount)
        lut.initialize(repeating: 0, count: Self.binCount)
    }

    deinit {
        counts.deallocate()
        sums.deallocate()
        lut.deallocate()
    }

    @inline(__always) private static func bin(_ p: UInt32) -> Int {
        let r: UInt32 = (p >> 18) & 0x3F
        let g: UInt32 = (p >> 10) & 0x3F
        let b: UInt32 = (p >> 2) & 0x3F
        return Int((r << 12) | (g << 6) | b)
    }

    func begin() { touched.removeAll(keepingCapacity: true) }

    @inline(__always) func add(_ p: UInt32) {
        let b = Self.bin(p)
        if counts[b] == 0 { touched.append(Int32(b)) }
        counts[b] += 1
        sums[b * 3] += UInt64((p >> 16) & 0xFF)
        sums[b * 3 + 1] += UInt64((p >> 8) & 0xFF)
        sums[b * 3 + 2] += UInt64(p & 0xFF)
    }

    /// Valid between `makePalette` and `end`, for colors that were added.
    @inline(__always) func index(for p: UInt32) -> UInt8 { lut[Self.bin(p)] }

    /// Clears the histogram, touching only the bins that were used.
    func end() {
        for b in touched {
            let i = Int(b)
            counts[i] = 0
            sums[i * 3] = 0
            sums[i * 3 + 1] = 0
            sums[i * 3 + 2] = 0
        }
        touched.removeAll(keepingCapacity: true)
    }

    private func appendAverage(of bin: Int, to palette: inout [UInt8]) {
        let n = UInt64(counts[bin])
        palette.append(UInt8((sums[bin * 3] + n / 2) / n))
        palette.append(UInt8((sums[bin * 3 + 1] + n / 2) / n))
        palette.append(UInt8((sums[bin * 3 + 2] + n / 2) / n))
    }

    private struct Box {
        var lo: Int
        var hi: Int
        var count: UInt64
        var axis: Int
        var score: Double
    }

    private func makeBox(_ order: [Int32], _ lo: Int, _ hi: Int) -> Box {
        var mins = [63, 63, 63]
        var maxs = [0, 0, 0]
        var total: UInt64 = 0
        for k in lo..<hi {
            let b = Int(order[k])
            let c = [(b >> 12) & 0x3F, (b >> 6) & 0x3F, b & 0x3F]
            for a in 0..<3 {
                if c[a] < mins[a] { mins[a] = c[a] }
                if c[a] > maxs[a] { maxs[a] = c[a] }
            }
            total += UInt64(counts[b])
        }
        var axis = 0
        var span = 0
        for a in 0..<3 where maxs[a] - mins[a] > span {
            span = maxs[a] - mins[a]
            axis = a
        }
        // Prefer splitting boxes that are both wide and well populated.
        let score = (hi - lo < 2 || span == 0) ? 0 : Double(span) * Double(total).squareRoot()
        return Box(lo: lo, hi: hi, count: total, axis: axis, score: score)
    }

    /// RGB triples. Every added color maps to an entry afterwards.
    func makePalette(maxColors: Int) -> [UInt8] {
        var palette: [UInt8] = []
        if touched.count <= maxColors {
            palette.reserveCapacity(touched.count * 3)
            for (i, b) in touched.enumerated() {
                appendAverage(of: Int(b), to: &palette)
                lut[Int(b)] = UInt8(i)
            }
            return palette
        }

        var order = touched
        var boxes = [makeBox(order, 0, order.count)]
        while boxes.count < maxColors {
            var best = -1
            var bestScore = 0.0
            for (i, box) in boxes.enumerated() where box.score > bestScore {
                bestScore = box.score
                best = i
            }
            guard best >= 0 else { break }
            let box = boxes[best]
            let shift = 12 - box.axis * 6
            order[box.lo..<box.hi].sort { (($0 >> shift) & 0x3F) < (($1 >> shift) & 0x3F) }
            // Split at the weighted median, keeping both halves non-empty.
            let half = box.count / 2
            var acc: UInt64 = 0
            var split = box.lo + 1
            for k in box.lo..<box.hi {
                acc += UInt64(counts[Int(order[k])])
                if acc >= half {
                    split = k + 1
                    break
                }
            }
            split = min(max(split, box.lo + 1), box.hi - 1)
            boxes[best] = makeBox(order, box.lo, split)
            boxes.append(makeBox(order, split, box.hi))
        }

        palette.reserveCapacity(boxes.count * 3)
        for (i, box) in boxes.enumerated() {
            var dominant = Int(order[box.lo])
            var r: UInt64 = 0, g: UInt64 = 0, b: UInt64 = 0
            for k in box.lo..<box.hi {
                let bin = Int(order[k])
                if counts[bin] > counts[dominant] { dominant = bin }
                r += sums[bin * 3]
                g += sums[bin * 3 + 1]
                b += sums[bin * 3 + 2]
                lut[bin] = UInt8(i)
            }
            if UInt64(counts[dominant]) * 2 >= box.count {
                // One color owns the box (a flat UI surface, typically). Keep it
                // exact so it matches the same surface in neighbouring frames.
                appendAverage(of: dominant, to: &palette)
            } else {
                let n = box.count
                palette.append(UInt8((r + n / 2) / n))
                palette.append(UInt8((g + n / 2) / n))
                palette.append(UInt8((b + n / 2) / n))
            }
        }
        return palette
    }
}

// MARK: - LZW

/// GIF-flavoured LZW: variable code width from `minCodeSize + 1` up to 12 bits,
/// least significant bit first, output split into sub-blocks of at most 255 bytes.
final class LZWEncoder {
    private static let tableSize = 8192  // power of two, at most half full
    private let keys: UnsafeMutablePointer<Int32>
    private let values: UnsafeMutablePointer<UInt16>
    private var bytes: [UInt8] = []

    init() {
        keys = .allocate(capacity: Self.tableSize)
        values = .allocate(capacity: Self.tableSize)
        values.initialize(repeating: 0, count: Self.tableSize)
        keys.initialize(repeating: -1, count: Self.tableSize)
    }

    deinit {
        keys.deallocate()
        values.deallocate()
    }

    func encode(_ pixels: UnsafeBufferPointer<UInt8>, minCodeSize: Int, into out: inout Data) {
        bytes.removeAll(keepingCapacity: true)
        var acc: UInt32 = 0
        var accBits = 0
        let clear = 1 << minCodeSize
        let endOfInformation = clear + 1
        var next = endOfInformation + 1
        var codeSize = minCodeSize + 1

        func emit(_ code: Int) {
            acc |= UInt32(code) << UInt32(accBits)
            accBits += codeSize
            while accBits >= 8 {
                bytes.append(UInt8(acc & 0xFF))
                acc >>= 8
                accBits -= 8
            }
        }
        func resetTable() {
            keys.update(repeating: -1, count: Self.tableSize)
            next = endOfInformation + 1
            codeSize = minCodeSize + 1
        }

        resetTable()
        emit(clear)
        if pixels.count > 0 {
            var prefix = Int(pixels[0])
            for i in 1..<pixels.count {
                let c = Int(pixels[i])
                let key = Int32(prefix << 8 | c)
                var slot = Int((UInt32(bitPattern: key) &* 0x9E37_79B1) >> 19)
                var found = -1
                while true {
                    let k = keys[slot]
                    if k == key {
                        found = Int(values[slot])
                        break
                    }
                    if k < 0 { break }
                    slot = (slot + 1) & (Self.tableSize - 1)
                }
                if found >= 0 {
                    prefix = found
                    continue
                }
                emit(prefix)
                if next < 4096 {
                    keys[slot] = key
                    values[slot] = UInt16(next)
                    // The decoder widens its codes once this entry exists on its side.
                    if next == (1 << codeSize) && codeSize < 12 { codeSize += 1 }
                    next += 1
                } else {
                    emit(clear)
                    resetTable()
                }
                prefix = c
            }
            emit(prefix)
            // The decoder adds one more entry after that last code, which can widen
            // the code it expects next.
            if next == (1 << codeSize) && codeSize < 12 { codeSize += 1 }
        }
        emit(endOfInformation)
        if accBits > 0 { bytes.append(UInt8(acc & 0xFF)) }

        var offset = 0
        while offset < bytes.count {
            let n = min(255, bytes.count - offset)
            out.append(UInt8(n))
            bytes.withUnsafeBufferPointer { out.append($0.baseAddress! + offset, count: n) }
            offset += n
        }
    }
}
