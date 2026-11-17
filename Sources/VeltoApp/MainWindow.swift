import AppKit
import SwiftUI
import VeltoCore

enum Pane: String, Hashable, CaseIterable {
    case overview, alerts, sources, settings

    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .alerts: "bell"
        case .sources: "square.3.layers.3d"
        case .settings: "gearshape"
        }
    }
}

/// Where the main window is. Shared with the app delegate so the menu, notifications and "Add source"
/// can open the window on the right page.
@MainActor
final class MainNavigation: ObservableObject {
    /// Remembered across launches, like the sidebar selection in Mail or Notes.
    @Published var pane: Pane? = Pane(rawValue: UserDefaults.standard.string(forKey: "pane") ?? "") ?? .overview {
        didSet { UserDefaults.standard.set(pane?.rawValue, forKey: "pane") }
    }
    /// The source open in the Sources page's editor; empty shows the list.
    @Published var sourcePath: [UUID] = []

    func addSource(in monitor: Monitor) {
        pane = .sources
        // Reuse an untouched new source instead of piling up empty ones.
        if let blank = monitor.config.sources.first(where: { $0.url.isEmpty && $0.name.isEmpty }) {
            sourcePath = [blank.id]
            return
        }
        let source = Source(name: "", kind: .prometheus)
        monitor.update { $0.sources.append(source) }
        sourcePath = [source.id]
    }
}

struct MainWindowActions {
    var showMenu: () -> Void
    var open: (URL) -> Void
}

