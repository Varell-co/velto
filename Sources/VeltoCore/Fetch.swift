import Foundation

/// Secrets resolved for one check. Kept out of `Source` so they never reach the config file or snapshot.
public struct Credentials: Sendable {
    public var token: String?
    public var password: String?
    public init(token: String? = nil, password: String? = nil) { self.token = token; self.password = password }
}

public enum FetchError: LocalizedError, Equatable {
    case invalidURL
    case http(Int)
    case unexpectedResponse
    case transport(String)
    case credentials(String)

    /// Short, human and free of secrets: these end up in the menu, the CLI and the snapshot file.
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The URL is not valid"
        case .http(401): "401 Unauthorized · check the credentials"
        case .http(403): "403 Forbidden · check access for this tenant"
        case .http(404): "404 Not found · check the URL and source type"
        case .http(let code): "Server answered \(code)"
        case .unexpectedResponse: "Unexpected response · is this the right source type?"
        case .transport(let message): message
        case .credentials(let message): message
        }
    }
}

extension Source {
    /// The alerts endpoint for this source type. Tolerates trailing slashes and a Mimir URL that already
    /// ends in `/prometheus`, the two most common copy-paste variants.
    public func alertsURL() -> URL? {
        var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let parsed = URL(string: base), parsed.scheme == "http" || parsed.scheme == "https", parsed.host != nil else { return nil }
        switch kind {
        case .prometheus:
            return URL(string: base + "/api/v1/alerts")
        case .mimir:
            return URL(string: base + (base.hasSuffix("/prometheus") ? "" : "/prometheus") + "/api/v1/alerts")
        case .grafana:
            return URL(string: base + "/api/alertmanager/grafana/api/v2/alerts?active=true&silenced=false&inhibited=false")
        case .alertmanager:
            return URL(string: base + "/api/v2/alerts?active=true&silenced=false&inhibited=false")
        case .probes:
            return nil // probes carry their own targets
        }
    }

    /// The Prometheus HTTP API root: `{base}/api/v1` for Prometheus, `{base}/prometheus/api/v1` for Mimir.
    public var prometheusAPI: String? {
        guard let alerts = alertsURL()?.absoluteString, kind == .prometheus || kind == .mimir else { return nil }
        return String(alerts.dropLast("/alerts".count))
    }

    /// `/api/v1/query?query=…`, with `+`, `&` and `=` escaped: URLComponents leaves `+` alone, and a
    /// server reads it as a space.
    public func queryURL(_ query: String) -> URL? {
        guard let api = prometheusAPI else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: api + "/query?query=" + encoded)
    }

    /// Where the Alertmanager v2 API lives, for silences. Nil for kinds that have none.
    public var alertmanagerBase: String? {
        var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        switch kind {
        case .alertmanager: return base
        case .grafana: return base + "/api/alertmanager/grafana"
        default: return nil
        }
    }

    /// Has a usable URL, or for probes at least one target. Incomplete sources are skipped by the poller
    /// and left out of the snapshot.
    public var isComplete: Bool {
        kind == .probes ? probes.contains { !$0.target.trimmingCharacters(in: .whitespaces).isEmpty } : alertsURL() != nil
    }

    public func request(credentials: Credentials) -> URLRequest? {
        alertsURL().map { request(for: $0, credentials: credentials) }
    }

    /// Any request to this source: same auth, same tenant, no caching.
    public func request(for url: URL, credentials: Credentials) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request, credentials: credentials)
        return request
    }

    public func authorize(_ request: inout URLRequest, credentials: Credentials) {
        switch auth {
        case .none: break
        case .bearer, .command:
            if let token = credentials.token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        case .basic:
            let pair = Data("\(username):\(credentials.password ?? "")".utf8).base64EncodedString()
            request.setValue("Basic \(pair)", forHTTPHeaderField: "Authorization")
        }
        let tenant = orgID.trimmingCharacters(in: .whitespaces)
        if kind.usesTenant, !tenant.isEmpty { request.setValue(tenant, forHTTPHeaderField: "X-Scope-OrgID") }
    }
}

