import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// Captures the next key combination typed, for changing a shortcut.
@MainActor
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()

    @Published private(set) var recording: CaptureAction?
    /// Actions whose shortcut macOS refused, usually because another app has it.
    @Published var unavailable: Set<CaptureAction> = []
    private var monitor: Any?

    func toggle(_ action: CaptureAction) {
        if recording == action { stop() } else { start(action) }
    }

    private func start(_ action: CaptureAction) {
        stop()
        recording = action
        // Our own shortcuts must not fire while a new one is being typed.
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        HotKeyCenter.shared.resume()
    }

    private func handle(_ event: NSEvent) {
        guard let action = recording else { return }
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plain, Int(event.keyCode) == kVK_Escape { return stop() }
        if plain, Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete {
            Prefs.shared.hotKeys[action] = nil
            return stop()
        }
        guard let combo = KeyCombo(event: event) else { return NSSound.beep() }
        var keys = Prefs.shared.hotKeys
        // A combination can only belong to one action.
        for other in CaptureAction.allCases where other != action && keys[other] == combo { keys[other] = nil }
        keys[action] = combo
        Prefs.shared.hotKeys = keys
        stop()
    }
}

struct ZToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(Theme.text)
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 12)
                Capsule()
                    .fill(isOn ? Theme.accent : Theme.fill)
                    .frame(width: 36, height: 20)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(isOn ? Theme.onAccent : Theme.text).frame(width: 16, height: 16).padding(2)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject var menu: MenuModel
    var titlebarHeight: CGFloat = 28
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip(title: "Shortcuts and settings", height: titlebarHeight).hairline(.bottom)
            VStack(alignment: .leading, spacing: 24) {
                if menu.iconHidden {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ZipShot's menu bar icon is hidden").fontWeight(.semibold).foregroundStyle(Theme.text)
                        Text("The menu bar is full. The shortcuts below still work. To make room, hold ⌘ and drag an icon you don't need off the menu bar, then open ZipShot again.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.window))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.record, lineWidth: 1))
                }
                section("Shortcuts") {
                    ForEach(CaptureAction.allCases, id: \.self) { action in
                        shortcutRow(action)
                    }
                    Text("Click a shortcut, then type the new one. Delete clears it, Esc cancels.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                section("After a capture") {
                    ZToggle(title: "Show a notice with Edit and Show file", isOn: $prefs.showToast)
                    ZToggle(title: "Play sounds", isOn: $prefs.playSounds)
                }
                section("GIF recording") {
                    HStack {
                        Text("Frames per second").foregroundStyle(Theme.text)
                        Spacer()
                        ZSegmented(
                            options: [(10, "10"), (15, "15"), (24, "24"), (30, "30")],
                            selection: $prefs.gifFPS
                        )
                        .frame(width: 200)
                    }
                    ZToggle(
                        title: "Record at full Retina resolution",
                        detail: "Sharper, but files are about four times larger.",
                        isOn: $prefs.gifRetina
                    )
                    ZToggle(title: "Show the pointer", isOn: $prefs.recordCursor)
                }
                section("General") {
                    ZToggle(
                        title: "Open ZipShot at login",
                        detail: loginError,
                        isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })
                    )
                }
                Text("Every capture is copied to the clipboard and saved to Desktop.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13))
            .padding(24)
        }
        .frame(width: 480)
        .background(Theme.panel)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: title)
            content()
        }
    }

    private func shortcutRow(_ action: CaptureAction) -> some View {
        let isRecording = recorder.recording == action
        let combo = prefs.hotKeys[action]
        return HStack(spacing: 10) {
            ZIcon(kind: icon(action)).foregroundStyle(Theme.text)
            Text(action.title).foregroundStyle(Theme.text)
            if recorder.unavailable.contains(action), !isRecording {
                Text("In use by another app").font(.system(size: 12)).foregroundStyle(Theme.record)
            }
            Spacer(minLength: 12)
            Button {
                recorder.toggle(action)
            } label: {
                Text(isRecording ? "Type shortcut…" : (combo?.display ?? "None"))
                    .font(isRecording ? .system(size: 12) : Theme.mono(12))
                    .foregroundStyle(isRecording ? Theme.onAccent : (combo == nil ? Theme.muted : Theme.text))
                    .frame(minWidth: 108)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isRecording ? Theme.accent : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isRecording ? .clear : Theme.outline, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shortcut for \(action.title)")
        }
    }

    private func icon(_ action: CaptureAction) -> ZIcon.Kind {
        switch action {
        case .region: return .region
        case .window: return .window
        case .screen: return .screen
        case .record: return .record
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS wouldn't change this: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    static func show() {
        if let existing = shared, let window = existing.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SettingsWindowController()
        shared = controller
        if let window = controller.window { AppWindows.present(window) }
    }

    init() {
        let window = ZWindow.make(
            title: "ZipShot Settings", contentSize: CGSize(width: 480, height: 560),
            minSize: CGSize(width: 480, height: 300), resizable: false
        )
        super.init(window: window)
        let host = NSHostingView(rootView: SettingsView(
            prefs: Prefs.shared, recorder: ShortcutRecorder.shared, menu: StatusItemController.shared.model,
            titlebarHeight: window.titlebarHeight
        ))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        ShortcutRecorder.shared.stop()
        // Called while the window is still closing; release it afterwards.
        let controller = Self.shared
        Self.shared = nil
        DispatchQueue.main.async { _ = controller }
        AppWindows.closed()
    }
}
