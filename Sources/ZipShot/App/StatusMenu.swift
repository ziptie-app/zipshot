import AppKit
import Carbon.HIToolbox
import SwiftUI

enum MenuCommand: Hashable {
    case capture(CaptureAction)
    case recent(UUID)
    case openDesktop
    case settings
    case quit
}

@MainActor
final class MenuModel: ObservableObject {
    @Published var highlighted: MenuCommand?
    @Published var isRecording = false
    /// The menu bar has no visible room for the icon.
    @Published var iconHidden = false
}

/// The menu bar icon and the dropdown under it.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var panel: MenuPanel?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var lastClosed = Date.distantPast
    let model = MenuModel()

    func install() {
        makeItem()
        // Give the menu bar a moment to place the icon, then see where it landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.checkPlacement(mayMove: true) }
    }

    private func makeItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Self.autosaveName
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.toolTip = "ZipShot"
        item.button?.setAccessibilityLabel("ZipShot menu")
        statusItem = item
        refreshIcon()
    }

    private static let autosaveName = "ZipShot"
    private static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
    /// Points from the right edge of the screen: past the clock and Control Center.
    private static let rescuePosition = 300

    /// True when the menu bar is so full that the icon was given a slot behind
    /// the notch, where it cannot be seen or clicked. (An icon parked off
    /// screen by a menu bar organizer is that organizer's business.)
    private var isBehindNotch: Bool {
        guard let frame = statusItem?.button?.window?.frame,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }),
              let visibleArea = screen.auxiliaryTopRightArea
        else { return false }
        return frame.minX < visibleArea.minX
    }

    /// New icons go to the left end of the row, which on a full menu bar is
    /// behind the notch. Then take a slot near the right end instead, the same
    /// as if it had been ⌘-dragged there; another icon gives way.
    private func checkPlacement(mayMove: Bool) {
        guard isBehindNotch else {
            model.iconHidden = false
            // Releasing the icon that was replaced erases the saved position; put it back.
            if !mayMove, UserDefaults.standard.object(forKey: Self.positionKey) == nil {
                UserDefaults.standard.set(Self.rescuePosition, forKey: Self.positionKey)
            }
            return
        }
        guard mayMove, let item = statusItem else {
            // macOS would not move it. Say so rather than leave nothing to see.
            model.iconHidden = true
            SettingsWindowController.show()
            return
        }
        close()
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        UserDefaults.standard.set(Self.rescuePosition, forKey: Self.positionKey)
        makeItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.checkPlacement(mayMove: false) }
    }

    func refreshIcon() {
        let recording = CaptureController.shared.isRecordingActive
        if recording {
            statusItem?.button?.image = IconPaths.statusImage(color: NSColor(hex: 0xFF6B5E), recording: true)
        } else {
            statusItem?.button?.image = IconPaths.statusImage(color: panel == nil ? nil : .zAccent)
        }
    }

    @objc private func toggle() {
        if panel != nil {
            close()
        } else if Date().timeIntervalSince(lastClosed) > 0.3 {
            // (A click on the icon while the menu is open may already have closed
            // it as a click "elsewhere"; that same click must not reopen it.)
            open()
        }
    }

    private var commands: [MenuCommand] {
        [.capture(.region), .capture(.window), .capture(.screen), .capture(.record)]
            + Library.shared.items.map { .recent($0.id) }
            + [.openDesktop, .settings, .quit]
    }

    private func open() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        model.highlighted = nil
        model.isRecording = CaptureController.shared.isRecordingActive

        let view = MenuView(model: model, library: Library.shared, prefs: Prefs.shared) { [weak self] command in
            self?.run(command)
        }
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = MenuPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.contentView = host
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        CaptureExclusion.add(panel)

        // Hang below the icon, right edges aligned, kept on screen. Menu bar
        // organizers can park the icon far off screen; then hang from the top
        // right corner instead.
        let anchor = buttonWindow.frame
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.underMouse
        let area = screen.frame
        let onScreen = area.intersects(anchor)
        let right = onScreen ? anchor.maxX : area.maxX - 10
        let top = onScreen ? anchor.minY : screen.visibleFrame.maxY
        let x = min(max(right - size.width, area.minX + 10), area.maxX - size.width - 10)
        panel.setFrameOrigin(CGPoint(x: x.rounded(), y: (top - 6 - size.height).rounded()))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        refreshIcon()
        button.highlight(true)

        // Any click elsewhere closes the menu, in other apps or in our own windows.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                // A click on the menu bar icon is handled by its own toggle.
                if event.window !== panel && event.window !== self.statusItem?.button?.window { self.close() }
            }
            return event
        }) { monitors.append(local) }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        lastClosed = Date()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel.orderOut(nil)
        // Often called from a click inside the menu: let that click finish first.
        DispatchQueue.main.async { _ = panel }
        statusItem?.button?.highlight(false)
        refreshIcon()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case ",": run(.settings); return true
            case "q": run(.quit); return true
            default: return false
            }
        }
        let all = commands
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
        case kVK_DownArrow:
            let i = model.highlighted.flatMap { all.firstIndex(of: $0) } ?? -1
            model.highlighted = all[min(i + 1, all.count - 1)]
        case kVK_UpArrow:
            let i = model.highlighted.flatMap { all.firstIndex(of: $0) } ?? all.count
            model.highlighted = all[max(i - 1, 0)]
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            if let command = model.highlighted { run(command) }
        default:
            return false
        }
        return true
    }

    private func run(_ command: MenuCommand) {
        close()
        // Let the menu leave the screen before anything captures it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            switch command {
            case .capture(let action):
                CaptureController.shared.perform(action)
            case .recent(let id):
                if let item = Library.shared.items.first(where: { $0.id == id }) { EditorWindows.open(item) }
            case .openDesktop:
                NSWorkspace.shared.open(Library.desktop)
            case .settings:
                SettingsWindowController.show()
            case .quit:
                NSApp.terminate(nil)
            }
        }
    }
}