public enum AlertParser {
    private struct PrometheusResponse: Decodable {
        struct DataBlock: Decodable { let alerts: [Raw] }
        struct Raw: Decodable {
            let labels: [String: String]
            let annotations: [String: String]?
            let state: String
            let activeAt: String?
        }
        let data: DataBlock
    }

    private struct GrafanaAlert: Decodable {
        struct State: Decodable { let state: String? }
        let labels: [String: String]
        let annotations: [String: String]?
        let startsAt: String?
        let fingerprint: String?
        let generatorURL: String?
        let status: State?
    }

    /// Prometheus `/api/v1/alerts` (also Mimir's ruler). Only `firing` counts; `pending` is not an alert yet.
    public static func prometheus(_ data: Data) throws -> [Alert] {
        guard let response = try? JSONDecoder().decode(PrometheusResponse.self, from: data) else { throw FetchError.unexpectedResponse }
        return response.data.alerts.filter { $0.state == "firing" }.map {
            alert(labels: $0.labels, annotations: $0.annotations ?? [:], activeAt: $0.activeAt, fingerprint: nil, url: nil)
        }.sorted(by: order)
    }

    /// Alertmanager v2 `/api/v2/alerts`: standalone, Mimir's, and Grafana's built-in one, which answers in the same shape.
    public static func alertmanagerV2(_ data: Data) throws -> [Alert] {
        guard let response = try? JSONDecoder().decode([GrafanaAlert].self, from: data) else { throw FetchError.unexpectedResponse }
        return response.filter { ($0.status?.state ?? "active") == "active" }.map {
            alert(labels: $0.labels, annotations: $0.annotations ?? [:], activeAt: $0.startsAt, fingerprint: $0.fingerprint, url: $0.generatorURL)
        }.sorted(by: order)
    }

    /// Worst first, then longest-firing first: the thing that needs attention sits on top.
    static func order(_ a: Alert, _ b: Alert) -> Bool {
        if a.severity != b.severity { return a.severity < b.severity }
        if a.activeAt != b.activeAt { return (a.activeAt ?? .distantFuture) < (b.activeAt ?? .distantFuture) }
        return a.name < b.name
    }

    private static func alert(labels: [String: String], annotations: [String: String], activeAt: String?, fingerprint: String?, url: String?) -> Alert {
        let severityLabel = labels["severity"] ?? labels["priority"]
        let target = ["instance", "pod", "service", "job", "namespace", "grafana_folder"].lazy.compactMap { labels[$0] }.first { !$0.isEmpty }
        let summary = ["summary", "description", "message"].lazy.compactMap { annotations[$0] }.first { !$0.isEmpty }
        return Alert(id: fingerprint ?? identity(labels), name: labels["alertname"] ?? "Unnamed alert",
                     severity: Severity(label: severityLabel), severityLabel: severityLabel, target: target,
                     summary: summary, activeAt: activeAt.flatMap(parseDate),
                     url: url.flatMap { $0.isEmpty ? nil : $0 }, labels: labels, annotations: annotations)
    }

    /// Prometheus has no fingerprint in this API; the full label set is what makes an alert unique.
    static func identity(_ labels: [String: String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a: stable across runs, unlike Hasher
        for byte in labels.sorted(by: { $0.key < $1.key }).map({ "\($0.key)=\($0.value)" }).joined(separator: "\u{1f}").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// RFC 3339 with any number of fractional digits. Prometheus sends nanoseconds, which
    /// ISO8601DateFormatter does not accept, so the fraction is cut to milliseconds first.
    public static func parseDate(_ string: String) -> Date? {
        var s = string
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = s[s.index(after: dot)..<end]
            s.replaceSubrange(s.index(after: dot)..<end, with: String((digits + "000").prefix(3)))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = s.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: s), date.timeIntervalSince1970 > 0 else { return nil } // Go's zero time means "unknown"
        return date
    }
}

/// Fetches one source. A fresh ephemeral session per check keeps cookies and caches out of the picture.
public enum Fetcher {
    public static func alerts(for source: Source, credentials: Credentials) async throws -> [Alert] {
        guard let request = source.request(credentials: credentials) else { throw FetchError.invalidURL }
        let data = try await send(request, for: source)
        return try source.kind.canSilence ? AlertParser.alertmanagerV2(data) : AlertParser.prometheus(data)
    }

