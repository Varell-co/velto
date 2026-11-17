import AppKit
import VeltoCore

// The CLI only reads the snapshot the app writes. It never touches the network or the Keychain, so a
// status line stays instant and the user's secrets stay with the signed app.

/// Read from the app bundle the CLI ships in (Velto.app/Contents/Helpers/velto), so there is one version source.
let version: String = {
    let contents = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent()
    let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))
    return info?["CFBundleShortVersionString"] as? String ?? "dev"
}()
let usage = """
velto \(version) · Prometheus, Grafana Mimir and Alertmanager alerts at a glance

Usage:
  velto status [--format default|plain|json|starship|waybar|xbar]
  velto alerts [--source NAME] [--severity critical|warning|info] [--env NAME] [--group] [--json]
  velto checks [--source NAME] [--json]
  velto history [--since 24h|7d] [--source NAME] [--json]
  velto refresh      ask the running app to check all sources now
  velto doctor       show paths, sources and what might be wrong
  velto open         open the Velto app

Options:
  --env NAME         only alerts whose env, environment, cluster or tenant label is NAME
  --group            fold same-name alerts in a source into one row
  --no-color         plain text (also honors NO_COLOR)
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("velto: \(message)\n".utf8))
    exit(1)
}

let useColor = !flag("--no-color") && ProcessInfo.processInfo.environment["NO_COLOR"] == nil && isatty(STDOUT_FILENO) == 1
let style = Render.Style(color: useColor)
if args.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) { print(usage); exit(0) }
let command = args.isEmpty ? "status" : args.removeFirst()
let snapshot = Store.loadSnapshot()

switch command {
case "status":
    let format = option("--format") ?? "default"
    switch format {
    case "default":
        let status = Status(snapshot: snapshot)
        print(style.health(status, status.headline))
    case "plain": print(Render.plain(snapshot))
    case "json": print(Render.json(snapshot))
    case "starship": print(Render.starship(snapshot))
    case "waybar": print(Render.waybar(snapshot))
    case "xbar": print(Render.xbar(snapshot, cli: executablePath()))
    default: fail("unknown format \"\(format)\"")
    }

case "alerts":
    let source = option("--source")
    let minimum = option("--severity").map { value -> Severity in
        guard let s = Severity(rawValue: value.lowercased()), s != .none else { fail("severity must be critical, warning or info") }
        return s
    } ?? .none
    let filter = AlertFilter(minimum: minimum, environment: option("--env"))
    let grouped = flag("--group")
    if flag("--json") { print(Render.json(snapshot)) }
    else { print(Render.alerts(snapshot, source: source, filter: filter, grouped: grouped, style: style), terminator: "") }

case "checks":
    let source = option("--source")
    if flag("--json") {
        struct Entry: Encodable { let source: String; let paused: Bool; let offline: Bool; let checks: [Check] }
        let entries = (snapshot?.sources ?? []).filter { source == nil || $0.name.caseInsensitiveCompare(source!) == .orderedSame }
            .map { Entry(source: $0.name, paused: $0.isPaused, offline: $0.isOffline, checks: $0.checks) }
        print(String(decoding: (try? Store.encoder.encode(entries)) ?? Data("[]".utf8), as: UTF8.self))
    } else {
        print(Render.checks(snapshot, source: source, style: style), terminator: "")
    }

case "history":
    let span = option("--since") ?? "24h"
    guard let amount = Double(span.dropLast()), amount > 0, let unit = span.last, let seconds = ["m": 60.0, "h": 3600, "d": 86400][String(unit)] else {
        fail("--since takes a duration like 30m, 24h or 7d")
    }
    let source = option("--source")
    let events = History.load(since: Date().addingTimeInterval(-amount * seconds))
        .filter { source == nil || $0.source.caseInsensitiveCompare(source!) == .orderedSame }
    if flag("--json") {
        print(String(decoding: (try? Store.encoder.encode(events)) ?? Data("[]".utf8), as: UTF8.self))
    } else {
        print(Render.history(events, style: style), terminator: "")
    }

case "refresh":
    guard appIsRunning() else { fail("the Velto app isn't running. Start it with: velto open") }
    let before = snapshot?.checkedAt
    DistributedNotificationCenter.default().postNotificationName(Store.refreshNotification, object: nil, deliverImmediately: true)
    // Sources time out after 10 s, so 15 s covers a full check; past that, show what is there.
    let deadline = Date().addingTimeInterval(15)
    var fresh = snapshot
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.25)
        fresh = Store.loadSnapshot()
        if let at = fresh?.checkedAt, at != before { break }
    }
    print(Render.alerts(fresh, style: style), terminator: "")

case "doctor":
    doctor()

case "open":
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Store.bundleID) else { fail("Velto.app not found") }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        if let error { fail(error.localizedDescription) }
        exit(0)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(10))

case "help", "--help", "-h":
    print(usage)

case "version", "--version", "-v":
    print("velto \(version)")

default:
    fail("unknown command \"\(command)\"\n\n\(usage)")
}

func appIsRunning() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Store.bundleID).isEmpty }

/// Absolute path for xbar, which runs plugins without the user's PATH.
func executablePath() -> String { (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path }

func doctor() {
    func row(_ ok: Bool?, _ text: String) {
        let mark = switch ok { case true?: style.success("✓"); case false?: style.critical("✗"); case nil: style.warning("!") }
        print("  \(mark) \(text)")
    }
    print(style.bold("velto \(version)"))
    print()
    print(style.bold("App"))
    row(appIsRunning(), appIsRunning() ? "running" : "not running · start it with: velto open")
    print()
    print(style.bold("Files"))
    let config: Config?
    do { config = try Store.loadConfig() } catch { config = nil; row(false, "config unreadable: \(error.localizedDescription)") }
    row(config != nil, "config    \(Store.configURL.path)")
    row(snapshot != nil, "snapshot  \(Store.snapshotURL.path)")
    print()
    print(style.bold("Local state"))
    let history = History.load()
    let days = history.first.map { max(1, Int(Date().timeIntervalSince($0.at) / 86400) + 1) } ?? 0
    row(true, "history   \(Store.historyURL.path) · \(Format.count(history.count, "event"))" + (days > 0 ? " · \(Format.count(days, "day"))" : ""))
    let mutes = (config?.mutes ?? []).filter { $0.until > Date() }
    row(true, "mutes     \(mutes.count) active" + (mutes.isEmpty ? "" : " (" + mutes.map { "until \(Format.clock($0.until))" }.joined(separator: ", ") + ")"))
    print()
    print(style.bold("Sources"))
    if let config, !config.sources.isEmpty {
        for source in config.sources {
            let state = snapshot?.sources.first { $0.id == source.id }
            var ok: Bool? = state?.lastAttempt == nil ? nil : state?.error == nil
            var line = "\(source.displayName) · \(source.kind.label) · \(source.url)"
            if let reason = state?.pausedReason { ok = nil; line += style.muted(" · paused · \(reason)") }
            else if let state, let error = state.error { line += "\n      " + style.critical(error) }
            else if let at = state?.lastSuccess { line += style.muted(" · ok \(Format.ago(at))") }
            else { line += style.muted(" · not checked yet") }
            if !source.queries.isEmpty {
                let failing = (state?.checks ?? []).filter { $0.state == .unknown && $0.message != nil }
                    .filter { check in source.queries.contains { $0.id.uuidString == check.id } }
                line += "\n      " + (source.queries.count == 1 ? "1 query" : "\(source.queries.count) queries")
                if let first = failing.first {
                    line += style.warning(" (\(failing.count) failing: \"\(first.name)\" · \(first.message ?? ""))")
                }
            }
            row(ok, line)
        }
    } else {
        row(nil, "none configured · add one in Velto's Settings")
    }
    print()
    let status = Status(snapshot: snapshot)
    print(style.bold("Status") + "  " + style.health(status, status.headline) + style.muted("  " + status.detail()))
}
