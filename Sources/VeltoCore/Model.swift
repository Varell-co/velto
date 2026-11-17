import Foundation

public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case prometheus, mimir, grafana, alertmanager, probes

    public var label: String {
        switch self {
        case .prometheus: "Prometheus"
        case .mimir: "Grafana Mimir"
        case .grafana: "Grafana Alerting"
        case .alertmanager: "Alertmanager"
        case .probes: "Probes"
        }
    }

    /// Kinds that answer the Alertmanager v2 API, where Velto can create silences.
    public var canSilence: Bool { self == .grafana || self == .alertmanager }

    /// Kinds that send `X-Scope-OrgID`: Mimir's ruler and Mimir's (or Cortex's) Alertmanager.
    public var usesTenant: Bool { self == .mimir || self == .alertmanager }
}

public enum AuthMethod: String, Codable, CaseIterable, Sendable {
    /// `bearer` and `basic` keep their secret in the Keychain, never in the config file.
    case none, bearer, command, basic

    public var label: String {
        switch self {
        case .none: "None"
        case .bearer: "Bearer token"
        case .command: "Token command"
        case .basic: "Username and password"
        }
    }
}

public struct Source: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: SourceKind
    public var url: String
    /// Mimir tenant, sent as X-Scope-OrgID.
    public var orgID: String
    public var auth: AuthMethod
    public var username: String
    /// Shell command whose output is the bearer token, e.g. `az account get-access-token ...`.
    public var tokenCommand: String
    public var skipTLSVerify: Bool
    /// Where "Open" goes for alerts that carry no link of their own, e.g. a Grafana alerting page.
    public var linkURL: String
    /// Only check when this holds, e.g. on the VPN. Otherwise the source is paused, not offline.
    public var requires: NetworkCondition?
    /// PromQL queries watched with thresholds. Prometheus and Mimir only.
    public var queries: [PinnedQuery]
    /// Adds a "Targets up" check from `/api/v1/targets`. Prometheus only: Mimir has no targets API.
    public var watchTargets: Bool
    /// HTTP, TCP, TLS and DNS checks for a `.probes` source.
    public var probes: [Probe]

    public init(id: UUID = UUID(), name: String = "", kind: SourceKind = .prometheus, url: String = "",
                orgID: String = "", auth: AuthMethod = .none, username: String = "", tokenCommand: String = "",
                skipTLSVerify: Bool = false, linkURL: String = "", requires: NetworkCondition? = nil,
                queries: [PinnedQuery] = [], watchTargets: Bool = false, probes: [Probe] = []) {
        self.id = id; self.name = name; self.kind = kind; self.url = url; self.orgID = orgID; self.auth = auth
        self.username = username; self.tokenCommand = tokenCommand; self.skipTLSVerify = skipTLSVerify; self.linkURL = linkURL
        self.requires = requires
        self.queries = queries
        self.watchTargets = watchTargets
        self.probes = probes
    }

    // Every field but id is optional on disk, so a hand-edited or older config still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Source()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        kind = try c.decodeIfPresent(SourceKind.self, forKey: .kind) ?? d.kind
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
        orgID = try c.decodeIfPresent(String.self, forKey: .orgID) ?? d.orgID
        auth = try c.decodeIfPresent(AuthMethod.self, forKey: .auth) ?? d.auth
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? d.username
        tokenCommand = try c.decodeIfPresent(String.self, forKey: .tokenCommand) ?? d.tokenCommand
        skipTLSVerify = try c.decodeIfPresent(Bool.self, forKey: .skipTLSVerify) ?? d.skipTLSVerify
        linkURL = try c.decodeIfPresent(String.self, forKey: .linkURL) ?? d.linkURL
        requires = try c.decodeIfPresent(NetworkCondition.self, forKey: .requires)
        queries = try c.decodeIfPresent([PinnedQuery].self, forKey: .queries) ?? []
        watchTargets = try c.decodeIfPresent(Bool.self, forKey: .watchTargets) ?? false
        probes = try c.decodeIfPresent([Probe].self, forKey: .probes) ?? []
    }

    public var displayName: String { name.isEmpty ? (URL(string: url)?.host ?? (kind == .probes ? "Probes" : "Untitled")) : name }
}