    /// Alerts and every pinned query, concurrently. Only the alerts request decides whether the source is
    /// offline; a failing query marks just its own check unknown.
    public static func fetch(for source: Source, credentials: Credentials) async throws -> SourceResult {
        // Each probe carries its own state, so a probes source is never "offline" as a whole.
        if source.kind == .probes { return SourceResult(checks: await ProbeRunner.run(source.probes, skipTLSVerify: source.skipTLSVerify)) }
        async let targets = targetCheck(for: source, credentials: credentials)
        async let checks = queryChecks(for: source, credentials: credentials)
        let alerts = try await alerts(for: source, credentials: credentials)
        return SourceResult(alerts: alerts, checks: [await targets].compactMap { $0 } + (await checks))
    }

    /// "Targets up 214/216" from `/api/v1/targets`, when the source watches targets.
    public static func targetCheck(for source: Source, credentials: Credentials) async -> Check? {
        guard source.kind == .prometheus, source.watchTargets, let api = source.prometheusAPI,
              let url = URL(string: api + "/targets?state=active") else { return nil }
        do {
            return try TargetHealth.check(from: try await send(source.request(for: url, credentials: credentials), for: source))
        } catch {
            return TargetHealth.check(error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    static func queryChecks(for source: Source, credentials: Credentials) async -> [Check] {
        guard source.kind == .prometheus || source.kind == .mimir, !source.queries.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, Check).self) { group in
            for (index, query) in source.queries.enumerated() {
                group.addTask { (index, await check(query, for: source, credentials: credentials)) }
            }
            var results: [(Int, Check)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// One pinned query, evaluated. Never throws: errors become an unknown check with the reason.
    public static func check(_ query: PinnedQuery, for source: Source, credentials: Credentials) async -> Check {
        guard let url = source.queryURL(query.query) else { return query.check(error: FetchError.invalidURL.errorDescription!) }
        do {
            let (data, status) = try await exchange(source.request(for: url, credentials: credentials), for: source)
            guard (200..<300).contains(status) else {
                return query.check(error: QueryParser.errorMessage(data) ?? FetchError.http(status).errorDescription!)
            }
            return query.check(value: query.worst(of: try QueryParser.values(data)))
        } catch {
            return query.check(error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Sends one request to a source and returns the body of a 2xx answer; anything else is a `FetchError`.
    public static func send(_ request: URLRequest, for source: Source) async throws -> Data {
        let (data, status) = try await exchange(request, for: source)
        guard (200..<300).contains(status) else { throw FetchError.http(status) }
        return data
    }

    /// Body and status of any answer, so callers can read an error body. Transport failures throw.
    public static func exchange(_ request: URLRequest, for source: Source) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let delegate = source.skipTLSVerify ? TrustAllDelegate() : nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError { throw FetchError.transport(message(for: error)) }
        guard let http = response as? HTTPURLResponse else { throw FetchError.unexpectedResponse }
        return (data, http.statusCode)
    }

    private static func message(for error: URLError) -> String {
        switch error.code {
        case .timedOut: "Timed out after 10s"
        case .cannotFindHost, .dnsLookupFailed: "Host not found · VPN?"
        case .cannotConnectToHost: "Connection refused"
        case .notConnectedToInternet: "No network connection"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            "TLS certificate not trusted"
        default: error.localizedDescription
        }
    }
}

/// Only used when the user ticks "Skip TLS verification" for a self-signed source.
private final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