/// The app window, in the dark glass style: a branded sidebar and pages that carry their own header.
struct MainView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var navigation: MainNavigation
    let notifier: Notifier
    let actions: MainWindowActions

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(monitor: monitor, navigation: navigation)
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(WindowGlass())
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .tint(Theme.iris)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 900, minHeight: 620)
    }

    @ViewBuilder private var page: some View {
        let header = HeaderActions(monitor: monitor, notifier: notifier, actions: actions)
        Group {
            switch navigation.pane ?? .overview {
            case .overview: OverviewPage(monitor: monitor, navigation: navigation, actions: actions, header: header)
            case .alerts: AlertsPage(monitor: monitor, open: actions.open, header: header)
            case .sources: SourcesPage(monitor: monitor, navigation: navigation, header: header)
            case .settings: SettingsPage(monitor: monitor, notifier: notifier, header: header)
            }
        }
        .id(navigation.pane)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var navigation: MainNavigation
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                VeltoMark().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("velto").font(.system(size: 19, weight: .bold)).tracking(-0.3)
                    Text("by Varell").font(.system(size: 11)).foregroundStyle(Glass.muted.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 54)
            .padding(.bottom, 22)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Velto by Varell")

            ForEach(Pane.allCases, id: \.self) { pane in
                if pane == .settings { Spacer().frame(height: 14) }
                item(pane)
            }
            Spacer()
            footer
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: 216)
        .background(.black.opacity(0.18))
    }

    private func item(_ pane: Pane) -> some View {
        let selected = (navigation.pane ?? .overview) == pane
        return Button {
            withAnimation(reduceMotion ? nil : Glass.easeOut()) { navigation.pane = pane }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: pane.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.markIris : Glass.muted)
                    .frame(width: 18)
                Text(pane.title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                if let badge = badge(pane) { Chip(text: "\(badge)", color: badgeColor(pane)) }
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.78))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.iris.opacity(0.26), Theme.violet.opacity(0.18)], startPoint: .leading, endPoint: .trailing))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.iris.opacity(0.25)))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func badge(_ pane: Pane) -> Int? {
        let count = switch pane {
        case .alerts: Status(snapshot: monitor.snapshot).firing
        case .sources: monitor.snapshot.sources.filter(\.isOffline).count
        default: 0
        }
        return count > 0 ? count : nil
    }

    private func badgeColor(_ pane: Pane) -> Color {
        pane == .sources ? Glass.warning : Glass.color(for: monitor.snapshot.firing().map(\.severity).min() ?? .none)
    }

    /// The live state in one line, so the sidebar answers "is everything OK?" on every page.
    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let status = Status(snapshot: monitor.snapshot, now: context.date)
            HStack(spacing: 9) {
                GlowDot(color: Glass.color(for: status), size: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.headline.capitalizedFirst).font(.system(size: 12, weight: .medium))
                    Text(status.checkedAt.map { "Checked \(Format.ago($0, now: context.date))" } ?? "Not checked yet")
                        .font(.system(size: 11)).foregroundStyle(Glass.muted.opacity(0.7))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .glassCard(radius: 12, padding: nil)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Page scaffold

/// Check Now, notifications and More: shown in every page header in place of a window toolbar.
private struct HeaderActions: View {
    @ObservedObject var monitor: Monitor
    let notifier: Notifier
    let actions: MainWindowActions
    @AppStorage(Notifier.enabledKey) private var notify = true

    var body: some View {
        HStack(spacing: 8) {
            Button { monitor.refresh() } label: {
                HStack(spacing: 6) {
                    if monitor.isRefreshing { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 13, height: 13) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text(monitor.isRefreshing ? "Checking…" : "Check Now")
                }
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(monitor.isRefreshing || monitor.config.sources.isEmpty)
            .keyboardShortcut("r")
            .help("Check all sources now")

            Menu {
                Toggle("Notify When an Alert Starts Firing", isOn: $notify)
                    .onChange(of: notify) { on in if on { notifier.requestAuthorization() } }
                Divider()
                Button("Notification Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            } label: { GlassIconLabel(systemImage: notify ? "bell" : "bell.slash") }
                // .button + .plain draws the label as-is; borderlessButton would strip the glass circle.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Notifications")

            Menu {
                Button("Show in Menu Bar") { actions.showMenu() }
                if let url = monitor.config.sources.lazy.compactMap({ URL(string: $0.linkURL) }).first(where: { $0.scheme != nil }) {
                    Button("Open Dashboard") { actions.open(url) }
                }
                Button("Show Files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.snapshotURL]) }
                Divider()
                Button("Quit Velto") { NSApp.terminate(nil) }
            } label: { GlassIconLabel(systemImage: "ellipsis") }
                // .button + .plain draws the label as-is; borderlessButton would strip the glass circle.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
        }
    }
}

/// A page: large title and subtitle on the left, actions on the right, content below.
private struct Page<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.4)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Glass.muted).lineLimit(1)
                }
                Spacer(minLength: 12)
                accessory
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 20)

            ScrollView { content.padding(.horizontal, 32).padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

// MARK: - Overview

private struct OverviewPage: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var navigation: MainNavigation
    let actions: MainWindowActions
    let header: HeaderActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = Status(snapshot: monitor.snapshot, now: context.date)
            Page(title: "Overview", subtitle: status.detail(now: context.date)) { header } content: {
                VStack(alignment: .leading, spacing: 18) {
                    hero(status)
                    stats(status, now: context.date)
                    MenuBarCard(monitor: monitor, status: status, showMenu: actions.showMenu)
                    cards
                }
                .frame(maxWidth: 1040, alignment: .leading)
            }
        }
    }

    private func hero(_ status: Status) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Your infrastructure,\nat a glance.")
                    .font(.system(size: 40, weight: .bold))
                    .tracking(-0.9)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    GlowDot(color: Glass.color(for: status), size: 8)
                    Text(sentence(status)).font(.system(size: 15)).foregroundStyle(Glass.muted)
                }
                .animation(Glass.easeOut(), value: status.headline)
            }
            Spacer(minLength: 0)
            VeltoMark().frame(width: 132, height: 132).padding(.trailing, 20)
        }
        .padding(.vertical, 26)
        .padding(.horizontal, 28)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Theme.violet.opacity(0.30), Theme.iris.opacity(0.06)], startPoint: .topTrailing, endPoint: .bottomLeading))
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom)))
    }

    /// The live version of the tagline's promise, in one sentence.
    private func sentence(_ status: Status) -> String {
        let sources = Format.count(status.sources, "source")
        switch status.health {
        case .healthy: return "All clear across \(sources)."
        case .firing: return "\(status.firing) \(status.firing == 1 ? "alert is" : "alerts are") firing across \(sources)."
        case .partial: return "\(status.firing) firing, and \(status.offline == 1 ? "1 source is" : "\(status.offline) sources are") unreachable."
        case .offline: return "Velto can't reach your sources right now."
        case .stale: return "Showing cached alerts. The last check is too old to trust."
        case .loading: return "Checking your sources for the first time…"
        case .paused: return "Paused: \(status.pausedReason ?? "waiting for the network"). Velto checks again when the network changes."
        case .unconfigured, .unavailable: return "Add a Prometheus or Grafana Mimir source to get started."
        }
    }

    private func stats(_ status: Status, now: Date) -> some View {
        let alerts = monitor.snapshot.firing(now: now)
        let sources = monitor.snapshot.sources
        let healthy = sources.filter { $0.lastSuccess != nil && !$0.isOffline }.count
        return HStack(spacing: 14) {
            StatTile(icon: "exclamationmark.triangle.fill", tint: Glass.critical, label: "Critical",
                     value: "\(alerts.filter { $0.severity == .critical || $0.severity == .none }.count)")
            StatTile(icon: "exclamationmark.circle.fill", tint: Glass.warning, label: "Warnings",
                     value: "\(alerts.filter { $0.severity == .warning || $0.severity == .info }.count)")
            StatTile(icon: "checkmark.circle.fill", tint: Glass.healthy, label: "Sources OK", value: "\(healthy)/\(sources.count)")
            StatTile(icon: "clock.fill", tint: Theme.iris, label: "Last checked",
                     value: status.checkedAt.map { Format.ago($0, now: now) } ?? "Never")
        }
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: 14) {
            FeatureCard(icon: "square.3.layers.3d", title: "Multiple sources",
                        text: monitor.config.sources.isEmpty ? "Connect Prometheus, Grafana Mimir, Grafana Alerting or Alertmanager."
                            : "\(Format.count(monitor.config.sources.count, "source")) connected, checked side by side.",
                        action: monitor.config.sources.isEmpty ? "Add Source" : "Manage Sources") {
                if monitor.config.sources.isEmpty { navigation.addSource(in: monitor) } else { navigation.pane = .sources }
            }
            FeatureCard(icon: "apple.terminal", title: "Works where you work",
                        text: "The same alerts in your terminal, Starship, xbar and Waybar.",
                        action: "Set Up Integrations") { navigation.pane = .settings }
            FeatureCard(icon: "cylinder.split.1x2", title: "Local and efficient",
                        text: "Checks every \(interval). Status lines read the local cache, never your servers.",
                        action: "Show Cache") { NSWorkspace.shared.activateFileViewerSelecting([Store.snapshotURL]) }
        }
    }

    private var interval: String {
        let s = monitor.config.refreshSeconds
        return s < 60 ? "\(s) seconds" : s == 60 ? "minute" : "\(s / 60) minutes"
    }
}

