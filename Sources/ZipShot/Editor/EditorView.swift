import AppKit
import SwiftUI
import ZipShotCore

struct CanvasHost: NSViewRepresentable {
    let model: EditorModel
    var onCreate: (CanvasView) -> Void = { _ in }

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView(model: model)
        onCreate(view)
        return view
    }

    func updateNSView(_ nsView: CanvasView, context: Context) {}
}

/// The capture editor: tools along the top, the capture in the middle, the
/// current tool's settings on the right.
struct EditorView: View {
    @ObservedObject var model: EditorModel
    var titlebarHeight: CGFloat = 28
    var onCanvas: (CanvasView) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip(title: model.item.fileName, height: titlebarHeight)
            toolbar
            HStack(spacing: 0) {
                CanvasHost(model: model, onCreate: onCanvas)
                    .frame(minWidth: 360, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
                InspectorView(model: model)
            }
            statusBar
        }
        .background(Theme.window)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(EditorTool.allCases) { tool in
                    let selected = model.tool == tool
                    Button {
                        model.tool = tool
                    } label: {
                        HStack(spacing: 8) {
                            ZIcon(kind: tool.icon)
                            Text(tool.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        }
                        .foregroundStyle(selected ? Theme.onAccent : Theme.text)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.title) (\(tool.key.uppercased()))")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button("Undo") { model.undo() }
                    .buttonStyle(ZButtonStyle(kind: .outlined))
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .buttonStyle(ZButtonStyle(kind: .outlined))
                    .disabled(!model.canRedo)
                Button(model.justCopied ? "Copied" : "Copy") { model.copyToClipboard() }
                    .buttonStyle(ZButtonStyle(kind: .light, padding: 16))
                    .help("Copy the edited capture (⌘C)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.panel)
        .hairline(.top, color: Theme.window)
        .hairline(.bottom)
    }

    private var statusBar: some View {
        HStack {
            if let error = model.saveError {
                Text("Couldn't save: \(error)").foregroundStyle(Theme.record)
            } else {
                Text("Edits save automatically to Desktop")
            }
            Spacer()
            let size = model.outputSize
            Text(verbatim: "\(Int(size.width)) × \(Int(size.height)) · PNG").font(Theme.mono(12))
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.panel)
        .hairline(.top)
    }
}

struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.tool {
            case .crop: crop
            case .border: border
            case .arrow: arrow
            case .text: text
            case .blur: blur
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .hairline(.leading)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).foregroundStyle(Theme.muted)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func gesture(_ editing: Bool) {
        if editing { model.beginGesture() } else { model.endGesture() }
    }

    private func pixels(_ points: Double) -> String { "\(Int((points * Double(model.scale)).rounded())) px" }

    // MARK: Tools

    @ViewBuilder private var border: some View {
        let b = model.state.border
        SectionTitle(title: "Border")
        field("Fill") {
            ZSegmented(
                options: [(BorderFill.color, "Color"), (BorderFill.blur, "Blur")],
                selection: Binding(get: { b.fill }, set: { model.setBorderFill($0) })
            )
        }
        field("Color") {
            SwatchRow(swatches: Theme.borderSwatches, selection: b.color) { model.setBorderColor($0) }
        }
        ZSlider(
            label: "Thickness",
            value: Binding(get: { Double(b.thickness) }, set: { model.setBorderThickness($0) }),
            range: 0...(96 * Double(model.scale)), step: Double(model.scale),
            valueText: "\(Int(b.thickness)) px", onEditing: gesture
        )
        ZSlider(
            label: "Blur strength",
            value: Binding(get: { Double(b.blurStrength) }, set: { model.setBorderBlur($0) }),
            range: 0...100,
            valueText: b.fill == .blur ? "\(Int(b.blurStrength))" : "Blur fill only",
            enabled: b.fill == .blur, onEditing: gesture
        )
    }

    @ViewBuilder private var arrow: some View {
        SectionTitle(title: "Arrow")
        field("Color") {
            SwatchRow(swatches: Theme.annotationSwatches, selection: model.arrowColor) { model.setArrowColor($0) }
        }
        ZSlider(
            label: "Thickness",
            value: Binding(get: { model.arrowThickness }, set: { model.setArrowThickness($0) }),
            range: 1...16, valueText: pixels(model.arrowThickness), onEditing: gesture
        )
        note("Drag to draw an arrow. Hold ⇧ for straight angles. Click an arrow to move it or drag its ends; Delete removes it.")
    }

    @ViewBuilder private var text: some View {
        SectionTitle(title: "Text")
        field("Color") {
            SwatchRow(swatches: Theme.annotationSwatches, selection: model.textColor) { model.setTextColor($0) }
        }
        ZSlider(
            label: "Size",
            value: Binding(get: { model.textSize }, set: { model.setTextSize($0) }),
            range: 10...72, valueText: pixels(model.textSize), onEditing: gesture
        )
        note("Click to add text, then click away or press Esc when done. Double-click text to change it; drag to move it.")
    }

    @ViewBuilder private var blur: some View {
        SectionTitle(title: "Pixel blur")
        field("Style") {
            ZSegmented(
                options: [(BlurStyle.pixelate, "Pixelate"), (BlurStyle.gaussian, "Smooth")],
                selection: Binding(get: { model.blurStyle }, set: { model.setBlurStyle($0) })
            )
        }
        ZSlider(
            label: model.blurStyle == .pixelate ? "Block size" : "Strength",
            value: Binding(get: { model.blurStrength }, set: { model.setBlurStrength($0) }),
            range: 3...40, valueText: pixels(model.blurStrength), onEditing: gesture
        )
        note("Drag over anything you want hidden. Click a blurred area to move it or drag its corners; Delete removes it.")
    }

    @ViewBuilder private var crop: some View {
        let c = model.state.crop
        SectionTitle(title: "Crop")
        HStack {
            Text("Size").foregroundStyle(Theme.muted)
            Spacer()
            Text(verbatim: "\(Int(c.width)) × \(Int(c.height)) px").font(Theme.mono(12)).foregroundStyle(Theme.text)
        }
        note("Drag the frame or its handles. Drag outside the frame to start a new one.")
        HStack(spacing: 8) {
            Button("Reset") { model.resetCrop() }
                .buttonStyle(ZButtonStyle(kind: .outlined))
                .disabled(c == model.imageBounds)
            Button("Done") { model.leaveCrop() }
                .buttonStyle(ZButtonStyle(kind: .accent, padding: 16))
        }
    }
}
