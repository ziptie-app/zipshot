import CoreGraphics
import Foundation

// All geometry in the edit model is in image pixels with a top-left origin
// (y grows downward), independent of any crop or border.

public struct RGBAColor: Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    public static let red = RGBAColor(r: 1.0, g: 0.231, b: 0.188)
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let black = RGBAColor(r: 0, g: 0, b: 0)
}

public struct ArrowShape: Equatable, Sendable {
    public var start: CGPoint
    public var end: CGPoint
    public var color: RGBAColor
    public var thickness: CGFloat

    public init(start: CGPoint, end: CGPoint, color: RGBAColor, thickness: CGFloat) {
        self.start = start
        self.end = end
        self.color = color
        self.thickness = thickness
    }

    public var length: CGFloat { hypot(end.x - start.x, end.y - start.y) }
}

public struct TextShape: Equatable, Sendable {
    /// Top-left corner of the text block.
    public var origin: CGPoint
    public var text: String
    public var color: RGBAColor
    public var fontSize: CGFloat

    public init(origin: CGPoint, text: String, color: RGBAColor, fontSize: CGFloat) {
        self.origin = origin
        self.text = text
        self.color = color
        self.fontSize = fontSize
    }
}

public enum BlurStyle: String, CaseIterable, Sendable {
    case pixelate
    case gaussian
}

public struct BlurShape: Equatable, Sendable {
    public var rect: CGRect
    public var style: BlurStyle
    /// Pixelate: block edge in pixels. Gaussian: blur sigma in pixels.
    public var strength: CGFloat

    public init(rect: CGRect, style: BlurStyle, strength: CGFloat) {
        self.rect = rect
        self.style = style
        self.strength = strength
    }
}

public enum Shape: Equatable, Sendable {
    case arrow(ArrowShape)
    case text(TextShape)
    case blur(BlurShape)
}

public struct Annotation: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var shape: Shape

    public init(id: UUID = UUID(), shape: Shape) {
        self.id = id
        self.shape = shape
    }
}

public enum BorderFill: String, CaseIterable, Sendable {
    case color
    /// A blurred, enlarged copy of the capture itself.
    case blur
}

public struct Border: Equatable, Sendable {
    public var fill: BorderFill
    public var color: RGBAColor
    /// Width of the border on each side, in pixels. Zero means no border.
    public var thickness: CGFloat
    /// 0...100, used by the blur fill only.
    public var blurStrength: CGFloat

    public init(fill: BorderFill = .color, color: RGBAColor = .white, thickness: CGFloat = 0, blurStrength: CGFloat = 40) {
        self.fill = fill
        self.color = color
        self.thickness = thickness
        self.blurStrength = blurStrength
    }

    /// The width actually added on each side, in whole pixels.
    public var inset: CGFloat { max(0, thickness.rounded()) }
}

/// Everything the editor changes. The captured image itself is never modified.
public struct EditState: Equatable, Sendable {
    public var annotations: [Annotation]
    public var crop: CGRect
    public var border: Border

    public init(imageSize: CGSize) {
        annotations = []
        crop = CGRect(origin: .zero, size: imageSize)
        border = Border()
    }

    public func index(of id: UUID) -> Int? { annotations.firstIndex { $0.id == id } }
}

extension CGRect {
    /// A rect from two arbitrary corner points.
    public init(corner a: CGPoint, opposite b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Whole-pixel rect inside `bounds`, at least 1x1.
    public func pixelAligned(within bounds: CGRect) -> CGRect {
        var r = CGRect(
            x: minX.rounded(), y: minY.rounded(),
            width: (maxX.rounded() - minX.rounded()), height: (maxY.rounded() - minY.rounded())
        ).intersection(bounds)
        if r.isNull || r.isEmpty {
            let x = min(max(minX.rounded(), bounds.minX), bounds.maxX - 1)
            let y = min(max(minY.rounded(), bounds.minY), bounds.maxY - 1)
            r = CGRect(x: x, y: y, width: 1, height: 1)
        }
        return r
    }
}

// MARK: - Hit testing and handles

public enum Handle: Equatable, Sendable {
    case arrowStart
    case arrowEnd
    /// Corner of a rect, clockwise from top-left: 0 TL, 1 TR, 2 BR, 3 BL.
    case corner(Int)
}

public func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

extension CGRect {
    /// Corners clockwise from top-left (in a y-down space).
    public var corners: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }

    /// The rect after dragging corner `index` to `p`, the opposite corner staying put.
    public func movingCorner(_ index: Int, to p: CGPoint) -> CGRect {
        CGRect(corner: p, opposite: corners[(index + 2) % 4])
    }
}

extension Annotation {
    public var bounds: CGRect {
        switch shape {
        case .arrow(let a):
            return CGRect(corner: a.start, opposite: a.end).insetBy(dx: -a.thickness * 2, dy: -a.thickness * 2)
        case .text(let t):
            return CGRect(origin: t.origin, size: TextLayout.size(of: t))
        case .blur(let b):
            return b.rect
        }
    }

    /// `tolerance` is the slop, in image pixels, allowed around thin shapes.
    public func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch shape {
        case .arrow(let a):
            return distance(from: p, toSegment: a.start, a.end) <= max(a.thickness * 1.5, tolerance)
        case .text, .blur:
            return bounds.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p)
        }
    }

    public var handles: [(handle: Handle, point: CGPoint)] {
        switch shape {
        case .arrow(let a):
            return [(.arrowStart, a.start), (.arrowEnd, a.end)]
        case .blur(let b):
            return b.rect.corners.enumerated().map { (.corner($0.offset), $0.element) }
        case .text:
            return []
        }
    }

    public mutating func translate(by d: CGSize) {
        switch shape {
        case .arrow(var a):
            a.start.x += d.width; a.start.y += d.height
            a.end.x += d.width; a.end.y += d.height
            shape = .arrow(a)
        case .text(var t):
            t.origin.x += d.width; t.origin.y += d.height
            shape = .text(t)
        case .blur(var b):
            b.rect.origin.x += d.width; b.rect.origin.y += d.height
            shape = .blur(b)
        }
    }

    public mutating func move(_ handle: Handle, to p: CGPoint) {
        switch (shape, handle) {
        case (.arrow(var a), .arrowStart):
            a.start = p
            shape = .arrow(a)
        case (.arrow(var a), .arrowEnd):
            a.end = p
            shape = .arrow(a)
        case (.blur(var b), .corner(let i)):
            b.rect = b.rect.movingCorner(i, to: p)
            shape = .blur(b)
        default:
            break
        }
    }
}

/// Snaps `p` so the line from `anchor` runs at a multiple of 45 degrees.
public func snapTo45(_ p: CGPoint, from anchor: CGPoint) -> CGPoint {
    let dx = p.x - anchor.x
    let dy = p.y - anchor.y
    let len = hypot(dx, dy)
    guard len > 0 else { return p }
    let step = CGFloat.pi / 4
    let angle = (atan2(dy, dx) / step).rounded() * step
    return CGPoint(x: anchor.x + cos(angle) * len, y: anchor.y + sin(angle) * len)
}