private struct StatTile: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(.system(size: 12)).foregroundStyle(Glass.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
        .accessibilityElement(children: .combine)
    }
}

/// The real menu, live, in a small menu-bar scene: what you see here is what the status item shows.
private struct MenuBarCard: View {
    @ObservedObject var monitor: Monitor
    let status: Status
    let showMenu: () -> Void
    @StateObject private var router = MenuRouter()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Chip(text: "Menu Bar", color: Theme.markIris)
                Text("Always in reach.").font(.system(size: 24, weight: .bold)).tracking(-0.4)
                Text("A native menu bar utility that keeps your alerts visible, wherever you work.")
                    .font(.system(size: 13))
                    .foregroundStyle(Glass.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showMenu() } label: { Label("Show in Menu Bar", systemImage: "menubar.arrow.up.rectangle") }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .padding(.top, 4)
            }
            .frame(width: 280, alignment: .leading)
            .padding(24)
            Spacer(minLength: 0)
            scene
        }
        .glassCard(padding: nil)
        .clipShape(RoundedRectangle(cornerRadius: Glass.cardRadius, style: .continuous))
    }

    private var scene: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(hex: 0x2B2560), Color(hex: 0x111319).opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        Image(nsImage: Theme.menuBarColorImage)
                        if !status.compact.isEmpty { Text(status.compact).monospacedDigit() }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                    Text(Date.now.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.top, 8)

                MenuView(monitor: monitor, router: router,
                         actions: MenuActions(refresh: { monitor.refresh() }, settings: { _ in }, open: { _ in }, quit: {}))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
                    .scaleEffect(0.82, anchor: .topTrailing)
                    .padding(.trailing, 18)
            }
        }
        .frame(width: 400, height: 260, alignment: .top)
    }
}

