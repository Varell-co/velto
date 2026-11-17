import Foundation

/// Text output for every integration. Pure functions of the snapshot, so the checks can pin them down.
public enum Render {
    // MARK: Terminal

    public struct Style {
        public var color: Bool
        public init(color: Bool) { self.color = color }

        public func paint(_ text: String, _ code: String) -> String { color ? "\u{1b}[\(code)m\(text)\u{1b}[0m" : text }
        public func bold(_ t: String) -> String { paint(t, "1") }
        public func muted(_ t: String) -> String { paint(t, "2") }
        // Brand tokens as 24-bit colors: critical #E66A56, warning #E8AD61, success #6EBFA5, info #78A6D8, iris #8E93F2.
        public func critical(_ t: String) -> String { paint(t, "38;2;230;106;86") }
        public func warning(_ t: String) -> String { paint(t, "38;2;232;173;97") }
        public func success(_ t: String) -> String { paint(t, "38;2;110;191;165") }
        public func info(_ t: String) -> String { paint(t, "38;2;120;166;216") }

        public func severity(_ s: Severity, _ t: String) -> String {
            switch s {
            case .critical: critical(t)
            case .warning: warning(t)
            case .info: info(t)
            case .none: muted(t)
            }
        }

        public func health(_ status: Status, _ t: String) -> String {
            switch status.health {
            case .healthy: success(t)
            case .firing, .partial: status.worst == .critical || status.worst == .none ? critical(t) : severity(status.worst, t)
            case .stale, .offline, .unavailable: warning(t)
            case .loading, .unconfigured, .paused: muted(t)
            }
        }
    }

    /// `velto alerts`: grouped by source, worst first, aligned columns. Uses dots as text, never emoji.
    /// `grouped` folds same-name alerts within a source into one row; each keeps its own identity.
    public static func alerts(_ snapshot: Snapshot?, source: String? = nil, filter: AlertFilter = AlertFilter(), grouped: Bool = false,
                              style: Style, now: Date = Date()) -> String {
        let status = Status(snapshot: snapshot, now: now)
        guard let snapshot, !snapshot.sources.isEmpty else { return style.health(status, status.headline) + "\n" + style.muted(status.detail(now: now)) + "\n" }
        let groups = snapshot.sources.filter { source == nil || $0.name.caseInsensitiveCompare(source!) == .orderedSame }
        if groups.isEmpty { return "No source named \"\(source!)\". Sources: \(snapshot.sources.map(\.name).joined(separator: ", "))\n" }

        var out = style.health(status, status.headline) + style.muted("  (\(Format.count(snapshot.sources.count, "source")))") + "\n"
        out += style.muted(status.detail(now: now)) + "\n"
        let shown = groups.map { group in (group, group.alerts.filter(filter.matches)) }
        let nameWidth = min(36, (shown.flatMap(\.1).map { $0.name.count + (grouped ? 4 : 0) }
            + groups.flatMap(\.breaches).map(\.name.count)).max() ?? 0)
        func pad(_ text: String) -> String {
            text.count > nameWidth ? String(text.prefix(nameWidth - 1)) + "…" : text.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        }
        for (group, alerts) in shown {
            out += "\n  " + style.bold(group.name) + "  "
            if let reason = group.pausedReason {
                out += style.muted("paused · \(reason)")
                if !group.alerts.isEmpty { out += style.muted(" · cached from \(group.lastSuccess.map { Format.ago($0, now: now) } ?? "earlier")") }
            } else if let error = group.error {
                out += style.warning("offline") + style.muted(" · \(error)")
                if !group.alerts.isEmpty { out += style.muted(" · showing cached") }
            } else {
                let firing = alerts.filter { !$0.isSnoozed(now: now) }.count + group.breaches.count
                out += firing == 0 ? style.success("0 firing") : style.critical("\(firing) firing")
                if firing < alerts.count { out += style.muted(" · \(alerts.count - firing) snoozed") }
            }
            out += "\n"
            for row in grouped ? Grouping.group(alerts) : alerts.map({ AlertGroup(id: $0.id, name: $0.name, alerts: [$0]) }) {
                if row.alerts.count > 1 {
                    out += "    " + style.severity(row.worst, "●") + " " + pad("\(row.name) ×\(row.alerts.count)") + "  "
                        + style.muted(row.targets.joined(separator: ", ")) + "\n"
                    continue
                }
                let alert = row.alerts[0]
                if let until = alert.snoozedUntil, alert.isSnoozed(now: now) {
                    out += "    " + style.muted("◌ " + pad(alert.name) + "  " + [alert.target, "snoozed until \(Format.clock(until))"].compactMap { $0 }.joined(separator: " · ")) + "\n"
                    continue
                }
                let place = [alert.target, alert.activeAt.map { Format.duration(now.timeIntervalSince($0)) }, alert.owner].compactMap { $0 }.joined(separator: " · ")
                out += "    " + style.severity(alert.severity, "●") + " " + pad(alert.name) + "  " + style.muted(place)
                    + (alert.isNew(now: now) ? "  " + style.info("new") : "")
                    + (alert.flapCount.map { "  " + style.warning("⟳ \($0)× in 1h") } ?? "") + "\n"
                if let runbook = alert.runbookURL { out += "      " + style.muted("runbook: \(runbook.absoluteString)") + "\n" }
            }
            for check in group.checks where check.state.isBreach && filter.minimum >= check.state.severity {
                out += "    " + style.severity(check.state.severity, "●") + " " + pad(check.name) + "  " + style.muted(check.display) + "\n"
            }
            let resolved = group.resolved.filter { now.timeIntervalSince($0.resolvedAt) < SnapshotMerge.resolvedWindow }
            if !resolved.isEmpty {
                out += "    " + style.muted("resolved in the last hour") + "\n"
                for item in resolved {
                    let place = [item.alert.target, Format.ago(item.resolvedAt, now: now)].compactMap { $0 }.joined(separator: " · ")
                    out += "    " + style.success("✓") + " " + style.muted(item.alert.name + "  " + place) + "\n"
                }
            }
        }
        return out
    }

