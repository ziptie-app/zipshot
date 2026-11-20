import AppKit
import Combine
import ZipShotCore

enum CaptureAction: String, CaseIterable, Codable {
    case region, window, screen, record

    var title: String {
        switch self {
        case .region: return "Capture region"
        case .window: return "Capture window"
        case .screen: return "Capture full screen"
        case .record: return "Record region to GIF"
        }
    }

    var hotKeyID: UInt32 {
        switch self {
        case .region: return 1
        case .window: return 2
        case .screen: return 3
        case .record: return 4
        }
    }
}

/// User settings, stored in UserDefaults.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let defaults: UserDefaults

    /// The developer checks (`--ui-check` and friends) change tool settings as
    /// they go; they get a scratch store so the user's own settings are untouched.
    static let isDeveloperRun = CommandLine.arguments.contains { ["--ui-check", "--ui-snapshots", "--capture-check"].contains($0) }

    @Published var hotKeys: [CaptureAction: KeyCombo] { didSet { saveHotKeys() } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var showToast: Bool { didSet { defaults.set(showToast, forKey: "showToast") } }
    @Published var gifFPS: Int { didSet { defaults.set(gifFPS, forKey: "gifFPS") } }
    @Published var gifRetina: Bool { didSet { defaults.set(gifRetina, forKey: "gifRetina") } }
    @Published var recordCursor: Bool { didSet { defaults.set(recordCursor, forKey: "recordCursor") } }

    static let defaultHotKeys: [CaptureAction: KeyCombo] = [
        .region: KeyCombo(keyCode: 18, modifiers: KeyCombo.option | KeyCombo.shift),  // ⌥⇧1
        .window: KeyCombo(keyCode: 19, modifiers: KeyCombo.option | KeyCombo.shift),  // ⌥⇧2
        .screen: KeyCombo(keyCode: 20, modifiers: KeyCombo.option | KeyCombo.shift),  // ⌥⇧3
        .record: KeyCombo(keyCode: 21, modifiers: KeyCombo.option | KeyCombo.shift),  // ⌥⇧4
    ]

    private init() {
        if Self.isDeveloperRun {
            let suite = "dev.zipshot.ZipShot.checks"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            defaults = .standard
        }
        defaults.register(defaults: [
            "playSounds": true, "showToast": true, "gifFPS": 15, "gifRetina": false, "recordCursor": true,
        ])
        playSounds = defaults.bool(forKey: "playSounds")
        showToast = defaults.bool(forKey: "showToast")
        gifFPS = defaults.integer(forKey: "gifFPS")
        gifRetina = defaults.bool(forKey: "gifRetina")
        recordCursor = defaults.bool(forKey: "recordCursor")

        var keys = Self.defaultHotKeys
        if let data = defaults.data(forKey: "hotKeys"),
           let stored = try? JSONDecoder().decode([String: KeyCombo?].self, from: data) {
            // A stored null means the user cleared that shortcut.
            for action in CaptureAction.allCases {
                if let entry = stored[action.rawValue] { keys[action] = entry }
            }
        }
        hotKeys = keys
    }

    private func saveHotKeys() {
        var stored: [String: KeyCombo?] = [:]
        for action in CaptureAction.allCases { stored[action.rawValue] = .some(hotKeys[action]) }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: "hotKeys") }
    }

    func shortcutLabel(_ action: CaptureAction) -> String? { hotKeys[action]?.display }

    // MARK: Editor tool settings, remembered between captures (in points)

    func color(_ key: String, default fallback: RGBAColor) -> RGBAColor {
        RGBAColor(packed: defaults.array(forKey: key) as? [Double]) ?? fallback
    }

    func setColor(_ color: RGBAColor, _ key: String) { defaults.set(color.packed, forKey: key) }

    func number(_ key: String, default fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    func setNumber(_ value: Double, _ key: String) { defaults.set(value, forKey: key) }

    func string(_ key: String) -> String? { defaults.string(forKey: key) }

    func setString(_ value: String, _ key: String) { defaults.set(value, forKey: key) }
}