private struct FeatureCard: View {
    let icon: String
    let title: String
    let text: String
    let action: String
    let perform: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.markIris)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.iris.opacity(0.16)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(text).font(.system(size: 12.5)).foregroundStyle(Glass.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text(action)
                    Image(systemName: "arrow.right").offset(x: hovered ? 3 : 0)
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.markIris)
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .glassCard()
            .background(RoundedRectangle(cornerRadius: Glass.cardRadius, style: .continuous).fill(.white.opacity(hovered ? 0.035 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: Glass.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Glass.easeOut(0.18), value: hovered)
    }
}

// MARK: - Alerts

private struct AlertsPage: View {
    @ObservedObject var monitor: Monitor
    let open: (URL) -> Void
    let header: HeaderActions
    @State private var filter = AlertFilter()
    @AppStorage("windowGroupByName") private var groupByName = false
    @State private var expanded: Set<String> = []
    @State private var showHistory = false
    @State private var history: [HistoryEvent] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let status = Status(snapshot: monitor.snapshot, now: context.date)
            let groups = monitor.snapshot.sources.map { source in (source, source.alerts.filter(filter.matches)) }.filter { !$0.1.isEmpty }
            Page(title: "Alerts", subtitle: status.firing == 0 ? "Nothing firing" : "\(status.firing) firing across \(Format.count(status.sources, "source"))") {
                header
            } content: {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        GlassSegments(options: [("Firing", false), ("History", true)], selection: $showHistory)
                        Spacer()
                    }
                    if showHistory {
                        HistoryList(events: history, now: context.date)
                    } else {
                        filters
                        if groups.isEmpty {
                            GlassEmpty(icon: monitor.snapshot.alerts.isEmpty ? "checkmark.seal" : "magnifyingglass",
                                       title: monitor.snapshot.alerts.isEmpty ? "No firing alerts" : "No matches",
                                       text: monitor.snapshot.alerts.isEmpty ? status.detail(now: context.date) : "Try a different search or severity.")
                                .padding(.top, 60)
                        } else {
                            ForEach(groups, id: \.0.id) { source, alerts in
                                group(source, alerts, now: context.date)
                            }
                        }
                    }
                }
                .frame(maxWidth: 1040, alignment: .top)
            }
        }
        .onChange(of: showHistory) { _ in loadHistory() }
        .onChange(of: monitor.snapshot.checkedAt) { _ in if showHistory { loadHistory() } }
    }

    private func loadHistory() {
        history = History.load(since: Date().addingTimeInterval(-86400)).reversed()
    }

    private var filters: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Glass.muted)
                TextField("Search alerts, targets or labels", text: $filter.text).textFieldStyle(.plain)
                if !filter.text.isEmpty {
                    Button { filter.text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Glass.muted) }
                        .buttonStyle(.plain)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.25)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .frame(maxWidth: 360)
            GlassSegments(options: [("All", Severity.none), ("Critical", .critical), ("Warning+", .warning)], selection: $filter.minimum)
            let environments = AlertFilter.environments(in: monitor.snapshot.alerts)
            if !environments.isEmpty || filter.environment != nil {
                Picker("", selection: $filter.environment) {
                    Text("All environments").tag(String?.none)
                    ForEach(environments, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            Toggle("Group by name", isOn: $groupByName).toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
        }
    }

    private func group(_ source: SourceSnapshot, _ alerts: [Alert], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(source.name).font(.system(size: 14, weight: .semibold))
                Text("\(alerts.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(Glass.muted).monospacedDigit()
                if source.isOffline { Chip(text: "Unreachable · cached", color: Glass.warning) }
                if let reason = source.pausedReason { Chip(text: "Paused · \(reason) · cached", color: Glass.muted) }
            }
            .padding(.leading, 4)
            let rows = groupByName ? Grouping.group(alerts, scope: source.id.uuidString) : alerts.map { AlertGroup(id: $0.id, name: $0.name, alerts: [$0]) }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 54) }
                    if group.alerts.count == 1 {
                        row(group.alerts[0], in: source, now: now)
                    } else {
                        GroupListRow(group: group, expanded: expanded.contains(group.id)) {
                            withAnimation(Glass.easeOut()) {
                                if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                            }
                        }
                        .opacity(source.isOffline ? 0.6 : 1)
                        if expanded.contains(group.id) {
                            ForEach(group.alerts) { row($0, in: source, now: now).padding(.leading, 28) }
                        }
                    }
                }
            }
            .glassCard(padding: nil)
        }
    }

    private func row(_ alert: Alert, in source: SourceSnapshot, now: Date) -> some View {
        AlertListRow(alert: alert, now: now, config: monitor.config.sources.first { $0.id == source.id }, link: link(for: source.id),
                     dimmed: source.isOffline || source.isPaused, open: open,
                     snooze: { scope, until in monitor.snooze(alert, in: source.id, scope: scope, until: until) },
                     unsnooze: { monitor.unsnooze(alert, in: source.id) })
    }

    private func link(for id: UUID) -> URL? {
        monitor.config.sources.first { $0.id == id }.flatMap { URL(string: $0.linkURL) }.flatMap { $0.scheme == nil ? nil : $0 }
    }
}