    /// `velto checks`: every check per source, healthy ones too, with ✓ ! × ? marks.
    public static func checks(_ snapshot: Snapshot?, source: String? = nil, style: Style, now: Date = Date()) -> String {
        let sources = (snapshot?.sources ?? []).filter { !$0.checks.isEmpty && (source == nil || $0.name.caseInsensitiveCompare(source!) == .orderedSame) }
        guard !sources.isEmpty else {
            return style.muted(source.map { "No checks for a source named \"\($0)\"." } ?? "No checks yet. Add pinned queries, target health or probes to a source in Settings.") + "\n"
        }
        let width = min(36, sources.flatMap(\.checks).map(\.name.count).max() ?? 0)
        var out = ""
        for group in sources {
            out += (out.isEmpty ? "" : "\n") + "  " + style.bold(group.name)
            if let reason = group.pausedReason { out += "  " + style.muted("paused · \(reason) · cached") }
            else if group.error != nil { out += "  " + style.warning("offline · cached") }
            out += "\n"
            for check in group.checks {
                let mark = switch check.state {
                case .ok: style.success("✓")
                case .warn: style.warning("!")
                case .crit: style.critical("×")
                case .unknown: style.warning("?")
                }
                let name = check.name.count > width ? String(check.name.prefix(width - 1)) + "…" : check.name.padding(toLength: width, withPad: " ", startingAt: 0)
                out += "    " + mark + " " + name + "  " + check.display + (check.message.map { style.muted("  " + $0) } ?? "") + "\n"
            }
        }
        return out
    }

