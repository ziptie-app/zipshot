// Draws ZipShot's app icon into an .iconset folder:
//   swift Scripts/make-icon.swift build/AppIcon.iconset
// build-app.sh runs this and hands the folder to iconutil.

import AppKit

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1
    )
}

/// The viewfinder-and-bolt mark, in a 16-unit box with y pointing down.
func mark() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 2, y: 5)); p.addLine(to: CGPoint(x: 2, y: 3))
    p.addArc(tangent1End: CGPoint(x: 2, y: 2), tangent2End: CGPoint(x: 3, y: 2), radius: 1)
    p.addLine(to: CGPoint(x: 5, y: 2))
    p.move(to: CGPoint(x: 11, y: 2)); p.addLine(to: CGPoint(x: 13, y: 2))
    p.addArc(tangent1End: CGPoint(x: 14, y: 2), tangent2End: CGPoint(x: 14, y: 3), radius: 1)
    p.addLine(to: CGPoint(x: 14, y: 5))
    p.move(to: CGPoint(x: 14, y: 11)); p.addLine(to: CGPoint(x: 14, y: 13))
    p.addArc(tangent1End: CGPoint(x: 14, y: 14), tangent2End: CGPoint(x: 13, y: 14), radius: 1)
    p.addLine(to: CGPoint(x: 11, y: 14))
    p.move(to: CGPoint(x: 5, y: 14)); p.addLine(to: CGPoint(x: 3, y: 14))
    p.addArc(tangent1End: CGPoint(x: 2, y: 14), tangent2End: CGPoint(x: 2, y: 13), radius: 1)
    p.addLine(to: CGPoint(x: 2, y: 11))
    p.move(to: CGPoint(x: 9, y: 4.5)); p.addLine(to: CGPoint(x: 6, y: 8.5))
    p.addLine(to: CGPoint(x: 10, y: 8.5)); p.addLine(to: CGPoint(x: 7, y: 11.5))
    return p
}

func render(_ pixels: Int) -> Data? {
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let s = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: s, y: -s)

    // The standard macOS icon plate: 824pt square on a 1024pt canvas.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1E1F22))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [color(0x34373D), color(0x1A1B1E)] as CFArray, locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.minY), end: CGPoint(x: 0, y: plate.maxY), options: [])
    ctx.restoreGState()

    ctx.addPath(shape)
    ctx.setStrokeColor(color(0x4A4E55))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // The mark, in the accent color.
    let unit: CGFloat = 36
    ctx.translateBy(x: 512 - 8 * unit, y: 512 - 8 * unit)
    ctx.scaleBy(x: unit, y: unit)
    ctx.addPath(mark())
    ctx.setStrokeColor(color(0xC6F24E))
    ctx.setLineWidth(1.6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

for (name, pixels) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    guard let data = render(pixels) else { continue }
    try? data.write(to: output.appendingPathComponent(name + ".png"))
}