/// When a source may be checked. Unmet means "paused": the corporate stack is not down, you're at home.
public enum NetworkCondition: Codable, Hashable, Sendable {
    /// Any VPN tunnel (utun, ppp, ipsec) is up with a routable address.
    case vpn
    /// This host name resolves: the most reliable "on the corporate network" test with split DNS.
    case resolves(host: String)

    public var pausedReason: String {
        switch self {
        case .vpn: "VPN required"
        case .resolves(let host): "needs \(Self.hostName(host))"
        }
    }

    /// Accepts a bare host or a pasted URL.
    public static func hostName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://"), let host = URL(string: trimmed)?.host { return host }
        return trimmed.split(separator: "/").first.map(String.init)?.split(separator: ":").first.map(String.init) ?? trimmed
    }
}

public struct Config: Codable, Equatable, Sendable {
    public static let refreshChoices = [15, 30, 60, 120, 300]
    public var refreshSeconds: Int
    public var sources: [Source]
    public var notifyResolved: Bool
    /// Local snoozes. Velto only; nothing is sent upstream.
    public var mutes: [Mute]
    public var quietHours: QuietHours?

    public init(refreshSeconds: Int = 30, sources: [Source] = [], notifyResolved: Bool = false, mutes: [Mute] = [],
                quietHours: QuietHours? = nil) {
        self.refreshSeconds = refreshSeconds
        self.sources = sources
        self.notifyResolved = notifyResolved
        self.mutes = mutes
        self.quietHours = quietHours
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshSeconds = max(5, try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 30)
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        notifyResolved = try c.decodeIfPresent(Bool.self, forKey: .notifyResolved) ?? false
        mutes = try c.decodeIfPresent([Mute].self, forKey: .mutes) ?? []
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours)
    }
}

/// A local snooze: one alert (`alertID`) or every alert with this name in one source (`alertID == nil`).
public struct Mute: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var alertName: String
    public var alertID: String?
    public var until: Date

    public init(id: UUID = UUID(), sourceID: UUID, alertName: String, alertID: String? = nil, until: Date) {
        self.id = id; self.sourceID = sourceID; self.alertName = alertName; self.alertID = alertID; self.until = until
    }

    public func matches(_ alert: Alert, in sourceID: UUID) -> Bool {
        guard sourceID == self.sourceID else { return false }
        if let alertID { return alert.id == alertID }
        return alert.name == alertName
    }
}

/// Notifications pause between `start` and `end`, minutes after midnight. Counts and the menu are untouched.
public struct QuietHours: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var allowCritical: Bool

    public init(start: Int = 22 * 60, end: Int = 7 * 60, allowCritical: Bool = true) {
        self.start = start; self.end = end; self.allowCritical = allowCritical
    }

    /// Wraps midnight when `start > end` (22:00 to 07:00). Equal start and end means never.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if start == end { return false }
        return start < end ? (start..<end).contains(minute) : minute >= start || minute < end
    }

    /// Whether this alert may notify at `date`.
    public func allows(_ alert: Alert, at date: Date, calendar: Calendar = .current) -> Bool {
        !contains(date, calendar: calendar) || (allowCritical && alert.severity == .critical)
    }
}

public enum Severity: String, Codable, Comparable, CaseIterable, Sendable {
    case critical, warning, info, none