    /// `velto history`: newest first, grouped by day.
    public static func history(_ events: [HistoryEvent], style: Style, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard !events.isEmpty else { return style.muted("No alerts fired or resolved in this period.") + "\n" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM"
        var out = ""
        var day: Date?
        let nameWidth = min(36, events.map(\.name.count).max() ?? 0)
        for event in events.sorted(by: { $0.at > $1.at }) {
            let start = calendar.startOfDay(for: event.at)
            if start != day {
                day = start
                let label = calendar.isDate(start, inSameDayAs: now) ? "Today" : calendar.isDate(start, inSameDayAs: now.addingTimeInterval(-86400)) ? "Yesterday" : formatter.string(from: start)
                out += (out.isEmpty ? "" : "\n") + style.bold(label) + "\n"
            }
            let mark = event.kind == .fired ? style.critical("●") : style.success("✓")
            let name = event.name.count > nameWidth ? String(event.name.prefix(nameWidth - 1)) + "…" : event.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let place = [event.source, event.target].compactMap { $0 }.joined(separator: " · ")
            out += "  " + style.muted(Format.clock(event.at, calendar: calendar)) + "  " + mark + " " + name + "  "
                + style.muted("\(event.kind == .fired ? "fired" : "resolved") · \(place)") + "\n"
        }
        return out
    }

    // MARK: Status lines

    public static func plain(_ snapshot: Snapshot?, now: Date = Date()) -> String { "\(Status(snapshot: snapshot, now: now).firing)" }

    /// Starship: nothing when healthy, so the segment disappears; otherwise the compact count.
    public static func starship(_ snapshot: Snapshot?, now: Date = Date()) -> String { Status(snapshot: snapshot, now: now).compact }

    /// Waybar `custom` module with `return-type: json`. `class` carries the health for CSS styling.
    public static func waybar(_ snapshot: Snapshot?, now: Date = Date()) -> String {
        let status = Status(snapshot: snapshot, now: now)
        var tooltip = alerts(snapshot, style: Style(color: false), now: now).trimmingCharacters(in: .newlines)
        if snapshot?.sources.contains(where: { !$0.checks.isEmpty }) == true {
            tooltip += "\n\nChecks\n" + checks(snapshot, style: Style(color: false), now: now).trimmingCharacters(in: .newlines)
        }
        let payload: [String: String] = ["text": status.compact.isEmpty ? "0" : status.compact, "tooltip": tooltip,
                                         "class": status.health.rawValue, "alt": status.health.rawValue]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// xbar / SwiftBar plugin output. Each alert row opens its link when it has one.
    public static func xbar(_ snapshot: Snapshot?, cli: String, now: Date = Date()) -> String {
        let status = Status(snapshot: snapshot, now: now)
        let symbol: String = switch status.health {
        case .paused: "pause.circle"
        case .healthy: "checkmark.circle"
        case .firing, .partial: "flame"
        default: "exclamationmark.circle"
        }
        var lines = ["\(status.compact) | sfimage=\(symbol)", "---", "\(status.headline) | size=14", "\(status.detail(now: now)) | color=gray size=11"]
        for source in snapshot?.sources ?? [] {
            lines.append("---")
            if let reason = source.pausedReason {
                lines.append("\(clean(source.name)): paused · \(clean(reason)) | color=gray")
                continue
            }
            lines.append(source.error.map { "\(clean(source.name)): offline · \(clean($0)) | color=#E8AD61" } ?? "\(clean(source.name)): \(source.attention(now: now)) firing")
            for alert in source.alerts {
                if let until = alert.snoozedUntil, alert.isSnoozed(now: now) {
                    lines.append("◌ \(clean(alert.name))  snoozed until \(Format.clock(until)) | color=gray trim=false")
                    continue
                }
                let color = switch alert.severity { case .critical: "#E66A56"; case .warning: "#E8AD61"; default: "#78A6D8" }
                let place = [alert.target, alert.activeAt.map { Format.duration(now.timeIntervalSince($0)) }].compactMap { $0 }.joined(separator: " · ")
                var line = "● \(clean(alert.name))  \(clean(place)) | color=\(color) trim=false"
                if let url = alert.url { line += " href=\(url)" }
                lines.append(line)
                // Without the app's config there is no Grafana base, so only explicit dashboard links show here.
                if let runbook = alert.runbookURL { lines.append("--Runbook | href=\(runbook.absoluteString)") }
                if let dashboard = alert.dashboardURL(base: "") { lines.append("--Dashboard | href=\(dashboard.absoluteString)") }
            }
        }
        let checks = (snapshot?.sources ?? []).flatMap { source in source.checks.map { (source, $0) } }
        if !checks.isEmpty {
            lines += ["---", "Checks | color=gray size=11"]
            for (source, check) in checks {
                let color = switch check.state { case .ok: "#6EBFA5"; case .warn, .unknown: "#E8AD61"; case .crit: "#E66A56" }
                lines.append("\(clean(check.name))  \(clean(check.display)) | color=\(source.isPaused ? "gray" : color) trim=false")
            }
        }
        lines += ["---", "Refresh now | bash=\(cli) param1=refresh terminal=false refresh=true"]
        return lines.joined(separator: "\n")
    }

    /// `|` starts xbar's parameter section, so it must not appear in a title.
    private static func clean(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "¦") }

    public static func json(_ snapshot: Snapshot?, now: Date = Date()) -> String {
        struct Payload: Encodable { let status: String; let firing: Int; let offline: Int; let snapshot: Snapshot? }
        let status = Status(snapshot: snapshot, now: now)
        let data = (try? Store.encoder.encode(Payload(status: status.health.rawValue, firing: status.firing, offline: status.offline, snapshot: snapshot))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
