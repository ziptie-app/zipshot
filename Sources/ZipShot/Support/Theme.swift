import AppKit
import SwiftUI
import ZipShotCore

/// Colors and metrics shared by every ZipShot surface. The app is always dark.
enum Theme {
    static let window = Color(hex: 0x1E1F22)
    static let panel = Color(hex: 0x26282C)
    static let line = Color(hex: 0x3A3D43)
    static let outline = Color(hex: 0x5B5F67)
    static let fill = Color(hex: 0x4A4E55)
    static let text = Color(hex: 0xF2F3F5)
    static let muted = Color(hex: 0xB4B8C0)
    static let ink = Color(hex: 0x15161A)
    static let accent = Color(hex: 0xC6F24E)
    static let onAccent = Color(hex: 0x161A08)
    static let record = Color(hex: 0xFF6B5E)
    static let idle = Color(hex: 0x8E939B)
    /// Dims everything outside a selection.
    static let scrim = Color(red: 10 / 255, green: 12 / 255, blue: 14 / 255, opacity: 0.6)

    static let accentRGBA = RGBAColor(hex: 0xC6F24E)
    static let annotationRed = RGBAColor(hex: 0xE5484D)

    /// Swatches offered for the border; annotations get red first.
    static let borderSwatches: [RGBAColor] = [
        RGBAColor(hex: 0xC6F24E), RGBAColor(hex: 0xFFFFFF), RGBAColor(hex: 0x0E0F11),
        RGBAColor(hex: 0x3E7BFA), RGBAColor(hex: 0xF7B955),
    ]
    static let annotationSwatches: [RGBAColor] = [
        RGBAColor(hex: 0xE5484D), RGBAColor(hex: 0xC6F24E), RGBAColor(hex: 0xFFFFFF),
        RGBAColor(hex: 0x0E0F11), RGBAColor(hex: 0x3E7BFA),
    ]

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    init(_ c: RGBAColor) {
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    convenience init(_ c: RGBAColor) {
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    static let zWindow = NSColor(hex: 0x1E1F22)
    static let zPanel = NSColor(hex: 0x26282C)
    static let zInk = NSColor(hex: 0x15161A)
    static let zAccent = NSColor(hex: 0xC6F24E)
    static let zOnAccent = NSColor(hex: 0x161A08)
    static let zText = NSColor(hex: 0xF2F3F5)
    static let zScrim = NSColor(srgbRed: 10 / 255, green: 12 / 255, blue: 14 / 255, alpha: 0.6)
}

extension RGBAColor {
    init(hex: UInt32) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255
        )
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor(hex: 0xFFFFFF)
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    /// Close enough to count as the same swatch.
    func matches(_ other: RGBAColor) -> Bool {
        abs(r - other.r) < 0.004 && abs(g - other.g) < 0.004 && abs(b - other.b) < 0.004
    }

    var packed: [Double] { [r, g, b, a] }

    init?(packed: [Double]?) {
        guard let p = packed, p.count == 4 else { return nil }
        self.init(r: p[0], g: p[1], b: p[2], a: p[3])
    }
}

// MARK: - Buttons

struct ZButtonStyle: ButtonStyle {
    enum Kind {
        case accent    // the main action
        case light     // the main action on surfaces where accent means "selected"
        case record
        case outlined
        case ghost
    }

    var kind: Kind = .outlined
    var height: CGFloat = 40
    var radius: CGFloat = 8
    var padding: CGFloat = 12
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let filled = kind == .accent || kind == .light || kind == .record
        configuration.label
            .font(.system(size: height <= 30 ? 12 : 13, weight: filled ? .semibold : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, padding)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius).fill(background))
            .overlay {
                if kind == .outlined {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.outline, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.75 : 1))
    }

    private var foreground: Color {
        switch kind {
        case .accent: return Theme.onAccent
        case .light, .record: return Theme.window
        case .outlined, .ghost: return Theme.text
        }
    }

    private var background: Color {
        switch kind {
        case .accent: return Theme.accent
        case .light: return Theme.text
        case .record: return Theme.record
        case .outlined, .ghost: return .clear
        }
    }
}

// MARK: - Small pieces

/// A key name in a rounded chip, as used in hint bars.
struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.line))
    }
}

struct Hint: Identifiable {
    let id = UUID()
    var key: String?
    var lead: String?
    var text: String
    var dimmed = false
}

