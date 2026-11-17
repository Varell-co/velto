import Foundation

/// One fire or resolve, as Velto saw it. Local only: a week of "did this keep coming back?".
public struct HistoryEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case fired, resolved }

    public var at: Date
    public var sourceID: UUID
    public var source: String
    public var alertID: String
    public var name: String
    public var target: String?
    public var kind: Kind

    public init(at: Date, sourceID: UUID, source: String, alertID: String, name: String, target: String? = nil, kind: Kind) {
        self.at = at; self.sourceID = sourceID; self.source = source; self.alertID = alertID
        self.name = name; self.target = target; self.kind = kind
    }

    public init(_ kind: Kind, _ alert: Alert, in source: SourceSnapshot, at: Date) {
        self.init(at: at, sourceID: source.id, source: source.name, alertID: alert.id, name: alert.name, target: alert.target, kind: kind)
    }
}

/// `history.jsonl` next to the snapshot: append-only JSON lines, pruned to 7 days and 5,000 lines.
public enum History {
    public static let keep: TimeInterval = 7 * 86400
    public static let maxLines = 5000
    public static let flapWindow: TimeInterval = 3600
    public static let flapThreshold = 3

    private static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static func append(_ events: [HistoryEvent]) throws {
        guard !events.isEmpty else { return }
        let url = Store.historyURL
        var data = Data()
        for event in events { data += try lineEncoder.encode(event) + Data("\n".utf8) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return try Store.writeData(data, to: url) }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Oldest first. A corrupt line (a crash mid-write, a hand edit) is skipped, never fatal.
    public static func load(since: Date? = nil) -> [HistoryEvent] {
        guard let data = try? Data(contentsOf: Store.historyURL) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let event = try? Store.decoder.decode(HistoryEvent.self, from: Data(line)) else { return nil }
            return since.map { event.at >= $0 } ?? true ? event : nil
        }
    }

    /// Atomic rewrite: a reader sees the old file or the new one.
    public static func prune(now: Date = Date()) throws {
        let all = load()
        let kept = Array(all.filter { now.timeIntervalSince($0.at) < keep }.suffix(maxLines))
        guard kept.count != all.count else { return }
        var data = Data()
        for event in kept { data += try lineEncoder.encode(event) + Data("\n".utf8) }
        try Store.writeData(data, to: Store.historyURL)
    }

    /// How often this alert started firing in the last hour.
    public static func flapCount(alertID: String, events: [HistoryEvent], now: Date) -> Int {
        events.filter { $0.kind == .fired && $0.alertID == alertID && now.timeIntervalSince($0.at) < flapWindow && $0.at <= now }.count
    }
}