/// The last 24 hours of fires and resolves, newest first, by day.
private struct HistoryList: View {
    let events: [HistoryEvent]
    let now: Date

    var body: some View {
        let days = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.at) }.sorted { $0.key > $1.key }
        if events.isEmpty {
            GlassEmpty(icon: "clock.arrow.circlepath", title: "No history yet", text: "Alerts that fire or resolve in the last 24 hours show up here.")
                .padding(.top, 60)
        } else {
            ForEach(days, id: \.key) { day, items in
                VStack(alignment: .leading, spacing: 10) {
                    Text(Calendar.current.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.wide).day().month()))
                        .font(.system(size: 14, weight: .semibold)).padding(.leading, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, event in
                            if index > 0 { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 54) }
                            HStack(spacing: 14) {
                                Image(systemName: event.kind == .fired ? "flame.fill" : "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(event.kind == .fired ? Glass.critical : Glass.healthy)
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill((event.kind == .fired ? Glass.critical : Glass.healthy).opacity(0.15)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.name).font(.system(size: 13, weight: .semibold))
                                    Text([event.kind == .fired ? "Fired" : "Resolved", event.source, event.target].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 12)).foregroundStyle(Glass.muted)
                                }
                                Spacer()
                                Text(Format.clock(event.at)).font(.system(size: 12)).foregroundStyle(Glass.muted).monospacedDigit()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                    .glassCard(padding: nil)
                }
            }
        }
    }
}

