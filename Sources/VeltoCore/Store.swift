import Foundation

public enum Store {
    public static let bundleID = "co.varell.velto"
    /// Posted by `velto refresh`; the running app checks all sources when it sees it.
    public static let refreshNotification = Notification.Name("co.varell.velto.refresh")

    /// `VELTO_HOME` points everything at another folder: used by the checks, handy for debugging.
    public static var directory: URL {
        if let home = ProcessInfo.processInfo.environment["VELTO_HOME"], !home.isEmpty { return URL(fileURLWithPath: home) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(bundleID)")
    }
    public static var configURL: URL { directory.appendingPathComponent("config.json") }
    public static var snapshotURL: URL { directory.appendingPathComponent("snapshot.json") }
    public static var historyURL: URL { directory.appendingPathComponent("history.jsonl") }
    public static var pulseConfigURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/pulse/config.toml") }

    public static func loadConfig() throws -> Config? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try decoder.decode(Config.self, from: data)
    }

    public static func save(_ config: Config) throws { try write(config, to: configURL) }

    public static func loadSnapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? decoder.decode(Snapshot.self, from: data)
    }

    public static func save(_ snapshot: Snapshot) throws { try write(snapshot, to: snapshotURL) }

    /// Atomic replace, so a status line reading mid-write sees the old file or the new one, never half.
    /// Owner-only permissions: the config names internal hosts even though it holds no secrets.
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try writeData(encoder.encode(value), to: url)
    }

    static func writeData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// One-time move from Pulse's `~/.config/pulse/config.toml`. Only the flat subset Pulse writes is read:
/// top-level keys and `[[sources]]` tables with string, number and boolean values.
public struct PulseImport {
    public var config = Config()
    /// Secrets that were inline in the TOML, by source id; the app moves them into the Keychain.
    public var secrets: [UUID: String] = [:]
    /// What could not be carried over, in plain words.
    public var notes: [String] = []

    public init(toml: String) {
        var tables: [[String: String]] = []
        var top: [String: String] = [:]
        var inSourceTable = false
        for raw in toml.components(separatedBy: .newlines) {
            let line = Self.stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                inSourceTable = line == "[[sources]]" || line == "[[source]]"
                if inSourceTable { tables.append([:]) }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = Self.unquote(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            if inSourceTable { tables[tables.count - 1][key] = value } else if tables.isEmpty { top[key] = value }
        }

        if let interval = top["interval_secs"].flatMap(Int.init) {
            config.refreshSeconds = Config.refreshChoices.min { abs($0 - interval) < abs($1 - interval) } ?? 30
        }
        for table in tables {
            let name = table["name"] ?? "source"
            guard let kind = table["kind"].flatMap(SourceKind.init(rawValue:)) else {
                notes.append("Skipped \(name): type \"\(table["kind"] ?? "?")\" is not supported yet")
                continue
            }
            var source = Source(name: name, kind: kind, url: table["url"] ?? "", orgID: table["org_id"] ?? "",
                                skipTLSVerify: table["insecure_skip_tls_verify"] == "true")
            if let token = table["bearer_token"], !token.isEmpty {
                source.auth = .bearer
                secrets[source.id] = token
            } else if let command = table["token_command"], !command.isEmpty {
                source.auth = .command
                source.tokenCommand = command
            } else if let user = table["username"], !user.isEmpty {
                source.auth = .basic
                source.username = user
                if let password = table["password"] { secrets[source.id] = password }
            }
            for key in ["bearer_token_env", "username_env", "password_env"] where table[key] != nil {
                notes.append("\(name): \(key) can't be read by a menu bar app; add the secret in Settings")
            }
            config.sources.append(source)
        }
    }

    private static func stripComment(_ line: String) -> String {
        var inString = false
        for (i, ch) in line.enumerated() {
            if ch == "\"" { inString.toggle() }
            if ch == "#", !inString { return String(line.prefix(i)) }
        }
        return line
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "'" ? inner : inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