private final class MenuPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only ⌘ shortcuts arrive here first; everything else comes through keyDown.
        if event.modifierFlags.contains(.command), onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

struct MenuView: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var library: Library
    @ObservedObject var prefs: Prefs
    var run: (MenuCommand) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 2) {
            row(.capture(.region), icon: .region, title: "Capture region", shortcut: prefs.shortcutLabel(.region))
            row(.capture(.window), icon: .window, title: "Capture window", shortcut: prefs.shortcutLabel(.window))
            row(.capture(.screen), icon: .screen, title: "Capture full screen", shortcut: prefs.shortcutLabel(.screen))
            divider
            row(
                .capture(.record), icon: model.isRecording ? .stop : .record,
                title: model.isRecording ? "Stop recording" : "Record region to GIF",
                shortcut: prefs.shortcutLabel(.record)
            )
            divider
            if !library.items.isEmpty {
                Text("RECENT")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.44)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                ForEach(library.items) { item in
                    RecentRow(item: item, highlighted: model.highlighted == .recent(item.id))
                        .onHover { if $0 { model.highlighted = .recent(item.id) } }
                        .onTapGesture { run(.recent(item.id)) }
                }
                divider
            }
            row(.openDesktop, icon: nil, title: "Open Desktop folder", shortcut: nil)
            row(.settings, icon: nil, title: "Shortcuts and settings…", shortcut: "⌘,")
            row(.quit, icon: nil, title: "Quit ZipShot", shortcut: "⌘Q")
            Text("Every capture is copied to the clipboard and saved to Desktop.")
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .hairline(.top)
                .padding(.top, 4)
        }
        .padding(6)
        .frame(width: 328)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
        .onHover { if !$0 { model.highlighted = nil } }
        .preferredColorScheme(.dark)
    }

    private var divider: some View {
        Theme.line.frame(height: 1).padding(.horizontal, 6).padding(.vertical, 4)
    }

    private func row(_ command: MenuCommand, icon: ZIcon.Kind?, title: String, shortcut: String?) -> some View {
        let on = model.highlighted == command
        return HStack(spacing: 10) {
            if let icon { ZIcon(kind: icon) }
            Text(title).font(.system(size: 13, weight: on ? .medium : .regular))
            Spacer(minLength: 8)
            if let shortcut {
                Text(shortcut).font(Theme.mono(12)).foregroundStyle(on ? Theme.onAccent : Theme.muted)
            }
        }
        .foregroundStyle(on ? Theme.onAccent : Theme.text)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.accent : .clear))
        .contentShape(Rectangle())
        .onHover { if $0 { model.highlighted = command } }
        .onTapGesture { run(command) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct RecentRow: View {
    @ObservedObject var item: CaptureItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Theme.fill
                if let image = item.thumbnail {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 44, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.outline, lineWidth: 1))
            Text(item.fileName).font(Theme.mono(12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(item.kind == .gif ? "Trim" : "Edit")
                .font(.system(size: 12))
                .foregroundStyle(highlighted ? Theme.onAccent : Theme.muted)
        }
        .foregroundStyle(highlighted ? Theme.onAccent : Theme.text)
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Theme.accent : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