private struct GroupListRow: View {
    let group: AlertGroup
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        let tint = Glass.color(for: group.worst)
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "square.stack.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.name).font(.system(size: 13.5, weight: .semibold))
                        Text("×\(group.alerts.count)").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Glass.muted).monospacedDigit()
                    }
                    Text(group.targets.joined(separator: ", ")).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Glass.muted.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 12)
                if group.worst != .none { Chip(text: group.worst.label, color: tint) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Glass.muted.opacity(0.6))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .padding(.top, 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(hovered ? 0.035 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct AlertListRow: View {
    let alert: Alert
    let now: Date
    let config: Source?
    let link: URL?
    let dimmed: Bool
    let open: (URL) -> Void
    let snooze: (Snooze.Scope, Date) -> Void
    let unsnooze: () -> Void
    @State private var hovered = false

    var body: some View {
        let url = alert.url.flatMap(URL.init(string:)) ?? link
        let snoozed = alert.isSnoozed(now: now)
        let tint = Glass.color(for: alert.severity)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: alert.severity == .warning || alert.severity == .info ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.name).font(.system(size: 13.5, weight: .semibold))
                if let summary = alert.summary { Text(summary).font(.system(size: 12.5)).foregroundStyle(Glass.muted).lineLimit(2) }
                if alert.target != nil || alert.owner != nil {
                    HStack(spacing: 6) {
                        if let target = alert.target { Text(target).font(.system(size: 11.5, design: .monospaced)) }
                        if let owner = alert.owner { Text(alert.target == nil ? owner : "· \(owner)").font(.system(size: 11.5)) }
                    }
                    .foregroundStyle(Glass.muted.opacity(0.7))
                }
                if runbook != nil || dashboard != nil {
                    HStack(spacing: 8) {
                        if let runbook { Button { open(runbook) } label: { Label("Runbook", systemImage: "book") }.buttonStyle(GlassButtonStyle()) }
                        if let dashboard { Button { open(dashboard) } label: { Label("Dashboard", systemImage: "chart.xyaxis.line") }.buttonStyle(GlassButtonStyle()) }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    if let until = alert.snoozedUntil, snoozed { Chip(text: "Snoozed until \(Format.clock(until))", color: Glass.muted) }
                    if let flaps = alert.flapCount, !snoozed { Chip(text: "⟳ \(flaps)× in 1h", color: Glass.warning) }
                    if alert.isNew(now: now) && !snoozed { Chip(text: "New", color: Theme.markIris) }
                    if alert.severity != .none { Chip(text: alert.severity.label, color: tint) }
                }
                if let at = alert.activeAt {
                    Text(Format.duration(now.timeIntervalSince(at))).font(.system(size: 11.5)).foregroundStyle(Glass.muted).monospacedDigit()
                }
            }
            if let url {
                Button { open(url) } label: { GlassIconLabel(systemImage: "arrow.up.right") }
                    .buttonStyle(.plain)
                    .opacity(hovered ? 1 : 0.35)
                    .help("Open in dashboard")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(hovered ? 0.035 : 0))
        .opacity(dimmed || snoozed ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(Glass.easeOut(0.12), value: hovered)
        .contextMenu {
            if snoozed { Button("Unsnooze") { unsnooze() } }
            Menu("Snooze") {
                ForEach(Snooze.presets(now: now), id: \.label) { preset in Button(preset.label) { snooze(.alert, preset.until) } }
            }
            Menu("Snooze All \(alert.name)") {
                ForEach(Snooze.presets(now: now), id: \.label) { preset in Button(preset.label) { snooze(.name, preset.until) } }
            }
            Divider()
            Button("Copy Alert Name") { copy(alert.name) }
            Button("Copy Labels") { copy(alert.labels.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: ", ")) }
            if !alert.annotations.isEmpty {
                Button("Copy Annotations") { copy(alert.annotations.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: "\n")) }
            }
            if url != nil || runbook != nil || dashboard != nil { Divider() }
            if let url { Button("Open") { open(url) } }
            if let runbook { Button("Open Runbook") { open(runbook) } }
            if let dashboard { Button("Open Dashboard") { open(dashboard) } }
        }
    }

    private var runbook: URL? { alert.runbookURL }
    private var dashboard: URL? { config?.dashboardURL(for: alert) }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Sources

private struct SourcesPage: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var navigation: MainNavigation
    let header: HeaderActions

    var body: some View {
        if let id = navigation.sourcePath.last, let source = monitor.config.sources.first(where: { $0.id == id }) {
            editor(source)
        } else {
            list
        }
    }

    private var list: some View {
        let offline = monitor.snapshot.sources.filter(\.isOffline).count
        let subtitle = monitor.config.sources.isEmpty ? "Nothing connected yet"
            : Format.count(monitor.config.sources.count, "source") + (offline > 0 ? " · \(offline) unreachable" : "")
        return Page(title: "Sources", subtitle: subtitle) {
            HStack(spacing: 8) {
                Button { navigation.addSource(in: monitor) } label: { Label("Add Source", systemImage: "plus") }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                header
            }
        } content: {
            if monitor.config.sources.isEmpty {
                GlassEmpty(icon: "square.3.layers.3d", title: "No sources yet", text: "Add a Prometheus, Grafana Mimir, Grafana Alerting or Alertmanager source.")
                    .padding(.top, 60)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(monitor.config.sources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 50) }
                        SourceRow(source: source, state: monitor.snapshot.sources.first { $0.id == source.id }) {
                            withAnimation(Glass.easeOut()) { navigation.sourcePath = [source.id] }
                        }
                        .contextMenu {
                            Button("Remove Source", role: .destructive) { monitor.update { $0.sources.removeAll { $0.id == source.id } } }
                        }
                    }
                }
                .glassCard(padding: nil)
                .frame(maxWidth: 1040)
            }
        }
    }

    private func editor(_ source: Source) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button { withAnimation(Glass.easeOut()) { navigation.sourcePath = [] } } label: {
                    GlassIconLabel(systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Sources")
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name.isEmpty ? "New Source" : source.name).font(.system(size: 26, weight: .bold)).tracking(-0.4)
                    Text(source.isComplete ? source.kind.label : source.kind == .probes ? "Needs a probe" : "Needs a URL")
                        .font(.system(size: 13)).foregroundStyle(Glass.muted)
                }
                Spacer()
                Button(role: .destructive) {
                    navigation.sourcePath = []
                    monitor.update { $0.sources.removeAll { $0.id == source.id } }
                } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(GlassButtonStyle(destructive: true))
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 20)
            ScrollView {
                SourceEditor(monitor: monitor, source: source)
                    .id(source.id)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SourceRow: View {
    let source: Source
    let state: SourceSnapshot?
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                GlowDot(color: Glass.color(for: state), size: 9).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name.isEmpty ? "New source" : source.name).font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(source.kind == .probes ? "\(source.kind.label) · \(source.probes.count)" : source.kind.label)
                        if source.kind != .probes, let host = URL(string: source.url)?.host {
                            Text("·")
                            Text(host).font(.system(size: 12, design: .monospaced))
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Glass.muted)
                }
                Spacer(minLength: 12)
                trailing
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Glass.muted.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(.white.opacity(hovered ? 0.035 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Glass.easeOut(0.12), value: hovered)
    }

    @ViewBuilder private var trailing: some View {
        if let reason = state?.pausedReason {
            Chip(text: "Paused · \(reason)", color: Glass.muted)
        } else if let state, state.lastAttempt != nil {
            if let error = state.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Glass.warning).lineLimit(1).frame(maxWidth: 260, alignment: .trailing)
            } else if state.attention() == 0 {
                Chip(text: "All clear", color: Glass.healthy)
            } else {
                Chip(text: "\(state.attention()) firing", color: Glass.color(for: state))
            }
        } else {
            Text(source.isComplete ? "Not checked yet" : "Incomplete").font(.system(size: 12)).foregroundStyle(Glass.muted)
        }
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    @ObservedObject var monitor: Monitor
    let notifier: Notifier
    let header: HeaderActions

    var body: some View {
        Page(title: "Settings", subtitle: "Checking, notifications and integrations") { header } content: {
            SettingsForm(monitor: monitor, notifier: notifier)
                .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

/// A centered empty state with the icon in a soft glass circle.
struct GlassEmpty: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.markIris)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Theme.iris.opacity(0.14)))
                .overlay(Circle().strokeBorder(Theme.iris.opacity(0.25)))
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(Glass.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
