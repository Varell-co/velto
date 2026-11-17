import AppKit

let app = NSApplication.shared
#if DEBUG
// `VELTO_SNAPSHOTS=<dir> swift run VeltoApp` renders the menu states to PNG for layout review, then quits.
if let directory = ProcessInfo.processInfo.environment["VELTO_SNAPSHOTS"] {
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        Snapshots.render(to: URL(fileURLWithPath: directory))
        exit(0)
    }
    app.run()
}
#endif
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
