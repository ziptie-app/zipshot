import Compression
import CoreGraphics
import Foundation

public enum FrameStoreError: Error {
    case cannotCreateFile
    case writeFailed
    case readFailed
    case badIndex
}

/// Recorded frames, kept losslessly in a temporary file instead of in memory.
///
/// Each frame is tightly packed 32-bit BGRA, LZ4-compressed. Frames identical
/// to the one before are dropped; their time is absorbed by that earlier frame,
/// which is all a GIF needs. The file is deleted when the store goes away.
public final class FrameStore: @unchecked Sendable {
    public struct Frame: Sendable {
        let offset: UInt64
        let length: Int
        let compressed: Bool
        /// Seconds from the start of the recording at which the frame appears.
        public let time: TimeInterval
    }

    public let width: Int
    public let height: Int
    public let url: URL

    private let fd: Int32
    private let lock = NSLock()
    private var storedFrames: [Frame] = []
    private var storedDuration: TimeInterval = 0
    private var writeOffset: UInt64 = 0
    private var hasLast = false
    private let last: UnsafeMutableRawPointer
    private let packed: UnsafeMutableRawPointer
    private let scratch: UnsafeMutablePointer<UInt8>
    private let scratchCapacity: Int

    public var frameBytes: Int { width * height * 4 }

