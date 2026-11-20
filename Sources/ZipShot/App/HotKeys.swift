import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The combination held in a key-down event, or nil if it would not make a
    /// usable global shortcut (it needs ⌘, ⌃ or ⌥, unless it is a function key).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= Self.command }
        if flags.contains(.shift) { mods |= Self.shift }
        if flags.contains(.option) { mods |= Self.option }
        if flags.contains(.control) { mods |= Self.control }
        let code = UInt32(event.keyCode)
        let isFunctionKey = Self.functionKeys.contains(Int(code))
        guard mods & (Self.command | Self.option | Self.control) != 0 || isFunctionKey else { return nil }
        guard Self.keyNames[Int(code)] != nil else { return nil }
        self.init(keyCode: code, modifiers: mods)
    }

    var keyName: String { Self.keyNames[Int(keyCode)] ?? "Key \(keyCode)" }

    /// For display, in the system's usual order: ⌃⌥⇧⌘ then the key.
    var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + keyName
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
    ]

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]
}

/// System-wide shortcuts via Carbon hot keys, which need no special permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var registered: [(id: UInt32, combo: KeyCombo)] = []
    private var handlerInstalled = false
    private var suspended = false
    private static let signature: OSType = 0x5A53_4854  // 'ZSHT'

    /// IDs whose shortcut could not be registered, usually because another app holds it.
    private(set) var failed: Set<UInt32> = []
    /// Called with `failed` each time the shortcuts are (re)registered.
    var onRegistered: ((Set<UInt32>) -> Void)?

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr else { return status }
            let which = id.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(which) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) {
        guard !suspended else { return }
        handlers[id]?()
    }

    /// Replaces every registered shortcut.
    func set(_ entries: [(id: UInt32, combo: KeyCombo?, handler: () -> Void)]) {
        installHandler()
        unregisterAll()
        handlers.removeAll()
        registered.removeAll()
        for entry in entries {
            handlers[entry.id] = entry.handler
            if let combo = entry.combo { registered.append((entry.id, combo)) }
        }
        if !suspended { registerAll() }
    }

    /// Lets key presses through to the app, for recording a new shortcut.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        registerAll()
    }

    private func registerAll() {
        failed.removeAll()
        for entry in registered {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: entry.id)
            let status = RegisterEventHotKey(entry.combo.keyCode, entry.combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[entry.id] = ref
            } else {
                failed.insert(entry.id)
            }
        }
        onRegistered?(failed)
    }

    private func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }
}
