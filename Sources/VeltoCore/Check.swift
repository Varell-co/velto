import Foundation

public enum CheckState: String, Codable, Sendable {
    case ok, warn, crit, unknown

    /// warn and crit count toward "firing"; unknown is shown but never counted, and never green.
    public var isBreach: Bool { self == .warn || self == .crit }

    public var severity: Severity {
        switch self {
        case .crit: .critical
        case .warn: .warning
        case .ok, .unknown: .none
        }
    }
}

/// A watched value: a pinned query, a target count, a probe. Shown when healthy too, unlike alerts.
public struct Check: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var value: Double?
    /// The value as people read it: "11 %", "214/216", "23 days", "no data".
    public var display: String
    public var state: CheckState
    /// Why it is unknown, or what the threshold was.
    public var message: String?

    public init(id: String, name: String, value: Double? = nil, display: String, state: CheckState, message: String? = nil) {
        self.id = id; self.name = name; self.value = value; self.display = display; self.state = state; self.message = message
    }
}

/// A PromQL query pinned to a Prometheus or Mimir source, with thresholds: a number to watch without
/// writing an alert rule.
public struct PinnedQuery: Codable, Identifiable, Hashable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case none, percent, bytes, seconds, days

        public var label: String {
            switch self {
            case .none: "Number"
            case .percent: "Percent"
            case .bytes: "Bytes"
            case .seconds: "Seconds"
            case .days: "Days"
            }
        }
    }

    /// Which side of the thresholds is bad.
    public enum Direction: String, Codable, CaseIterable, Sendable { case above, below }

    public var id: UUID
    public var name: String
    public var query: String
    public var unit: Unit
    public var direction: Direction
    public var warn: Double?
    public var crit: Double?

    public init(id: UUID = UUID(), name: String = "", query: String = "", unit: Unit = .none, direction: Direction = .above,
                warn: Double? = nil, crit: Double? = nil) {
        self.id = id; self.name = name; self.query = query; self.unit = unit; self.direction = direction; self.warn = warn; self.crit = crit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        unit = try c.decodeIfPresent(Unit.self, forKey: .unit) ?? .none
        direction = try c.decodeIfPresent(Direction.self, forKey: .direction) ?? .above
        warn = try c.decodeIfPresent(Double.self, forKey: .warn)
        crit = try c.decodeIfPresent(Double.self, forKey: .crit)
    }

    public var displayName: String { name.isEmpty ? query : name }

    /// Strictly past a threshold is bad: "crit above 0" fires at 1, "crit below 7" fires at 6.9.
    public func evaluate(_ value: Double?) -> (CheckState, String) {
        guard let value, value.isFinite else { return (.unknown, "no data") }
        func past(_ threshold: Double?) -> Bool {
            guard let threshold else { return false }
            return direction == .above ? value > threshold : value < threshold
        }
        let state: CheckState = past(crit) ? .crit : past(warn) ? .warn : .ok
        return (state, unit.format(value))
    }

    /// The worst value of a vector by this query's direction: the highest when high is bad.
    public func worst(of values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        return direction == .above ? finite.max() : finite.min()
    }

    public func check(value: Double?) -> Check {
        let (state, display) = evaluate(value)
        return Check(id: id.uuidString, name: displayName, value: value, display: display, state: state)
    }

    public func check(error: String) -> Check {
        Check(id: id.uuidString, name: displayName, display: "error", state: .unknown, message: error)
    }

    /// Ready-made queries for the editor's presets menu.
    public static let presets: [PinnedQuery] = [
        PinnedQuery(name: "Targets down", query: "count(up == 0) or vector(0)", unit: .none, direction: .above, crit: 0),
        PinnedQuery(name: "Lowest disk free",
                    query: #"min(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}) * 100"#,
                    unit: .percent, direction: .below, warn: 15, crit: 5),
        PinnedQuery(name: "Days until a certificate expires", query: "min((probe_ssl_earliest_cert_expiry - time()) / 86400)",
                    unit: .days, direction: .below, warn: 14, crit: 7),
    ]
}

extension PinnedQuery.Unit {
    /// "11 %", "1.2 GB", "340 ms", "23 days". Decimal (SI) bytes, like Finder.
    public func format(_ value: Double) -> String {
        switch self {
        case .none: return Self.number(value)
        case .percent: return Self.number(value) + " %"
        case .days:
            let days = Int(value.rounded(.down))
            return days == 1 ? "1 day" : "\(days) days"
        case .seconds:
            if abs(value) < 1 { return "\(Int((value * 1000).rounded())) ms" }
            if abs(value) < 60 { return Self.number(value) + " s" }
            return Format.duration(value)
        case .bytes:
            var scaled = value
            var index = 0
            let names = ["B", "KB", "MB", "GB", "TB", "PB"]
            while abs(scaled) >= 1000, index < names.count - 1 { scaled /= 1000; index += 1 }
            return (index == 0 ? "\(Int(scaled))" : Self.number(scaled, digits: 1)) + " " + names[index]
        }
    }

    /// Up to `digits` decimals, trailing zeros dropped; large values as whole numbers.
    static func number(_ value: Double, digits: Int = 2) -> String {
        if abs(value) >= 100 { return String(Int(value.rounded())) }
        var text = String(format: "%.\(abs(value) >= 10 ? min(digits, 1) : digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}

/// What one check of a source produced.
public struct SourceResult: Sendable {
    public var alerts: [Alert]
    public var checks: [Check]
    public init(alerts: [Alert] = [], checks: [Check] = []) { self.alerts = alerts; self.checks = checks }
}

/// Instant-query responses: `vector` and `scalar`.
public enum QueryParser {
    /// `[1700000000.123, "42"]`: a timestamp and the value as a string.
    private enum Sample: Decodable {
        case string(String), number(Double)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s) } else { self = .number(try c.decode(Double.self)) }
        }
    }
    private struct Series: Decodable { let value: [Sample]? }
    private struct DataBlock: Decodable {
        let values: [Double]
        enum CodingKeys: String, CodingKey { case resultType, result }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .resultType) {
            case "scalar": values = [QueryParser.number(try c.decode([Sample].self, forKey: .result))].compactMap { $0 }
            case "vector": values = try c.decode([Series].self, forKey: .result).compactMap { $0.value.flatMap(QueryParser.number) }
            default: throw FetchError.unexpectedResponse // matrix and string answers have no single number
            }
        }
    }
    private struct Response: Decodable {
        let data: DataBlock?
        let errorType: String?
        let error: String?
    }

    private static func number(_ pair: [Sample]) -> Double? {
        guard pair.count == 2, case .string(let s) = pair[1] else { return nil }
        return Double(s)
    }

    /// The numbers in the answer: one per series for a vector, one for a scalar.
    public static func values(_ data: Data) throws -> [Double] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let block = response.data else {
            throw FetchError.unexpectedResponse
        }
        return block.values
    }

    /// "bad_data: parse error at char 12" from a Prometheus error body, when there is one.
    public static func errorMessage(_ data: Data) -> String? {
        struct ErrorBody: Decodable { let errorType: String?; let error: String? }
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data), let error = body.error else { return nil }
        return [body.errorType, error].compactMap { $0 }.joined(separator: ": ")
    }
}