/// The pill of keyboard hints along the bottom of capture overlays.
struct HintBar: View {
    let hints: [Hint]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(hints) { hint in
                HStack(spacing: 6) {
                    if let key = hint.key { Keycap(label: key) }
                    if let lead = hint.lead { Text(lead).foregroundStyle(Theme.muted) }
                    Text(hint.text).foregroundStyle(hint.dimmed ? Theme.muted : Theme.text)
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Capsule().fill(Theme.ink))
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        .fixedSize()
    }
}

/// Uppercase heading for a group of controls.
struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.44)
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A two-or-more way choice in a recessed track.
struct ZSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.text : Theme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.fill : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.window))
    }
}

/// A labelled slider with its value shown in monospace on the right.
struct ZSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var valueText: String
    var enabled = true
    /// Called with true when a drag starts and false when it ends.
    var onEditing: (Bool) -> Void = { _ in }

    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).foregroundStyle(Theme.muted)
                Spacer()
                Text(valueText)
                    .font(Theme.mono(12))
                    .foregroundStyle(enabled ? Theme.text : Theme.muted)
            }
            GeometryReader { geo in
                let knob: CGFloat = 16
                let span = max(1, geo.size.width - knob)
                let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                let x = min(max(fraction, 0), 1) * span
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line).frame(height: 4)
                    Capsule().fill(enabled ? Theme.accent : Theme.outline).frame(width: x + knob / 2, height: 4)
                    Circle()
                        .fill(enabled ? Theme.text : Theme.outline)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: x)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard enabled else { return }
                            if !dragging {
                                dragging = true
                                onEditing(true)
                            }
                            let f = Double(min(max((g.location.x - knob / 2) / span, 0), 1))
                            let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                            let stepped = (raw / step).rounded() * step
                            let next = min(max(stepped, range.lowerBound), range.upperBound)
                            if next != value { value = next }
                        }
                        .onEnded { _ in
                            guard dragging else { return }
                            dragging = false
                            onEditing(false)
                        }
                )
            }
            .frame(height: 18)
        }
        .font(.system(size: 13))
        .opacity(enabled ? 1 : 0.7)
    }
}

/// Round color swatches plus a dashed "+" that opens the system color panel.
struct SwatchRow: View {
    let swatches: [RGBAColor]
    let selection: RGBAColor
    let onPick: (RGBAColor) -> Void

    var body: some View {
        let isCustom = !swatches.contains { $0.matches(selection) }
        HStack(spacing: 8) {
            ForEach(Array(swatches.enumerated()), id: \.offset) { _, swatch in
                let selected = swatch.matches(selection)
                Button {
                    onPick(swatch)
                } label: {
                    Circle()
                        .fill(Color(swatch))
                        .overlay(Circle().strokeBorder(selected ? Theme.text : ring(for: swatch), lineWidth: 2))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            Button {
                ColorPanelBridge.shared.pick(initial: selection, onChange: onPick)
            } label: {
                ZStack {
                    if isCustom {
                        Circle().fill(Color(selection))
                        Circle().strokeBorder(Theme.text, lineWidth: 2)
                    } else {
                        Circle().strokeBorder(Theme.muted, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                        Text("+").font(.system(size: 16)).foregroundStyle(Theme.text).offset(y: -1)
                    }
                }
                .frame(width: 32, height: 32)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Custom color")
        }
    }

    /// Dark swatches need a visible edge against the panel.
    private func ring(for c: RGBAColor) -> Color {
        (c.r + c.g + c.b) / 3 < 0.25 ? Theme.outline : Theme.panel
    }
}

/// Routes the shared NSColorPanel's changes to whichever swatch row opened it.
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((RGBAColor) -> Void)?

    func pick(initial: RGBAColor, onChange: @escaping (RGBAColor) -> Void) {
        let panel = NSColorPanel.shared
        self.onChange = nil  // setting the color below must not echo back
        panel.showsAlpha = false
        panel.color = NSColor(initial)
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.isContinuous = true
        self.onChange = onChange
        panel.orderFront(nil)
    }

    func detach() { onChange = nil }

    @objc private func changed(_ sender: NSColorPanel) {
        onChange?(RGBAColor(sender.color))
    }
}

/// The top strip of ZipShot's windows: the file name, centered, in monospace.
struct TitleStrip: View {
    let title: String
    let height: CGFloat

    var body: some View {
        Text(title)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .padding(.horizontal, 80)  // clear of the window buttons
            .background(Theme.panel)
    }
}

extension View {
    func hairline(_ edge: Edge, color: Color = Theme.line) -> some View {
        overlay(alignment: edge == .top ? .top : edge == .bottom ? .bottom : edge == .leading ? .leading : .trailing) {
            if edge == .top || edge == .bottom {
                color.frame(height: 1)
            } else {
                color.frame(width: 1)
            }
        }
    }
}
