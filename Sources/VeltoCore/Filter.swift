import Foundation

/// What the menu, the window and `velto alerts` show. Filtering hides rows; it never changes counts.
public struct AlertFilter: Codable, Equatable, Sendable {
    /// Show alerts at this severity or worse; `.none` shows everything.
    public var minimum: Severity
    public var environment: String?
    public var text: String

    public init(minimum: Severity = .none, environment: String? = nil, text: String = "") {
        self.minimum = minimum; self.environment = environment; self.text = text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minimum = try c.decodeIfPresent(Severity.self, forKey: .minimum) ?? .none
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    public var isActive: Bool { minimum != .none || environment != nil || !text.isEmpty }

    public func matches(_ alert: Alert) -> Bool {
        guard alert.severity <= minimum else { return false }
        if let environment, alert.environment?.caseInsensitiveCompare(environment) != .orderedSame { return false }
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return ([alert.name, alert.target, alert.summary] + alert.labels.values.map(Optional.some))
            .contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    /// The environments present, for a picker: only offer what would match something.
    public static func environments(in alerts: [Alert]) -> [String] {
        Array(Set(alerts.compactMap(\.environment))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// Same-name alerts in one source, shown as one row. Display only: each alert keeps its own id, so two
/// different incidents that share a name are never merged into one.
public struct AlertGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let alerts: [Alert]

    public init(id: String, name: String, alerts: [Alert]) { self.id = id; self.name = name; self.alerts = alerts }

    public var worst: Severity { alerts.map(\.severity).min() ?? .none }
    public var targets: [String] { alerts.compactMap(\.target) }
}

public enum Grouping {
    /// Groups by `alertname` in first-seen order, so the existing worst-first sort is kept.
    public static func group(_ alerts: [Alert], scope: String = "") -> [AlertGroup] {
        var order: [String] = []
        var members: [String: [Alert]] = [:]
        for alert in alerts {
            if members[alert.name] == nil { order.append(alert.name) }
            members[alert.name, default: []].append(alert)
        }
        return order.map { AlertGroup(id: scope + "/" + $0, name: $0, alerts: members[$0]!) }
    }
}

public enum Snooze {
    public enum Scope: Sendable { case alert, name }

    /// The menu's snooze choices: 1 hour, 4 hours, and 09:00 the next calendar day.
    public static func presets(now: Date = Date(), calendar: Calendar = .current) -> [(label: String, until: Date)] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        return [("1 Hour", now.addingTimeInterval(3600)), ("4 Hours", now.addingTimeInterval(4 * 3600)), ("Until Tomorrow 09:00", nine)]
    }

    /// Sets `snoozedUntil` on every alert from the latest unexpired matching mute, and clears it otherwise.
    public static func apply(_ mutes: [Mute], to source: inout SourceSnapshot, now: Date) {
        for index in source.alerts.indices {
            source.alerts[index].snoozedUntil = mutes
                .filter { $0.until > now && $0.matches(source.alerts[index], in: source.id) }
                .map(\.until).max()
        }
    }
}
