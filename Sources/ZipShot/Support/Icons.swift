import AppKit
import SwiftUI

/// ZipShot's line icons, drawn from the design's own paths so they match it
/// exactly at any size.
struct ZIcon: View {
    enum Kind {
        case logo, region, window, screen, record
        case crop, border, arrow, text, pixels
        case check, play, pause, stop, dot, close
    }

    let kind: Kind
    var size: CGFloat = 16

    var body: some View {
        Canvas { ctx, canvasSize in
            let box = kind.box
            ctx.scaleBy(x: canvasSize.width / box, y: canvasSize.height / box)
            let round = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            let plain = StrokeStyle(lineWidth: 1.5)
            switch kind {
            case .logo:
                ctx.stroke(Path(IconPaths.logo), with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            case .region:
                ctx.stroke(
                    Path(roundedRect: CGRect(x: 2.5, y: 2.5, width: 11, height: 11), cornerRadius: 1.5),
                    with: .foreground, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2])
                )
            case .window:
                ctx.stroke(Path(roundedRect: CGRect(x: 2, y: 3, width: 12, height: 10), cornerRadius: 1.5), with: .foreground, style: plain)
                ctx.stroke(Path { $0.move(to: CGPoint(x: 2, y: 6)); $0.addLine(to: CGPoint(x: 14, y: 6)) }, with: .foreground, style: plain)
            case .screen:
                ctx.stroke(Path(roundedRect: CGRect(x: 1.5, y: 2.5, width: 13, height: 8.5), cornerRadius: 1.5), with: .foreground, style: round)
                ctx.stroke(Path {
                    $0.move(to: CGPoint(x: 5.5, y: 14)); $0.addLine(to: CGPoint(x: 10.5, y: 14))
                    $0.move(to: CGPoint(x: 8, y: 11)); $0.addLine(to: CGPoint(x: 8, y: 14))
                }, with: .foreground, style: round)
            case .record:
                ctx.stroke(Path(ellipseIn: CGRect(x: 2, y: 2, width: 12, height: 12)), with: .foreground, style: plain)
                ctx.fill(Path(ellipseIn: CGRect(x: 5.5, y: 5.5, width: 5, height: 5)), with: .foreground)
            case .crop:
                ctx.stroke(Path {
                    $0.move(to: CGPoint(x: 4.5, y: 1.5)); $0.addLine(to: CGPoint(x: 4.5, y: 11.5)); $0.addLine(to: CGPoint(x: 14.5, y: 11.5))
                    $0.move(to: CGPoint(x: 1.5, y: 4.5)); $0.addLine(to: CGPoint(x: 11.5, y: 4.5)); $0.addLine(to: CGPoint(x: 11.5, y: 14.5))
                }, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            case .border:
                ctx.stroke(Path(roundedRect: CGRect(x: 1.5, y: 1.5, width: 13, height: 13), cornerRadius: 2), with: .foreground, style: plain)
                ctx.stroke(Path(roundedRect: CGRect(x: 4.5, y: 4.5, width: 7, height: 7), cornerRadius: 0.5), with: .foreground, style: plain)
            case .arrow:
                ctx.stroke(Path {
                    $0.move(to: CGPoint(x: 2.5, y: 13.5)); $0.addLine(to: CGPoint(x: 13, y: 3))
                    $0.move(to: CGPoint(x: 7, y: 3)); $0.addLine(to: CGPoint(x: 13, y: 3)); $0.addLine(to: CGPoint(x: 13, y: 9))
                }, with: .foreground, style: round)
            case .text:
                ctx.stroke(Path {
                    $0.move(to: CGPoint(x: 3, y: 3.5)); $0.addLine(to: CGPoint(x: 13, y: 3.5))
                    $0.move(to: CGPoint(x: 8, y: 3.5)); $0.addLine(to: CGPoint(x: 8, y: 13))
                }, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            case .pixels:
                for origin in [CGPoint(x: 2, y: 2), CGPoint(x: 10.5, y: 2), CGPoint(x: 6.25, y: 6.25), CGPoint(x: 2, y: 10.5), CGPoint(x: 10.5, y: 10.5)] {
                    ctx.fill(Path(CGRect(origin: origin, size: CGSize(width: 3.5, height: 3.5))), with: .foreground)
                }
            case .check:
                ctx.stroke(Path {
                    $0.move(to: CGPoint(x: 2.5, y: 7.5)); $0.addLine(to: CGPoint(x: 5.5, y: 10.5)); $0.addLine(to: CGPoint(x: 11.5, y: 3.5))
                }, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            case .play:
                ctx.fill(Path {
                    $0.move(to: CGPoint(x: 2.5, y: 1.5)); $0.addLine(to: CGPoint(x: 2.5, y: 10.5)); $0.addLine(to: CGPoint(x: 10.5, y: 6)); $0.closeSubpath()
                }, with: .foreground)
            case .pause:
                ctx.fill(Path(roundedRect: CGRect(x: 2, y: 1.5, width: 3, height: 9), cornerRadius: 0.5), with: .foreground)
                ctx.fill(Path(roundedRect: CGRect(x: 7, y: 1.5, width: 3, height: 9), cornerRadius: 0.5), with: .foreground)
            case .stop:
                ctx.fill(Path(roundedRect: CGRect(x: 1.5, y: 1.5, width: 9, height: 9), cornerRadius: 1.5), with: .foreground)
            case .dot:
                ctx.fill(Path(ellipseIn: CGRect(x: 1, y: 1, width: 10, height: 10)), with: .foreground)
            case .close:
                ctx.stroke(Path {
                    $0.move(to: CGPoint(x: 3, y: 3)); $0.addLine(to: CGPoint(x: 11, y: 11))
                    $0.move(to: CGPoint(x: 11, y: 3)); $0.addLine(to: CGPoint(x: 3, y: 11))
                }, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension ZIcon.Kind {
    /// The side of the square each icon's coordinates are written in.
    var box: CGFloat {
        switch self {
        case .check, .close: return 14
        case .play, .pause, .stop, .dot: return 12
        default: return 16
        }
    }
}

enum IconPaths {
    /// Viewfinder corners around a small bolt, in a 16-unit box with y pointing down.
    static let logo: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 2, y: 5))
        p.addLine(to: CGPoint(x: 2, y: 3))
        p.addArc(tangent1End: CGPoint(x: 2, y: 2), tangent2End: CGPoint(x: 3, y: 2), radius: 1)
        p.addLine(to: CGPoint(x: 5, y: 2))

        p.move(to: CGPoint(x: 11, y: 2))
        p.addLine(to: CGPoint(x: 13, y: 2))
        p.addArc(tangent1End: CGPoint(x: 14, y: 2), tangent2End: CGPoint(x: 14, y: 3), radius: 1)
        p.addLine(to: CGPoint(x: 14, y: 5))

        p.move(to: CGPoint(x: 14, y: 11))
        p.addLine(to: CGPoint(x: 14, y: 13))
        p.addArc(tangent1End: CGPoint(x: 14, y: 14), tangent2End: CGPoint(x: 13, y: 14), radius: 1)
        p.addLine(to: CGPoint(x: 11, y: 14))

        p.move(to: CGPoint(x: 5, y: 14))
        p.addLine(to: CGPoint(x: 3, y: 14))
        p.addArc(tangent1End: CGPoint(x: 2, y: 14), tangent2End: CGPoint(x: 2, y: 13), radius: 1)
        p.addLine(to: CGPoint(x: 2, y: 11))

        p.move(to: CGPoint(x: 9, y: 4.5))
        p.addLine(to: CGPoint(x: 6, y: 8.5))
        p.addLine(to: CGPoint(x: 10, y: 8.5))
        p.addLine(to: CGPoint(x: 7, y: 11.5))
        return p
    }()

    /// The menu bar icon. With no color it is a template image that follows
    /// the menu bar's own appearance.
    static func statusImage(color: NSColor? = nil, recording: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 1, y: 1)
            if recording {
                ctx.setFillColor((color ?? .black).cgColor)
                ctx.setStrokeColor((color ?? .black).cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: CGRect(x: 2, y: 2, width: 12, height: 12))
                ctx.fillEllipse(in: CGRect(x: 5.5, y: 5.5, width: 5, height: 5))
            } else {
                ctx.addPath(logo)
                ctx.setStrokeColor((color ?? .black).cgColor)
                ctx.setLineWidth(1.6)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            }
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}