    public init(width: Int, height: Int, directory: URL = FileManager.default.temporaryDirectory) throws {
        self.width = width
        self.height = height
        url = directory.appendingPathComponent("zipshot-frames-\(UUID().uuidString).bin")
        fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw FrameStoreError.cannotCreateFile }
        let bytes = width * height * 4
        last = .allocate(byteCount: bytes, alignment: 16)
        packed = .allocate(byteCount: bytes, alignment: 16)
        scratchCapacity = bytes + bytes / 200 + 1024
        scratch = .allocate(capacity: scratchCapacity)
    }

    deinit {
        close(fd)
        unlink(url.path)
        last.deallocate()
        packed.deallocate()
        scratch.deallocate()
    }

    // MARK: Reading the timeline

    public var frames: [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames
    }

    public var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames.count
    }

    /// Total length of the recording; the last frame is shown until then.
    public var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return storedDuration
    }

    public var fileSize: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return writeOffset
    }

    /// The frame on screen at `time`.
    public func frameIndex(at time: TimeInterval) -> Int {
        let frames = self.frames
        var lo = 0
        var hi = frames.count - 1
        var result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if frames[mid].time <= time {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    // MARK: Writing

    /// Appends a frame. Returns false when it matched the previous frame and was dropped.
    @discardableResult
    public func append(bgra source: UnsafeRawPointer, bytesPerRow: Int, time: TimeInterval) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let rowBytes = width * 4
        var tight = source
        if bytesPerRow != rowBytes {
            for y in 0..<height {
                memcpy(packed + y * rowBytes, source + y * bytesPerRow, rowBytes)
            }
            tight = UnsafeRawPointer(packed)
        }
        if hasLast, memcmp(last, tight, frameBytes) == 0 {
            storedDuration = max(storedDuration, time)
            return false
        }

        let typed = tight.assumingMemoryBound(to: UInt8.self)
        let encoded = compression_encode_buffer(scratch, scratchCapacity, typed, frameBytes, nil, COMPRESSION_LZ4)
        let compressed = encoded > 0 && encoded < frameBytes
        let length = compressed ? encoded : frameBytes
        let bytes = compressed ? UnsafeRawPointer(scratch) : tight
        var written = 0
        while written < length {
            let n = pwrite(fd, bytes + written, length - written, off_t(writeOffset) + off_t(written))
            guard n > 0 else { throw FrameStoreError.writeFailed }
            written += n
        }
        storedFrames.append(Frame(offset: writeOffset, length: length, compressed: compressed, time: time))
        writeOffset += UInt64(length)
        storedDuration = max(storedDuration, time)
        memcpy(last, tight, frameBytes)
        hasLast = true
        return true
    }

    /// Marks the end of the recording.
    public func finish(duration: TimeInterval) {
        lock.lock()
        storedDuration = max(duration, storedFrames.last?.time ?? 0)
        lock.unlock()
    }

    // MARK: Reading frames

    /// Decodes a frame into `destination`, which must hold `frameBytes` bytes.
    public func read(_ index: Int, into destination: UnsafeMutableRawPointer) throws {
        lock.lock()
        defer { lock.unlock() }
        guard storedFrames.indices.contains(index) else { throw FrameStoreError.badIndex }
        let frame = storedFrames[index]
        let target = frame.compressed ? UnsafeMutableRawPointer(scratch) : destination
        var done = 0
        while done < frame.length {
            let n = pread(fd, target + done, frame.length - done, off_t(frame.offset) + off_t(done))
            guard n > 0 else { throw FrameStoreError.readFailed }
            done += n
        }
        if frame.compressed {
            let decoded = compression_decode_buffer(
                destination.assumingMemoryBound(to: UInt8.self), frameBytes, scratch, frame.length, nil, COMPRESSION_LZ4
            )
            guard decoded == frameBytes else { throw FrameStoreError.readFailed }
        }
    }

    public func image(at index: Int) -> CGImage? {
        var data = Data(count: frameBytes)
        let ok: Bool = data.withUnsafeMutableBytes { raw in
            (try? read(index, into: raw.baseAddress!)) != nil
        }
        guard ok, let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

// MARK: - GIF export

public enum GIFExporter {
    public struct Step: Equatable, Sendable {
        public let frame: Int
        public let delay: TimeInterval

        public init(frame: Int, delay: TimeInterval) {
            self.frame = frame
            self.delay = delay
        }
    }

    /// Which frames to write, and for how long each, to cover `range` of a
    /// recording whose frames appear at `times` and which lasts `duration`.
    public static func plan(times: [TimeInterval], duration: TimeInterval, range: ClosedRange<TimeInterval>) -> [Step] {
        guard !times.isEmpty else { return [] }
        let a = max(0, range.lowerBound)
        let b = min(duration, range.upperBound)
        guard b > a else { return [] }
        // Start with the frame already on screen at `a`.
        var first = 0
        for (i, t) in times.enumerated() where t <= a { first = i }
        var steps: [Step] = []
        for i in first..<times.count {
            if times[i] >= b { break }
            let start = max(times[i], a)
            let end = min(i + 1 < times.count ? times[i + 1] : duration, b)
            // Skip slivers: a range edge that lands on a frame boundary can leave a
            // few nanoseconds of the neighbouring frame, which a GIF would stretch
            // into a visible flash.
            if end - start >= 0.001 { steps.append(Step(frame: i, delay: end - start)) }
        }
        return steps
    }

    /// Writes `range` of the recording to `url`, replacing any file there only
    /// once the new one is complete. `progress` gets 0...1 and returns false to
    /// cancel. Returns false if cancelled.
    @discardableResult
    public static func export(
        store: FrameStore,
        range: ClosedRange<TimeInterval>? = nil,
        to url: URL,
        progress: ((Double) -> Bool)? = nil
    ) throws -> Bool {
        let range = range ?? 0...store.duration
        let steps = plan(times: store.frames.map(\.time), duration: store.duration, range: range)
        guard !steps.isEmpty else { throw GIFError.noFrames }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(CaptureNaming.randomToken(length: 6)).tmp")
        var keepTemp = false
        defer { if !keepTemp { try? FileManager.default.removeItem(at: temp) } }

        let encoder = try GIFEncoder(url: temp, width: store.width, height: store.height)
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: store.frameBytes, alignment: 16)
        defer { pixels.deallocate() }
        for (i, step) in steps.enumerated() {
            try store.read(step.frame, into: pixels)
            try encoder.addFrame(bgra: pixels.assumingMemoryBound(to: UInt32.self), delay: step.delay)
            if let progress, !progress(Double(i + 1) / Double(steps.count)) {
                try? encoder.finish()
                return false
            }
        }
        try encoder.finish()

        if rename(temp.path, url.path) != 0 {
            // Different volume or similar: fall back to a copying replace.
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        }
        keepTemp = true
        return true
    }
}
