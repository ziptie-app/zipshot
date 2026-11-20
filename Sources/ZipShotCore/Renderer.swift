import AppKit
import CoreImage

/// Draws a capture with its edits applied. One renderer per captured image;
/// the image is never modified, so every edit stays reversible.
///
/// All drawing methods expect a context whose unit is one image pixel and
/// whose y axis points down.
public final class Renderer: @unchecked Sendable {
    public let base: CGImage
    public let size: CGSize
    public let colorSpace: CGColorSpace

    private let ciContext: CIContext
    private let lock = NSLock()
    private var blurCache: [BlurKey: BlurPatch] = [:]
    private var backdropCache: (key: BackdropKey, image: CGImage)?

    private struct BlurKey: Hashable {
        let x: Int, y: Int, w: Int, h: Int
        let style: BlurStyle
        let strength: Int
    }

    private struct BackdropKey: Equatable {
        let x: Int, y: Int, w: Int, h: Int
        let strength: Int
    }

    private struct BlurPatch {
        let image: CGImage
        let rect: CGRect
        /// Pixelated patches are scaled up with hard edges; gaussian ones smoothly.
        let smooth: Bool
    }

    public init(base: CGImage) {
        self.base = base
        size = CGSize(width: base.width, height: base.height)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        if let cs = base.colorSpace, cs.model == .rgb, cs.supportsOutput {
            colorSpace = cs
        } else {
            colorSpace = srgb
        }
        ciContext = CIContext(options: [.cacheIntermediates: false])
    }

    public var bounds: CGRect { CGRect(origin: .zero, size: size) }

    // MARK: Output

    public func outputSize(for state: EditState) -> CGSize {
        let t = state.border.inset
        return CGSize(width: state.crop.width + 2 * t, height: state.crop.height + 2 * t)
    }

