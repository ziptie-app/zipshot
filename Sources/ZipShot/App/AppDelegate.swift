import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One menu bar icon is plenty.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }
        removeStaleRecordings()
        NSApp.mainMenu = MainMenu.build()
        StatusItemController.shared.install()

        HotKeyCenter.shared.onRegistered = { failed in
            ShortcutRecorder.shared.unavailable = Set(CaptureAction.allCases.filter { failed.contains($0.hotKeyID) })
        }
        Prefs.shared.$hotKeys
            .sink { keys in
                HotKeyCenter.shared.set(CaptureAction.allCases.map { action in
                    (id: action.hotKeyID, combo: keys[action], handler: { CaptureController.shared.perform(action) })
                })
            }
            .store(in: &observers)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again while it is running (from Finder, Spotlight, the
    /// Dock) shows Settings, so there is always a way in even if the menu bar
    /// icon is hidden behind the notch or by a menu bar organizer.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { SettingsWindowController.show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        EditorWindows.flushAll()
        Library.shared.releaseAll()
    }

    /// Frame files from a session that ended without cleaning up.
    private func removeStaleRecordings() {
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names where name.hasPrefix("zipshot-frames-") && name.hasSuffix(".bin") {
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.show()
    }
}

/// The app's menu bar menus. They are only visible while an editor or the
/// settings window is open, but their key equivalents (⌘Z, ⌘C, ⌘W…) are what
/// make those shortcuts work.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About ZipShot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide ZipShot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit ZipShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, titled: "ZipShot", to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, titled: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: "Edit", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
