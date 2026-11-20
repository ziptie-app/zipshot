import AppKit

// ZipShot: a menu bar app for screenshots and GIF recordings.

MainActor.assumeIsolated {
    let application = NSApplication.shared

    if let flag = CommandLine.arguments.firstIndex(of: "--ui-snapshots"), flag + 1 < CommandLine.arguments.count {
        // Developer aid: draw each piece of UI to a PNG without touching the screen.
        UISnapshots.run(into: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        exit(0)
    }

    if CommandLine.arguments.contains("--ui-check") {
        // Developer aid: drive the editors with synthetic input and verify the results.
        exit(UICheck.run() ? 0 : 1)
    }

    if let flag = CommandLine.arguments.firstIndex(of: "--capture-check"), flag + 1 < CommandLine.arguments.count {
        // Developer aid: run the real capture paths once and report.
        let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
        Task { @MainActor in
            exit(await CaptureCheck.run(into: folder) ? 0 : 1)
        }
        application.run()
    }

    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    // `run` never returns, which keeps `delegate` alive for the life of the app.
    application.run()
}
