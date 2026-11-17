import Foundation

/// The brand's canonical states. Order of precedence is in `Status.init`.
public enum Health: String, Codable, Sendable {
    /// No snapshot on disk: the app has never run, or the file is unreadable.
    case unavailable
    /// The app runs but no source is configured.
    case unconfigured
    /// Sources exist, none has been checked yet.
    case loading
    /// The last check is too old to trust.
    case stale
    /// Every source failed its last check.
    case offline
    /// Some sources failed, others answered.
    case partial
    case firing
    case healthy
    /// Every source is paused by its network condition, e.g. off the VPN.
    case paused
}

public struct Status: Equatable, Sendable {
    public let health: Health
    public let firing: Int
    public let sources: Int
    public let offline: Int
    public let checkedAt: Date?
    public let worst: Severity
    /// Firing but snoozed locally: shown dimmed, left out of `firing` and `worst`.
    public let snoozed: Int
    /// Sources whose network condition is unmet. Neither offline nor healthy.
    public let paused: Int
    /// Why, when every source is paused: "VPN required".
    public let pausedReason: String?
    /// Checks that returned no data or failed: shown, never counted, never green.
    public let unknownChecks: Int

    /// Never reports "0 firing" while a source is unverified: a failed or stale check wins over a calm count.
    public init(snapshot: Snapshot?, now: Date = Date()) {
        let sources = snapshot?.sources ?? []
        let alerts = sources.flatMap { $0.firing(now: now) }
        let breaches = sources.flatMap(\.breaches)
        let active = sources.filter { !$0.isPaused }
        firing = alerts.count + breaches.count
        snoozed = active.flatMap(\.alerts).count - alerts.count
        unknownChecks = active.flatMap(\.checks).filter { $0.state == .unknown }.count
        paused = sources.count - active.count
        pausedReason = Array(Set(sources.compactMap(\.pausedReason))).sorted().joined(separator: ", ").nonEmpty
        self.sources = active.count
        offline = active.filter(\.isOffline).count
        checkedAt = snapshot?.checkedAt
        worst = (alerts.map(\.severity) + breaches.map(\.state.severity)).min() ?? .none

        if snapshot == nil { health = .unavailable }
        else if sources.isEmpty { health = .unconfigured }
        else if !active.isEmpty, active.allSatisfy({ $0.lastAttempt == nil }) { health = .loading }
        // Stale before paused: if the app stopped, "paused" would be a claim nobody is checking.
        else if let checkedAt, let snapshot, now.timeIntervalSince(checkedAt) > snapshot.staleAfter { health = .stale }
        else if active.isEmpty { health = .paused }
        else if offline == active.count { health = .offline }
        else if offline > 0 { health = .partial }
        else if firing > 0 { health = .firing }
        else { health = .healthy }
    }

    /// The short headline, e.g. "3 firing · 1 offline". Mirrors the brand's status language.
    public var headline: String {
        switch health {
        case .unavailable: "? unavailable"
        case .unconfigured: "No sources"
        case .loading: "… checking"
        case .stale: "\(firing) cached · stale"
        case .offline: "! offline"
        case .partial: "\(firing) firing · \(offline) offline"
        case .firing: "\(firing) firing"
        case .healthy: "All clear"
        case .paused: "Paused"
        }
    }

    /// The menu-bar text next to the mark. Empty when healthy: the tool should feel invisible then.
    public var compact: String {
        switch health {
        case .unavailable, .stale: "?"
        case .unconfigured, .healthy: ""
        case .loading: "…"
        case .offline: "!"
        case .partial: "\(firing)!"
        case .firing: "\(firing)"
        case .paused: "‖"
        }
    }

    /// One line under the headline: freshness first, then source health.
    public func detail(now: Date = Date()) -> String {
        switch health {
        case .unavailable: return "Open Velto to start checking."
        case .unconfigured: return "No sources yet. Add one to get started."
        case .loading: return "First check in progress"
        case .paused: return "Paused · \(pausedReason ?? "network condition not met")"
        default: break
        }
        var parts: [String] = []
        if let checkedAt { parts.append(health == .stale ? "Showing cached alerts · last checked \(Format.ago(checkedAt, now: now))" : "Last checked \(Format.ago(checkedAt, now: now))") }
        if offline > 0 {
            parts.append(offline == 1 ? "1 source unreachable" : "\(offline) sources unreachable")
        } else if health != .stale {
            parts.append(sources == 1 ? "1 source healthy" : "\(sources) sources healthy")
        }
        if paused > 0 { parts.append("\(paused) paused") }
        if snoozed > 0 { parts.append("\(snoozed) snoozed") }
        if unknownChecks > 0 { parts.append(unknownChecks == 1 ? "1 check no data" : "\(unknownChecks) checks no data") }
        return parts.joined(separator: " · ")
    }
}

public enum Format {
    /// Firing durations: "8m", "2h 5m", "3d 4h". Under a minute counts as "1m" so it never reads "0m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(1, m))m"
    }

    /// Freshness: "just now", "12s ago", "3m ago", "2h ago".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    /// Wall-clock time for "snoozed until 14:00". 24-hour, like the rest of Velto's terse output.
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    public static func count(_ n: Int, _ singular: String) -> String { "\(n) \(singular)\(n == 1 ? "" : "s")" }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