    /// The finished image: cropped, annotated, with its border.
    public func render(_ state: EditState) -> CGImage? {
        let out = outputSize(for: state)
        guard let ctx = makeContext(width: Int(out.width), height: Int(out.height)) else { return nil }
        ctx.translateBy(x: 0, y: out.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        drawScene(state, in: ctx)
        return ctx.makeImage()
    }

    private func makeContext(width: Int, height: Int, opaque: Bool = false) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: alpha.rawValue
        )
    }

    // MARK: Drawing

    /// Border plus cropped content, with the scene's top-left corner at the origin.
    public func drawScene(_ state: EditState, in ctx: CGContext, skipping skipped: UUID? = nil, proxy: CGImage? = nil) {
        let t = state.border.inset
        let crop = state.crop
        let outer = CGRect(x: 0, y: 0, width: crop.width + 2 * t, height: crop.height + 2 * t)

        if t > 0 {
            switch state.border.fill {
            case .color:
                ctx.setFillColor(state.border.color.cgColor)
                ctx.fill(outer)
            case .blur:
                if let backdrop = backdrop(crop: crop, strength: state.border.blurStrength) {
                    // Aspect-fill the outer rect so the blurred copy bleeds past every edge.
                    let s = max(outer.width / crop.width, outer.height / crop.height)
                    let w = crop.width * s
                    let h = crop.height * s
                    let dest = CGRect(x: outer.midX - w / 2, y: outer.midY - h / 2, width: w, height: h)
                    ctx.saveGState()
                    ctx.clip(to: outer)
                    ctx.interpolationQuality = .high
                    Self.draw(backdrop, in: dest, ctx: ctx)
                    ctx.restoreGState()
                }
            }
        }

        ctx.saveGState()
        ctx.clip(to: CGRect(x: t, y: t, width: crop.width, height: crop.height))
        ctx.translateBy(x: t - crop.minX, y: t - crop.minY)
        drawContent(state, in: ctx, skipping: skipped, proxy: proxy)
        ctx.restoreGState()
    }

    /// The whole captured image with its annotations, ignoring crop and border.
    /// `proxy` is an optional scaled-down copy of the capture to draw in its
    /// place, for fast on-screen display; blurs are still taken from the original.
    public func drawContent(_ state: EditState, in ctx: CGContext, skipping skipped: UUID? = nil, proxy: CGImage? = nil) {
        Self.draw(proxy ?? base, in: bounds, ctx: ctx)
        for annotation in state.annotations where annotation.id != skipped {
            switch annotation.shape {
            case .blur(let b):
                guard let patch = blurPatch(for: b) else { continue }
                ctx.saveGState()
                ctx.interpolationQuality = patch.smooth ? .high : .none
                // Replace rather than blend, so see-through pixels stay hidden too.
                ctx.setBlendMode(.copy)
                Self.draw(patch.image, in: patch.rect, ctx: ctx)
                ctx.restoreGState()
            case .arrow(let a):
                Self.drawArrow(a, in: ctx)
            case .text(let t):
                TextLayout.draw(t, in: ctx)
            }
        }
    }

    /// Draws an image upright in a y-down context.
    public static func draw(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    public static func drawArrow(_ a: ArrowShape, in ctx: CGContext) {
        let len = a.length
        guard len > 0.5 else { return }
        let ux = (a.end.x - a.start.x) / len
        let uy = (a.end.y - a.start.y) / len
        // An open chevron head: two strokes back from the tip.
        let head = min(len * 0.5, max(a.thickness * 5, 10))
        let spread = CGFloat.pi * 32 / 180
        func arm(_ angle: CGFloat) -> CGPoint {
            let bx = -ux * cos(angle) + uy * sin(angle)
            let by = -ux * sin(angle) - uy * cos(angle)
            return CGPoint(x: a.end.x + bx * head, y: a.end.y + by * head)
        }
        ctx.saveGState()
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(max(1, a.thickness))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: a.start)
        ctx.addLine(to: a.end)
        ctx.move(to: arm(spread))
        ctx.addLine(to: a.end)
        ctx.addLine(to: arm(-spread))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Blur patches

    private func blurPatch(for b: BlurShape) -> BlurPatch? {
        let r = b.rect.standardized.integral.intersection(bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        let key = BlurKey(
            x: Int(r.minX), y: Int(r.minY), w: Int(r.width), h: Int(r.height),
            style: b.style, strength: Int((b.strength * 4).rounded())
        )
        lock.lock()
        let cached = blurCache[key]
        lock.unlock()
        if let cached { return cached }

        guard let crop = base.cropping(to: r) else { return nil }
        var patch: BlurPatch?
        switch b.style {
        case .pixelate:
            // Average each block by scaling down, then scale back up unsmoothed.
            let block = max(2, b.strength.rounded())
            let cols = max(1, Int((r.width / block).rounded(.up)))
            let rows = max(1, Int((r.height / block).rounded(.up)))
            if let ctx = makeContext(width: cols, height: rows) {
                ctx.interpolationQuality = .high
                ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cols, height: rows))
                if let image = ctx.makeImage() {
                    patch = BlurPatch(image: image, rect: r, smooth: false)
                }
            }
        case .gaussian:
            let input = CIImage(cgImage: crop)
            let output = input.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(max(0.5, b.strength)))
                .cropped(to: input.extent)
            if let image = ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: colorSpace) {
                patch = BlurPatch(image: image, rect: r, smooth: true)
            }
        }
        if let patch {
            lock.lock()
            if blurCache.count > 48 { blurCache.removeAll() }
            blurCache[key] = patch
            lock.unlock()
        }
        return patch
    }

    // MARK: Blur border backdrop

    /// A blurred copy of the cropped capture, kept small because it only ever
    /// holds low frequencies. Built from the capture alone (no annotations) so
    /// it can be cached while annotations are being dragged around.
    private func backdrop(crop: CGRect, strength: CGFloat) -> CGImage? {
        let key = BackdropKey(
            x: Int(crop.minX), y: Int(crop.minY), w: Int(crop.width), h: Int(crop.height),
            strength: Int(strength.rounded())
        )
        lock.lock()
        let cached = backdropCache
        lock.unlock()
        if let cached, cached.key == key { return cached.image }

        guard let cropped = base.cropping(to: crop) else { return nil }
        let longest = max(crop.width, crop.height)
        let scale = min(1, 1024 / longest)
        let w = max(1, Int((crop.width * scale).rounded()))
        let h = max(1, Int((crop.height * scale).rounded()))
        guard let ctx = makeContext(width: w, height: h, opaque: true) else { return nil }
        // Window captures have see-through corners; give them something to sit on.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard var image = ctx.makeImage() else { return nil }

        let sigma = Double(max(0, min(100, strength)) / 100 * 0.10 * CGFloat(max(w, h)))
        if sigma >= 0.3 {
            let input = CIImage(cgImage: image)
            let output = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
            if let blurred = ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: colorSpace) {
                image = blurred
            }
        }
        lock.lock()
        backdropCache = (key, image)
        lock.unlock()
        return image
    }
}

// MARK: - PNG

public enum PNGWriter {
    /// `scale` is the display scale the capture was taken at (2 on Retina); it is
    /// recorded as DPI so the image opens at its on-screen size.
    public static func data(for image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        let dpi = 72 * max(1, scale)
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
