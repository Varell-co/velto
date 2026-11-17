import AppKit
import SwiftUI
import VeltoCore

struct MenuActions {
    var refresh: () -> Void
    var settings: (_ addSource: Bool) -> Void
    var open: (URL) -> Void
    var quit: () -> Void
}

enum MenuRoute: Hashable {
    case root
    case all
    case source(UUID)
}

/// Where the popover is: kept outside the view so a notification can open it on a source, and closing
/// it can return to the top.
@MainActor
final class MenuRouter: ObservableObject {
    @Published private(set) var route: MenuRoute = .root
    /// Direction of the last move, so the slide goes the way a drill-down should.
    private(set) var forward = true

    func go(_ route: MenuRoute, animated: Bool = true) {
        forward = route != .root
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { self.route = route; return }
        // Ease-out, not a spring: the brand asks for calm menus (240 ms reveal at most).
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)) { self.route = route }
    }
}

/// The status-item popover, laid out like macOS's own menu-bar extras: a summary on top, one row per
/// source, drill-down for detail, utilities at the bottom.
struct MenuView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var router: MenuRouter
    let actions: MenuActions
    static let width: CGFloat = 320

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    page(now: context.date)
                        .id(router.route)
                        .transition(.asymmetric(
                            insertion: .move(edge: router.forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: router.forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .clipped()
                if let notice = monitor.silenceNotice { SilenceBanner(monitor: monitor, notice: notice) }
                Divider().padding(.horizontal, 14).padding(.top, 6)
                footer
            }
            .padding(.top, 6)
        }
        .frame(width: Self.width)
    }

    @ViewBuilder private func page(now: Date) -> some View {
        switch router.route {
        case .root: root(now: now)
        case .all: AllAlertsPage(monitor: monitor, router: router, now: now, open: actions.open)
        case .source(let id): SourcePage(monitor: monitor, router: router, id: id, now: now, open: actions.open)
        }
    }

    private func root(now: Date) -> some View {
        let status = Status(snapshot: monitor.snapshot, now: now)
        let hasSources = !monitor.snapshot.sources.isEmpty
        return VStack(spacing: 0) {
            HoverRow(action: hasSources ? { router.go(.all) } : nil) {
                HStack(spacing: 12) {
                    VeltoMark().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("velto").font(.system(size: 19, weight: .semibold))
                        HStack(spacing: 6) {
                            StatusDot(color: Theme.color(for: status))
                            Text(summary(status, now: now) + newSuffix(now: now)).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if hasSources { Chevron() }
                }
                .padding(.vertical, 4)
            }
            .help(status.detail(now: now))
            .accessibilityLabel("Velto, \(status.headline). \(status.detail(now: now))")

            Divider().padding(.horizontal, 14).padding(.vertical, 6)

            if hasSources {
                ForEach(monitor.snapshot.sources) { source in
                    HoverRow(action: { router.go(.source(source.id)) }) {
                        HStack(spacing: 10) {
                            if source.isPaused {
                                Circle().strokeBorder(Theme.neutral, lineWidth: 1.5).frame(width: 9, height: 9).accessibilityHidden(true)
                            } else {
                                StatusDot(color: color(for: source, now: now), size: 9)
                            }
                            Text(source.name).font(.system(size: 13.5)).lineLimit(1)
                            Spacer(minLength: 8)
                            if let trailing = trailing(for: source, now: now) {
                                Text(trailing).font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Chevron()
                        }
                    }
                }
            } else {
                HoverRow(action: { actions.settings(true) }) {
                    Label("Add a source…", systemImage: "plus.circle").font(.system(size: 13.5))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            IconButton(systemImage: "gearshape", help: "Settings") { actions.settings(false) }
                .keyboardShortcut(",")
            Spacer()
            if monitor.isRefreshing { ProgressView().controlSize(.small).padding(.trailing, 4) }
            Menu {
                Button("Refresh Now") { actions.refresh() }
                    .keyboardShortcut("r")
                    .disabled(monitor.isRefreshing || monitor.snapshot.sources.isEmpty)
                if let url = dashboardURL { Button("Open Dashboard") { actions.open(url) } }
                Divider()
                Button("Settings…") { actions.settings(false) }
                Button("Quit Velto") { actions.quit() }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).frame(width: 30, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// The header line. Short like a system menu, but never "healthy" while a source is unverified.
    private func summary(_ status: Status, now: Date) -> String {
        switch status.health {
        case .healthy: status.sources == 1 ? "Source healthy" : "All sources healthy"
        case .firing: "\(status.firing) firing"
        case .partial: "\(status.firing) firing · \(status.offline) unreachable"
        case .offline: status.sources == 1 ? "Source unreachable" : "Sources unreachable"
        case .stale: status.checkedAt.map { "Stale · checked \(Format.ago($0, now: now))" } ?? "Stale"
        case .loading: "Checking…"
        case .unconfigured: "No sources yet"
        case .unavailable: "Not running"
        case .paused: "Paused · \(status.pausedReason ?? "")"
        }
    }

    private func newSuffix(now: Date) -> String {
        let new = monitor.snapshot.firing(now: now).filter { $0.isNew(now: now) }.count
        let snoozed = Status(snapshot: monitor.snapshot, now: now).snoozed
        return (new == 0 ? "" : " · \(new) new") + (snoozed == 0 ? "" : " · \(snoozed) snoozed")
    }

    private func color(for source: SourceSnapshot, now: Date) -> Color {
        if source.lastAttempt == nil { return Theme.neutral }
        if source.error != nil { return Theme.warning }
        return source.attention(now: now) == 0 ? Theme.success : Theme.color(for: source.worst(now: now))
    }

    private func trailing(for source: SourceSnapshot, now: Date) -> String? {
        if let reason = source.pausedReason { return "Paused · \(reason.replacingOccurrences(of: " required", with: ""))" }
        if source.error != nil { return "Unreachable" }
        let count = source.attention(now: now)
        return count == 0 ? nil : "\(count)"
    }

    private var dashboardURL: URL? {
        monitor.config.sources.lazy.compactMap { URL(string: $0.linkURL) }.first { $0.scheme != nil }
    }
}

// MARK: - Pages

private struct SourcePage: View {
    @ObservedObject var monitor: Monitor
    let router: MenuRouter
    let id: UUID
    let now: Date
    let open: (URL) -> Void
    @AppStorage("menuFilter") private var filterData = Data()
    @State private var expanded: Set<String> = []

    var body: some View {
        let source = monitor.snapshot.sources.first { $0.id == id }
        let config = monitor.config.sources.first { $0.id == id }
        let link = config.flatMap { URL(string: $0.linkURL) }.flatMap { $0.scheme == nil ? nil : $0 }
        VStack(alignment: .leading, spacing: 0) {
            BackHeader(title: source?.name ?? "Source",
                       subtitle: [config?.kind.label, source?.lastSuccess.map { "checked \(Format.ago($0, now: now))" }].compactMap { $0 }.joined(separator: " · "),
                       back: { router.go(.root) })
            if let source {
                if let reason = source.pausedReason {
                    Label("Paused · \(reason)" + (source.lastSuccess.map { " · last checked \(Format.ago($0, now: now))" } ?? ""),
                          systemImage: "pause.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let error = source.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let resolved = source.resolved.filter { now.timeIntervalSince($0.resolvedAt) < SnapshotMerge.resolvedWindow }
                let filter = MenuFilter.decode(filterData)
                let shown = source.alerts.filter(filter.matches)
                if source.alerts.count > 1 || (filter.isActive && !source.alerts.isEmpty) {
                    FilterBar(filter: MenuFilter.binding($filterData), environments: AlertFilter.environments(in: source.alerts))
                }
                if source.alerts.isEmpty && resolved.isEmpty && source.checks.isEmpty {
                    EmptyNote(text: source.lastAttempt == nil ? "Checking…" : source.error == nil ? "No firing alerts" : "No cached alerts")
                } else {
                    AlertList {
                        if shown.isEmpty && source.kind != .probes {
                            EmptyNote(text: !source.alerts.isEmpty ? "No alerts match the filter" : source.error == nil ? "No firing alerts" : "No cached alerts")
                        }
                        AlertRows(monitor: monitor, alerts: shown, sourceID: source.id, config: config, now: now, dimmed: source.error != nil || source.isPaused,
                                  link: link, open: open, expanded: $expanded)
                        if !source.checks.isEmpty {
                            if source.kind != .probes { SectionTitle(text: "Checks") }
                            ForEach(source.checks) { item in CheckRow(check: item).opacity(source.error != nil || source.isPaused ? 0.55 : 1) }
                        }
                        if !resolved.isEmpty {
                            SectionTitle(text: "Resolved in the last hour")
                            ForEach(resolved) { item in ResolvedRow(item: item, now: now) }
                        }
                    }
                }
            }
        }
    }
}

private struct AllAlertsPage: View {
    @ObservedObject var monitor: Monitor
    let router: MenuRouter
    let now: Date
    let open: (URL) -> Void
    @AppStorage("menuFilter") private var filterData = Data()
    @State private var expanded: Set<String> = []

    var body: some View {
        let status = Status(snapshot: monitor.snapshot, now: now)
        VStack(alignment: .leading, spacing: 0) {
            BackHeader(title: status.firing == 0 ? "Alerts" : "\(status.firing) firing", subtitle: status.detail(now: now), back: { router.go(.root) })
            let filter = MenuFilter.decode(filterData)
            if monitor.snapshot.alerts.count > 1 || filter.isActive {
                FilterBar(filter: MenuFilter.binding($filterData), environments: AlertFilter.environments(in: monitor.snapshot.alerts))
            }
            if monitor.snapshot.alerts.isEmpty {
                EmptyNote(text: status.offline > 0 ? "No alerts from reachable sources" : "No firing alerts")
            } else if !monitor.snapshot.alerts.contains(where: filter.matches) {
                EmptyNote(text: "No alerts match the filter")
            } else {
                AlertList {
                    ForEach(monitor.snapshot.sources.filter { $0.alerts.contains(where: filter.matches) }) { source in
                        let config = monitor.config.sources.first { $0.id == source.id }
                        let link = config.flatMap { URL(string: $0.linkURL) }.flatMap { $0.scheme == nil ? nil : $0 }
                        Text(source.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        AlertRows(monitor: monitor, alerts: source.alerts.filter(filter.matches), sourceID: source.id, config: config, now: now,
                                  dimmed: source.error != nil || source.isPaused, link: link, open: open, expanded: $expanded)
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

private struct BackHeader: View {
    let title: String
    let subtitle: String
    let back: () -> Void

    var body: some View {
        HoverRow(action: back) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
        }
        .keyboardShortcut(.leftArrow, modifiers: [])
        .accessibilityLabel("Back")
        .padding(.bottom, 4)
    }
}

/// Grows with its content up to a cap, then scrolls; a ScrollView alone would not size to its content.
private struct AlertList<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.bottom, 2)
                .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
        }
        .frame(height: min(height, 380))
        .onPreferenceChange(HeightKey.self) { height = $0 }
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AlertRow: View {
    let alert: Alert
    let config: Source?
    let now: Date
    let dimmed: Bool
    let url: URL?
    let open: (URL) -> Void
    var snooze: ((Snooze.Scope, Date) -> Void)?
    var unsnooze: (() -> Void)?
    var silence: ((Date) -> Void)?

    var body: some View {
        let runbook = alert.runbookURL
        let snoozed = alert.isSnoozed(now: now)
        let dashboard = config?.dashboardURL(for: alert)
        VStack(alignment: .leading, spacing: 0) {
            HoverRow(action: url.map { url in { open(url) } }) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    StatusDot(color: snoozed ? Theme.neutral : Theme.color(for: alert.severity), size: 8)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alert.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 6)
                    if let flaps = alert.flapCount, !snoozed {
                        Text("⟳ \(flaps)× in 1h").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.warning)
                            .help("Started firing \(flaps) times in the last hour")
                    }
                    if alert.isNew(now: now) && !snoozed { NewChip() }
                    if snoozed { Image(systemName: "moon.zzz").font(.system(size: 11)).foregroundStyle(.secondary) }
                    else if alert.severity != .none {
                        Text(alert.severity.label).font(.system(size: 11.5)).foregroundStyle(Theme.color(for: alert.severity))
                    }
                }
            }
            // Outside the row's button: a button inside a button label would swallow the click.
            if runbook != nil || dashboard != nil {
                HStack(spacing: 6) {
                    if let runbook { LinkChip(title: "Runbook", systemImage: "book") { open(runbook) } }
                    if let dashboard { LinkChip(title: "Dashboard", systemImage: "chart.xyaxis.line") { open(dashboard) } }
                }
                .padding(.leading, 34)
                .padding(.bottom, 4)
            }
        }
        .opacity(dimmed || snoozed ? 0.55 : 1)
        .help(alert.summary ?? alert.name)
        .contextMenu {
            if let snooze {
                if snoozed, let unsnooze { Button("Unsnooze") { unsnooze() } }
                Menu("Snooze") {
                    ForEach(Snooze.presets(now: now), id: \.label) { preset in Button(preset.label) { snooze(.alert, preset.until) } }
                }
                Menu("Snooze All \(alert.name)") {
                    ForEach(Snooze.presets(now: now), id: \.label) { preset in Button(preset.label) { snooze(.name, preset.until) } }
                }
                Divider()
            }
            if let silence {
                Menu("Silence Upstream") {
                    ForEach(Snooze.presets(now: now), id: \.label) { preset in Button(preset.label) { silence(preset.until) } }
                }
                Divider()
            }
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
        .accessibilityLabel("\(alert.severity.label) alert \(alert.name). \(subtitle)")
    }

    private var subtitle: String {
        if let until = alert.snoozedUntil, alert.isSnoozed(now: now) {
            return [alert.target, "snoozed until \(Format.clock(until))"].compactMap { $0 }.joined(separator: " · ")
        }
        return [alert.target, alert.activeAt.map { Format.duration(now.timeIntervalSince($0)) }, alert.owner].compactMap { $0 }.joined(separator: " · ")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// "Silenced until 13:00 · Undo", or why the silence failed. Clears itself after 10 seconds.
private struct SilenceBanner: View {
    @ObservedObject var monitor: Monitor
    let notice: Monitor.SilenceNotice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "bell.slash.fill")
                .foregroundStyle(notice.isError ? Theme.warning : Theme.iris)
            Text(notice.message).font(.system(size: 12)).lineLimit(2)
            Spacer(minLength: 4)
            if let id = notice.silenceID {
                Button("Undo") { Task { await monitor.expireSilence(id, in: notice.sourceID) } }
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .transition(.opacity)
    }
}

/// A small pill link under an alert: Runbook, Dashboard.
private struct LinkChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(hovered ? 0.12 : 0.06), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovered = $0 }
    }
}

/// The menu's filter, kept in UserDefaults so it survives closing the popover.
enum MenuFilter {
    static func decode(_ data: Data) -> AlertFilter { (try? JSONDecoder().decode(AlertFilter.self, from: data)) ?? AlertFilter() }

    static func binding(_ data: Binding<Data>) -> Binding<AlertFilter> {
        Binding(get: { decode(data.wrappedValue) },
                set: { data.wrappedValue = (try? JSONEncoder().encode($0)) ?? Data() })
    }
}

private struct FilterBar: View {
    @Binding var filter: AlertFilter
    let environments: [String]

    var body: some View {
        HStack(spacing: 8) {
            Picker("Severity", selection: $filter.minimum) {
                Text("All").tag(Severity.none)
                Text("Critical").tag(Severity.critical)
                Text("Warning+").tag(Severity.warning)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: 0)
            if !environments.isEmpty || filter.environment != nil {
                Menu {
                    Button("All Environments") { filter.environment = nil }
                    Divider()
                    ForEach(environments, id: \.self) { env in Button(env) { filter.environment = env } }
                } label: {
                    Text(filter.environment ?? "All envs").font(.system(size: 11.5))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

/// Alert rows with same-name alerts folded into one expandable row. Each child keeps its own row.
private struct AlertRows: View {
    let monitor: Monitor
    let alerts: [Alert]
    let sourceID: UUID
    let config: Source?
    let now: Date
    let dimmed: Bool
    let link: URL?
    let open: (URL) -> Void
    @Binding var expanded: Set<String>

    var body: some View {
        ForEach(Grouping.group(alerts, scope: sourceID.uuidString)) { group in
            if group.alerts.count == 1 {
                row(group.alerts[0])
            } else {
                GroupRow(group: group, now: now, expanded: expanded.contains(group.id)) {
                    if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                }
                .opacity(dimmed || group.alerts.allSatisfy { $0.isSnoozed(now: now) } ? 0.55 : 1)
                if expanded.contains(group.id) {
                    ForEach(group.alerts) { row($0).padding(.leading, 14) }
                }
            }
        }
    }

    private func row(_ alert: Alert) -> some View {
        AlertRow(alert: alert, config: config, now: now, dimmed: dimmed, url: alert.url.flatMap(URL.init(string:)) ?? link, open: open,
                 snooze: { scope, until in monitor.snooze(alert, in: sourceID, scope: scope, until: until) },
                 unsnooze: { monitor.unsnooze(alert, in: sourceID) },
                 // Prometheus and Mimir rulers don't know which Alertmanager routes their alerts: no guessing.
                 silence: config?.kind.canSilence == true ? { until in Task { await monitor.silence(alert, in: sourceID, until: until) } } : nil)
    }
}

private struct GroupRow: View {
    let group: AlertGroup
    let now: Date
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let longest = group.alerts.compactMap(\.activeAt).min().map { Format.duration(now.timeIntervalSince($0)) }
        HoverRow(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusDot(color: Theme.color(for: group.worst), size: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(group.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text("×\(group.alerts.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(([group.targets.joined(separator: ", ")].filter { !$0.isEmpty } + [longest].compactMap { $0 }).joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if group.alerts.contains(where: { $0.isNew(now: now) }) { NewChip() }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .accessibilityLabel("\(group.name), \(group.alerts.count) alerts. \(expanded ? "Collapse" : "Expand")")
    }
}

private struct NewChip: View {
    var body: some View {
        Text("NEW")
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Theme.iris)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Theme.iris.opacity(0.16), in: Capsule())
            .accessibilityLabel("New")
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

private struct CheckRow: View {
    let check: Check

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(check.name).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 6)
            Text(check.display).font(.system(size: 12.5)).monospacedDigit()
                .foregroundStyle(check.state == .unknown ? Theme.warning : .primary)
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(color).frame(width: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .help(check.message ?? check.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.name), \(check.display), \(check.state.rawValue)")
    }

    private var symbol: String {
        switch check.state {
        case .ok: "checkmark"
        case .warn: "exclamationmark"
        case .crit: "xmark"
        case .unknown: "questionmark"
        }
    }

    private var color: Color {
        switch check.state {
        case .ok: Theme.success
        case .warn, .unknown: Theme.warning
        case .crit: Theme.critical
        }
    }
}

private struct ResolvedRow: View {
    let item: ResolvedAlert
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.success).frame(width: 8)
            Text(item.alert.name).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 6)
            Text([item.alert.target, Format.ago(item.resolvedAt, now: now)].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .opacity(0.7)
        .accessibilityLabel("\(item.alert.name) resolved \(Format.ago(item.resolvedAt, now: now))")
    }
}

private struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }
}

/// A full-width row with the soft hover fill macOS uses in Control Center and menu-bar extras.
struct HoverRow<Content: View>: View {
    let action: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        Button { action?() } label: {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(hovered && action != nil ? Color.primary.opacity(0.09) : .clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .onHover { hovered = $0 }
        .padding(.horizontal, 6)
    }
}

private struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 26)
                .background(hovered ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7
    var body: some View { Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true) }
}

private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
    }
}