    /// Maps the many spellings seen in the wild ("page", "P1", "high", "3 - Moderate") onto four levels.
    public init(label: String?) {
        let value = (label ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "": self = .none
        case "critical", "crit", "page", "high", "error", "fatal", "emergency", "p1", "p2": self = .critical
        case "warning", "warn", "medium", "moderate", "p3": self = .warning
        case "info", "informational", "low", "notice", "p4", "p5", "none", "ok": self = .info
        default:
            if value.hasPrefix("1") || value.hasPrefix("2") { self = .critical }
            else if value.hasPrefix("3") { self = .warning }
            else if value.hasPrefix("4") || value.hasPrefix("5") { self = .info }
            else { self = .warning } // unknown but present: worth a look, not a page
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }

    public var label: String { self == .none ? "" : rawValue.capitalized }
}

public struct Alert: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var severity: Severity
    /// The label as the server sent it, shown when it differs from the normalized level.
    public var severityLabel: String?
    /// Instance, service or job: the "where" of the alert.
    public var target: String?
    public var summary: String?
    public var activeAt: Date?
    public var url: String?
    public var labels: [String: String]
    public var annotations: [String: String]
    /// When Velto first saw this alert firing. Set by the app, so the menu, the CLI and status lines agree on "new".
    public var firstSeen: Date?
    /// Set by the app from a matching local snooze. A snoozed alert still shows, dimmed, but is not counted.
    public var snoozedUntil: Date?

    /// Times this alert started firing in the last hour, set by the app only when it is 3 or more.
    public var flapCount: Int?

    public func isSnoozed(now: Date = Date()) -> Bool { (snoozedUntil ?? .distantPast) > now }

    /// How long an alert counts as new. Fixed, not per viewer: no read state to keep in sync.
    public static let newWindow: TimeInterval = 600

    public func isNew(now: Date = Date()) -> Bool {
        guard let firstSeen else { return false }
        return now.timeIntervalSince(firstSeen) < Self.newWindow
    }

    public init(id: String, name: String, severity: Severity, severityLabel: String? = nil, target: String? = nil,
                summary: String? = nil, activeAt: Date? = nil, url: String? = nil, labels: [String: String] = [:],
                annotations: [String: String] = [:]) {
        self.id = id; self.name = name; self.severity = severity; self.severityLabel = severityLabel
        self.target = target; self.summary = summary; self.activeAt = activeAt; self.url = url; self.labels = labels
        self.annotations = annotations
    }

