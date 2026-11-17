#if DEBUG
import AppKit
import SwiftUI
import VeltoCore

/// Renders the menu in each state to PNG (light and dark) for layout review without live servers.
@MainActor
enum Snapshots {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let production = Source(name: "Production", kind: .prometheus, url: "https://prometheus.example.com", linkURL: "https://grafana.example.com")
        let homelab = Source(name: "Homelab", kind: .mimir, url: "https://mimir.example.com")
        func alert(_ name: String, _ severity: Severity, _ target: String, _ minutes: Double) -> Alert {
            Alert(id: name, name: name, severity: severity, target: target, activeAt: now.addingTimeInterval(-minutes * 60))
        }
        func state(_ source: Source, _ alerts: [Alert], error: String? = nil, resolved: [ResolvedAlert] = [], checks: [Check] = []) -> SourceSnapshot {
            SourceSnapshot(source: source, alerts: alerts, error: error, lastAttempt: now.addingTimeInterval(-12),
                           lastSuccess: error == nil ? now.addingTimeInterval(-12) : nil, resolved: resolved, checks: checks)
        }
        let config = Config(sources: [production, homelab])
        let cases: [(String, Config, Snapshot)] = [
            ("firing", config, Snapshot(checkedAt: now.addingTimeInterval(-12), sources: [
                state(production, [alert("HighMemoryUsage", .critical, "api-server-01", 23), alert("DiskSpaceLow", .warning, "postgres-02", 8)]),
                state(homelab, [alert("NodeExporterDown", .critical, "prometheus.local", 5)]),
            ])),
            ("healthy", config, Snapshot(checkedAt: now.addingTimeInterval(-8), sources: [state(production, []), state(homelab, [])])),
            ("partial", config, Snapshot(checkedAt: now.addingTimeInterval(-12), sources: [
                state(production, [alert("HighMemoryUsage", .critical, "api-server-01", 23)]),
                state(homelab, [alert("NodeExporterDown", .critical, "prometheus.local", 5)], error: "Host not found · VPN?"),
            ])),
            ("stale", config, Snapshot(checkedAt: now.addingTimeInterval(-720), sources: [state(production, [alert("DiskSpaceLow", .warning, "postgres-02", 8)]), state(homelab, [])])),
            ("empty", Config(), Snapshot()),
            ("context", config, Snapshot(checkedAt: now.addingTimeInterval(-12), sources: [
                state(production, [
                    Alert(id: "ctx", name: "HighMemoryUsage", severity: .critical, target: "api-server-01",
                          summary: "Memory above 92% for 15 minutes", activeAt: now.addingTimeInterval(-23 * 60),
                          labels: ["alertname": "HighMemoryUsage", "team": "platform"],
                          annotations: ["runbook_url": "https://runbooks.example.com/memory", "__dashboardUid__": "node", "__panelId__": "4"]),
                    alert("DiskSpaceLow", .warning, "postgres-02", 8),
                ]),
                state(homelab, []),
            ])),
            ("grouped", config, Snapshot(checkedAt: now.addingTimeInterval(-12), sources: [
                state(production, [
                    alert("HighMemoryUsage", .critical, "api-server-01", 23),
                    Alert(id: "d2", name: "DiskSpaceLow", severity: .warning, target: "postgres-02", activeAt: now.addingTimeInterval(-480)),
                    Alert(id: "d3", name: "DiskSpaceLow", severity: .warning, target: "postgres-03", activeAt: now.addingTimeInterval(-400)),
                    Alert(id: "d4", name: "DiskSpaceLow", severity: .warning, target: "postgres-04", activeAt: now.addingTimeInterval(-300)),
                    { var a = alert("CertRenewal", .warning, "ingress", 90); a.snoozedUntil = now.addingTimeInterval(3 * 3600); return a }(),
                ].map { var a = $0; if a.id == "HighMemoryUsage" { a.firstSeen = now.addingTimeInterval(-120) }; return a },
                resolved: [ResolvedAlert(alert: alert("NodeExporterDown", .critical, "homelab-01", 40), resolvedAt: now.addingTimeInterval(-720))]),
                state(homelab, []),
            ])),
            ("checks", config, Snapshot(checkedAt: now.addingTimeInterval(-12), sources: [
                state(production, [alert("HighMemoryUsage", .critical, "api-server-01", 23)], checks: [
                    Check(id: "t", name: "Targets up", value: 214, display: "214/216", state: .warn),
                    Check(id: "c", name: "Cert expiry (min)", value: 23, display: "23 days", state: .ok),
                    Check(id: "d", name: "Disk free (min)", value: 11, display: "11 %", state: .warn),
                    Check(id: "q", name: "Queue depth", display: "no data", state: .unknown),
                ]),
                state(homelab, []),
            ])),
        ]
        renderSettings(config: config, to: directory)
        let actions = MenuActions(refresh: {}, settings: { _ in }, open: { _ in }, quit: {})
        for (name, config, snapshot) in cases {
            let routes: [(String, MenuRoute)] = switch name {
            case "firing": [("root", .root), ("all", .all), ("source", .source(production.id))]
            case "context": [("source", .source(production.id))]
            case "grouped", "checks": [("root", .root), ("source", .source(production.id))]
            default: [("root", .root)]
            }
            for (routeName, route) in routes {
                for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    let router = MenuRouter()
                    router.go(route, animated: false)
                    // The popover material can't render offscreen; the window color stands in for it.
                    let view = MenuView(monitor: Monitor(preview: config, snapshot: snapshot), router: router, actions: actions)
                        .padding(.bottom, 4)
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(20)
                        .background(scheme == "dark" ? Color(hex: 0x15161C) : Color(hex: 0xC9CAD3))
                    let hosting = NSHostingView(rootView: view)
                    hosting.appearance = NSAppearance(named: appearance)
                    hosting.frame.size = hosting.fittingSize
                    hosting.layoutSubtreeIfNeeded()
                    // Layout runs twice: the list's measured height lands after the first pass.
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    hosting.frame.size = hosting.fittingSize
                    hosting.layoutSubtreeIfNeeded()
                    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    let file = "menu-\(name)\(routeName == "root" || name == "context" ? "" : "-" + routeName)-\(scheme).png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(file))
                }
            }
        }
    }

    private static func renderSettings(config: Config, to directory: URL) {
        let now = Date()
        let snapshot = Snapshot(checkedAt: now.addingTimeInterval(-12), sources: [
            SourceSnapshot(source: config.sources[0], alerts: [
                Alert(id: "a", name: "HighMemoryUsage", severity: .critical, target: "api-server-01", summary: "Memory above 92% for 15 minutes", activeAt: now.addingTimeInterval(-1380)),
                Alert(id: "b", name: "DiskSpaceLow", severity: .warning, target: "postgres-02", activeAt: now.addingTimeInterval(-480)),
            ], lastAttempt: now.addingTimeInterval(-12), lastSuccess: now.addingTimeInterval(-12)),
            SourceSnapshot(source: config.sources[1], alerts: [
                Alert(id: "c", name: "NodeExporterDown", severity: .critical, target: "prometheus.local", activeAt: now.addingTimeInterval(-300)),
            ], lastAttempt: now.addingTimeInterval(-12), lastSuccess: now.addingTimeInterval(-12)),
        ])
        for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (name, pane) in [("overview", Pane.overview), ("alerts", .alerts), ("sources", .sources), ("source-editor", .sources), ("settings", .settings)] {
                let navigation = MainNavigation()
                navigation.pane = pane
                if name == "source-editor" { navigation.sourcePath = [config.sources[0].id] }
                let monitor = Monitor(preview: config, snapshot: snapshot)
                let view = MainView(monitor: monitor, navigation: navigation, notifier: Notifier(),
                                    actions: MainWindowActions(showMenu: {}, open: { _ in }))
                // A real window, so the glass blur renders as it would on screen.
                let hosting = NSHostingController(rootView: view)
                let window = NSWindow(contentViewController: hosting)
                Glass.configure(window)
                window.setContentSize(NSSize(width: 1080, height: 760))
                window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
                window.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                if let id = window.windowNumber as Int?, let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(id), [.boundsIgnoreFraming, .bestResolution]) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: directory.appendingPathComponent("window-\(name)-\(scheme).png"))
                }
                window.orderOut(nil)
            }
        }
    }
}
#endif
