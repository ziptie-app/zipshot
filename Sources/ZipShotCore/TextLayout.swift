import AppKit

/// Text annotations are laid out and drawn with AppKit string drawing so the
/// rendered result lines up with the NSTextView used to type them.
public enum TextLayout {
    public static func font(size: CGFloat) -> NSFont {
        .systemFont(ofSize: max(1, size), weight: .bold)
    }

    public static func attributes(color: RGBAColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: font(size: fontSize),
            .foregroundColor: NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a),
        ]
    }

    private static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
    private static let unbounded = CGSize(width: 100_000, height: 100_000)

    public static func size(of t: TextShape) -> CGSize {
        // An empty string still occupies one line, so there is something to hit.
        let string = t.text.isEmpty ? " " : t.text
        let attributed = NSAttributedString(string: string, attributes: attributes(color: t.color, fontSize: t.fontSize))
        let r = attributed.boundingRect(with: unbounded, options: options)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// Draws into a context whose y axis points down.
    public static func draw(_ t: TextShape, in ctx: CGContext) {
        guard !t.text.isEmpty else { return }
        let attributed = NSAttributedString(string: t.text, attributes: attributes(color: t.color, fontSize: t.fontSize))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attributed.draw(with: CGRect(origin: t.origin, size: unbounded), options: options)
        NSGraphicsContext.current = previous
    }
}
