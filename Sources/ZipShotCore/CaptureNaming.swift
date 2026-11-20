import Foundation

/// File naming for saved captures: `zipshot-<random>.<ext>`.
public enum CaptureNaming {
    public static let prefix = "zipshot-"
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    public static func randomToken(length: Int = 8) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    public static func fileName(ext: String) -> String {
        "\(prefix)\(randomToken()).\(ext)"
    }

    /// A URL in `directory` that does not collide with an existing file.
    public static func uniqueURL(in directory: URL, ext: String) -> URL {
        while true {
            let url = directory.appendingPathComponent(fileName(ext: ext))
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
    }
}
