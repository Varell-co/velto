import Foundation

/// Upstream silences, for Alertmanager and Grafana sources. App only: the CLI never touches the network.
public enum SilenceRequest {
    public static let comment = "Silenced from Velto"

    /// POST `{base}/api/v2/silences` matching the alert's full label set exactly, so only this alert is
    /// silenced, never a look-alike from another instance.
    public static func make(source: Source, alert: Alert, until: Date, now: Date = Date(), user: String,
                            credentials: Credentials = Credentials()) -> URLRequest? {
        guard let base = source.alertmanagerBase, let url = URL(string: base + "/api/v2/silences"), !alert.labels.isEmpty else { return nil }
        struct Matcher: Encodable { let name: String; let value: String; let isEqual: Bool; let isRegex: Bool }
        struct Body: Encodable { let matchers: [Matcher]; let startsAt: String; let endsAt: String; let createdBy: String; let comment: String }
        let formatter = ISO8601DateFormatter()
        let body = Body(matchers: alert.labels.sorted { $0.key < $1.key }.map { Matcher(name: $0.key, value: $0.value, isEqual: true, isRegex: false) },
                        startsAt: formatter.string(from: now), endsAt: formatter.string(from: until),
                        createdBy: user, comment: comment)
        var request = source.request(for: url, credentials: credentials)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try? encoder.encode(body)
        return request
    }

    /// DELETE `{base}/api/v2/silence/{id}`: the Undo.
    public static func expire(source: Source, id: String, credentials: Credentials = Credentials()) -> URLRequest? {
        guard let base = source.alertmanagerBase, let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: base + "/api/v2/silence/" + escaped) else { return nil }
        var request = source.request(for: url, credentials: credentials)
        request.httpMethod = "DELETE"
        return request
    }

    /// `{"silenceID": "…"}`.
    public static func silenceID(from data: Data) throws -> String {
        struct Response: Decodable { let silenceID: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw FetchError.unexpectedResponse }
        return response.silenceID
    }
}