    // Fields added after v0.1.0 are optional on disk, so an older snapshot still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed alert"
        severity = try c.decodeIfPresent(Severity.self, forKey: .severity) ?? .none
        severityLabel = try c.decodeIfPresent(String.self, forKey: .severityLabel)
        target = try c.decodeIfPresent(String.self, forKey: .target)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        activeAt = try c.decodeIfPresent(Date.self, forKey: .activeAt)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        annotations = try c.decodeIfPresent([String: String].self, forKey: .annotations) ?? [:]
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        flapCount = try c.decodeIfPresent(Int.self, forKey: .flapCount)
    }

    // MARK: Context

    private static func first(_ keys: [String], in values: [String: String]) -> String? {
        keys.lazy.compactMap { values[$0]?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    private static func web(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Only http(s): an annotation is free text, and a `file:` or app link should not open from one click.
    public var runbookURL: URL? { Self.web(Self.first(["runbook_url", "runbook", "playbook"], in: annotations)) }
    public var owner: String? { Self.first(["team", "owner", "squad", "service_owner"], in: labels) }
    public var environment: String? { Self.first(["env", "environment", "cluster", "tenant"], in: labels) }

    /// An explicit link wins; otherwise Grafana-managed rules carry the dashboard and panel they belong to.
    public func dashboardURL(base: String) -> URL? {
        if let explicit = Self.web(Self.first(["dashboard_url", "grafana_url"], in: annotations)) { return explicit }
        guard let uid = Self.first(["__dashboardUid__"], in: annotations) else { return nil }
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        guard Self.web(root) != nil else { return nil }
        let panel = Self.first(["__panelId__"], in: annotations).map { "?viewPanel=\($0)" } ?? ""
        return URL(string: "\(root)/d/\(uid)\(panel)")
    }
}

extension Source {
    /// The Grafana root that `/d/<uid>` links hang off: the dashboard link's host, or a Grafana source's own URL.
    public var grafanaBase: String? {
        if let link = URL(string: linkURL), let scheme = link.scheme, let host = link.host {
            return "\(scheme)://\(host)" + (link.port.map { ":\($0)" } ?? "")
        }
        return kind == .grafana ? url : nil
    }

    public func dashboardURL(for alert: Alert) -> URL? {
        alert.dashboardURL(base: grafanaBase ?? "")
    }
}

public struct SourceSnapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: SourceKind
    /// On a failed check this keeps the last good list: still the best information there is, and the
    /// error makes it clear it is cached.
    public var alerts: [Alert]
    public var error: String?
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    /// Alerts that stopped firing in the last hour, newest first.
    public var resolved: [ResolvedAlert]
    /// Set while the source's network condition is unmet. Its alerts are then cached, not current.
    public var pausedReason: String?
    /// Pinned queries, target health, probes. On a failed check these stay cached, like alerts.
    public var checks: [Check]

    public init(source: Source, alerts: [Alert] = [], error: String? = nil, lastAttempt: Date? = nil, lastSuccess: Date? = nil,
                resolved: [ResolvedAlert] = [], checks: [Check] = []) {
        id = source.id; name = source.displayName; kind = source.kind
        self.alerts = alerts; self.error = error; self.lastAttempt = lastAttempt; self.lastSuccess = lastSuccess
        self.resolved = resolved; self.checks = checks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(SourceKind.self, forKey: .kind) ?? .prometheus
        alerts = try c.decodeIfPresent([Alert].self, forKey: .alerts) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
        lastAttempt = try c.decodeIfPresent(Date.self, forKey: .lastAttempt)
        lastSuccess = try c.decodeIfPresent(Date.self, forKey: .lastSuccess)
        resolved = try c.decodeIfPresent([ResolvedAlert].self, forKey: .resolved) ?? []
        pausedReason = try c.decodeIfPresent(String.self, forKey: .pausedReason)
        checks = try c.decodeIfPresent([Check].self, forKey: .checks) ?? []
    }

    public var isPaused: Bool { pausedReason != nil }
    /// A paused source is not offline: Velto chose not to ask.
    public var isOffline: Bool { error != nil && !isPaused }

    /// What counts toward the badge: everything firing except snoozed alerts. Nothing while paused,
    /// since cached alerts from a source Velto can't reach are not current.
    public func firing(now: Date = Date()) -> [Alert] { isPaused ? [] : alerts.filter { !$0.isSnoozed(now: now) } }

    /// Checks in warn or crit. They count toward "firing" next to alerts.
    public var breaches: [Check] { isPaused ? [] : checks.filter(\.state.isBreach) }

    /// What the source's badge shows: unsnoozed alerts plus breached checks.
    public func attention(now: Date = Date()) -> Int { firing(now: now).count + breaches.count }

    /// The worst of firing alerts and breached checks.
    public func worst(now: Date = Date()) -> Severity {
        (firing(now: now).map(\.severity) + breaches.map(\.state.severity)).min() ?? .none
    }
}

public struct ResolvedAlert: Codable, Hashable, Identifiable, Sendable {
    public var alert: Alert
    public var resolvedAt: Date
    public var id: String { alert.id }
    public init(alert: Alert, resolvedAt: Date) { self.alert = alert; self.resolvedAt = resolvedAt }
}

/// What the app writes after every check and every integration reads: the CLI, xbar, Starship, Waybar.
public struct Snapshot: Codable, Equatable, Sendable {
    public var checkedAt: Date?
    public var refreshSeconds: Int
    public var sources: [SourceSnapshot]

    public init(checkedAt: Date? = nil, refreshSeconds: Int = 30, sources: [SourceSnapshot] = []) {
        self.checkedAt = checkedAt; self.refreshSeconds = refreshSeconds; self.sources = sources
    }

    /// Three missed checks, or 2 minutes for fast intervals: one slow poll is not "stale".
    public var staleAfter: TimeInterval { TimeInterval(max(refreshSeconds * 3, 120)) }

    public var alerts: [Alert] { sources.flatMap(\.alerts) }
    public func firing(now: Date = Date()) -> [Alert] { sources.flatMap { $0.firing(now: now) } }
}
