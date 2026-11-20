// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZipShot",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: edit model, rendering, GIF encoding, frame storage.
        // No app or UI state, so it can be exercised headlessly.
        .target(name: "ZipShotCore", path: "Sources/ZipShotCore"),
        // The menu bar app.
        .executableTarget(name: "ZipShot", dependencies: ["ZipShotCore"], path: "Sources/ZipShot"),
        // Headless checks for ZipShotCore: `swift run -c release zipshot-selftest`.
        // (A plain executable rather than a test target, so it runs with only
        // the Command Line Tools installed.)
        .executableTarget(name: "zipshot-selftest", dependencies: ["ZipShotCore"], path: "Sources/SelfTest"),
    ]
)
