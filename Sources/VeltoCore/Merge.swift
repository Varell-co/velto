import Foundation

/// What one check changed for one source.
public struct MergeResult: Sendable {
    public var source: SourceSnapshot
    /// Alerts absent from the previous good check. Empty without a baseline, so a first check or a
    /// source coming back never floods notifications.
    public var started: [Alert]
    /// Alerts that stopped firing in this check, under the same baseline rule.
    public var ended: [Alert]
}

/// Folds one check result into a source's previous state. Pure, so the checks can pin it down; the app
/// calls it from `Monitor.apply`.
public enum SnapshotMerge {
    public static let resolvedWindow: TimeInterval = 3600
    public static let resolvedLimit = 20

    public static func merge(previous: SourceSnapshot, result: Result<[Alert], Error>, now: Date) -> MergeResult {
        merge(previous: previous, result: result.map { SourceResult(alerts: $0) }, now: now)
    }

    public static func merge(previous: SourceSnapshot, result: Result<SourceResult, Error>, now: Date) -> MergeResult {
        var next = previous
        next.lastAttempt = now
        next.resolved = prune(previous.resolved, now: now)
        guard case .success(let checked) = result else {
            // A failed check changes nothing but the error: cached alerts and checks stay, marked as such.
            if case .failure(let error) = result { next.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            return MergeResult(source: next, started: [], ended: [])
        }
        let fresh = checked.alerts
        next.checks = checked.checks
        let hasBaseline = previous.lastSuccess != nil
        let known = Dictionary(previous.alerts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var started: [Alert] = []
        next.alerts = fresh.map { alert in
            var alert = alert
            if let before = known[alert.id] {
                alert.firstSeen = before.firstSeen ?? previous.lastSuccess ?? now
            } else if hasBaseline {
                alert.firstSeen = now
                started.append(alert)
            } else {
                // First check ever: an alert that has fired for hours is not "new" just because Velto is.
                alert.firstSeen = alert.activeAt ?? now
            }
            return alert
        }
        let firing = Set(fresh.map(\.id))
        let ended = hasBaseline ? previous.alerts.filter { !firing.contains($0.id) } : []
        let carried = next.resolved.filter { !firing.contains($0.id) && !ended.map(\.id).contains($0.id) }
        next.resolved = Array((ended.map { ResolvedAlert(alert: $0, resolvedAt: now) } + carried).prefix(resolvedLimit))
        next.error = nil
        next.lastSuccess = now
        return MergeResult(source: next, started: started, ended: ended)
    }

    static func prune(_ resolved: [ResolvedAlert], now: Date) -> [ResolvedAlert] {
        Array(resolved.filter { now.timeIntervalSince($0.resolvedAt) < resolvedWindow }.prefix(resolvedLimit))
    }
}
