import AppKit
import SwiftUI

/// The small card in the corner after a capture: what happened, with Edit and Show file.
@MainActor
final class ToastController {
    static let shared = ToastController()

    private var panel: NSPanel?
    private var timer: Timer?
    private var hovering = false

    func show(_ item: CaptureItem, on screen: NSScreen) {
        dismiss(animated: false)

        let view = ToastView(
            item: item,
            onEdit: { [weak self] in
                self?.dismiss(animated: false)
                EditorWindows.open(item)
            },
            onShowFile: { [weak self] in
                self?.dismiss(animated: true)
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            },
            onClose: { [weak self] in self?.dismiss(animated: true) },
            onHover: { [weak self] inside in
                self?.hovering = inside
                if !inside { self?.scheduleDismiss(after: 2.5) }
            }
        )
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        CaptureExclusion.add(panel)

        let area = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: area.maxX - size.width - 20, y: area.minY + 20))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        hovering = false
        scheduleDismiss(after: 6)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hovering else { return }
                self.dismiss(animated: true)
            }
        }
    }

    func dismiss(animated: Bool) {
        timer?.invalidate()
        timer = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.orderOut(nil)
            // Usually called from one of the toast's own buttons: let that click finish first.
            DispatchQueue.main.async { _ = panel }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

struct ToastView: View {
    @ObservedObject var item: CaptureItem
    var onEdit: () -> Void = {}
    var onShowFile: () -> Void = {}
    var onClose: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ZIcon(kind: .check, size: 14).foregroundStyle(Theme.accent)
                    Text("Copied to clipboard").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                }
                Text("Saved to Desktop").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text(item.fileName).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Button(item.kind == .gif ? "Trim" : "Edit", action: onEdit)
                        .buttonStyle(ZButtonStyle(kind: .accent, height: 28, radius: 6, padding: 14))
                    Button("Show file", action: onShowFile)
                        .buttonStyle(ZButtonStyle(kind: .outlined, height: 28, radius: 6, padding: 12))
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onClose) {
                    ZIcon(kind: .close, size: 10).foregroundStyle(Theme.muted).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Dismiss")
            }
        }
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .preferredColorScheme(.dark)
    }

    private var thumbnail: some View {
        ZStack {
            Color(hex: 0xECEDEF)
            if let image = item.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 96, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.outline, lineWidth: 1))
    }
}
