import Foundation
import Network
import Security

/// A built-in check that needs no Prometheus: is this URL answering, this port open, this certificate
/// far from expiry, this name resolving.
public struct Probe: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case http, tcp, tls, dns

        public var label: String {
            switch self {
            case .http: "HTTP"
            case .tcp: "TCP port"
            case .tls: "TLS certificate"
            case .dns: "DNS"
            }
        }

        public var placeholder: String {
            switch self {
            case .http: "https://status.example.com/health"
            case .tcp: "db.example.com:5432"
            case .tls: "example.com:443"
            case .dns: "example.com"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var type: Kind
    public var target: String
    /// HTTP only: the statuses that count as up. Default 200...399.
    public var expectStatus: ClosedRange<Int>?
    /// TLS only: days left that turn the check warn and crit.
    public var warnDays: Int
    public var critDays: Int

    public init(id: UUID = UUID(), name: String = "", type: Kind = .http, target: String = "", expectStatus: ClosedRange<Int>? = nil,
                warnDays: Int = 14, critDays: Int = 7) {
        self.id = id; self.name = name; self.type = type; self.target = target; self.expectStatus = expectStatus
        self.warnDays = warnDays; self.critDays = critDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Probe()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        type = try c.decodeIfPresent(Kind.self, forKey: .type) ?? d.type
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? d.target
        expectStatus = try c.decodeIfPresent(ClosedRange<Int>.self, forKey: .expectStatus)
        warnDays = try c.decodeIfPresent(Int.self, forKey: .warnDays) ?? d.warnDays
        critDays = try c.decodeIfPresent(Int.self, forKey: .critDays) ?? d.critDays
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? target.trimmingCharacters(in: .whitespaces) : trimmed
    }

    // MARK: Pure rules

    public func statusIsUp(_ status: Int) -> Bool { (expectStatus ?? 200...399).contains(status) }

    public func tlsState(daysLeft: Int) -> CheckState {
        daysLeft < critDays ? .crit : daysLeft < warnDays ? .warn : .ok
    }

    /// "host:port" with an optional scheme or IPv6 brackets. `defaultPort` fills in a bare host.
    public static func hostAndPort(_ value: String, defaultPort: UInt16?) -> (host: String, port: UInt16)? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("://"), let url = URL(string: text), let host = url.host {
            guard let port = url.port.map(UInt16.init) ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : defaultPort) else { return nil }
            return (host, port)
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) { return (host, port) }
            return defaultPort.map { (host, $0) }
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, !parts[0].isEmpty, let port = UInt16(parts[1]) { return (String(parts[0]), port) }
        guard !text.isEmpty, parts.count == 1, let port = defaultPort else { return nil }
        return (text, port)
    }

    func check(_ state: CheckState, _ display: String, value: Double? = nil, message: String? = nil) -> Check {
        Check(id: id.uuidString, name: displayName, value: value, display: display, state: state, message: message)
    }
}

/// `/api/v1/targets`: how many scrape targets answer.
public enum TargetHealth {
    public static let checkID = "targets"

    /// Warn when any target is down, crit when more than 10% are. Targets not scraped yet count as up.
    public static func check(from data: Data) throws -> Check {
        struct Response: Decodable {
            struct DataBlock: Decodable { let activeTargets: [Target] }
            struct Target: Decodable { let health: String }
            let data: DataBlock
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw FetchError.unexpectedResponse }
        let total = response.data.activeTargets.count
        let down = response.data.activeTargets.filter { $0.health == "down" }.count
        let state: CheckState = down == 0 ? .ok : Double(down) > Double(total) * 0.1 ? .crit : .warn
        return Check(id: checkID, name: "Targets up", value: Double(total - down), display: "\(total - down)/\(total)", state: state,
                     message: down == 0 ? nil : "\(down) down")
    }

    public static func check(error: String) -> Check {
        Check(id: checkID, name: "Targets up", display: "error", state: .unknown, message: error)
    }
}

/// Runs probes. Network failures become crit checks with a short reason; nothing throws.
public enum ProbeRunner {
    public static func run(_ probes: [Probe], skipTLSVerify: Bool) async -> [Check] {
        let usable = probes.filter { !$0.target.trimmingCharacters(in: .whitespaces).isEmpty }
        return await withTaskGroup(of: (Int, Check).self) { group in
            for (index, probe) in usable.enumerated() {
                group.addTask { (index, await run(probe, skipTLSVerify: skipTLSVerify)) }
            }
            var results: [(Int, Check)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public static func run(_ probe: Probe, skipTLSVerify: Bool) async -> Check {
        switch probe.type {
        case .http: await http(probe, skipTLSVerify: skipTLSVerify)
        case .tcp: await tcp(probe)
        case .tls: await tls(probe, skipTLSVerify: skipTLSVerify)
        case .dns: await dns(probe)
        }
    }

    static func http(_ probe: Probe, skipTLSVerify: Bool) async -> Check {
        let target = probe.target.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: target), url.scheme == "http" || url.scheme == "https", url.host != nil else {
            return probe.check(.unknown, "invalid URL", message: "Use a full URL, e.g. https://example.com/health")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Velto", forHTTPHeaderField: "User-Agent")
        let source = Source(kind: .probes, skipTLSVerify: skipTLSVerify)
        let start = Date()
        do {
            let (_, status) = try await Fetcher.exchange(request, for: source)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return probe.check(probe.statusIsUp(status) ? .ok : .crit, "\(status) · \(ms) ms", value: Double(status))
        } catch {
            return probe.check(.crit, "down", message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    static func tcp(_ probe: Probe, timeout: TimeInterval = 5) async -> Check {
        guard let (host, port) = Probe.hostAndPort(probe.target, defaultPort: nil) else {
            return probe.check(.unknown, "invalid target", message: "Use host:port, e.g. db.example.com:5432")
        }
        let start = Date()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let open: Bool = await withCheckedContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: true) }
                // NWConnection waits for a path instead of failing on a refused port: treat that as closed.
                case .failed, .waiting, .cancelled: if once.claim() { continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
        connection.cancel()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return open ? probe.check(.ok, "open · \(ms) ms", value: Double(ms)) : probe.check(.crit, "closed", message: "No connection to \(host):\(port)")
    }

    static func tls(_ probe: Probe, skipTLSVerify: Bool, now: Date = Date()) async -> Check {
        guard let (host, port) = Probe.hostAndPort(probe.target, defaultPort: 443),
              let url = URL(string: "https://\(host.contains(":") ? "[\(host)]" : host):\(port)/") else {
            return probe.check(.unknown, "invalid target", message: "Use host:port, e.g. example.com:443")
        }
        let capture = TrustCapture()
        let session = URLSession(configuration: .ephemeral, delegate: capture, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request) // cancelled on purpose once the certificate is in hand
        guard let trust = capture.trust else { return probe.check(.crit, "no TLS", message: "No TLS handshake with \(host):\(port)") }
        if !skipTLSVerify, !SecTrustEvaluateWithError(trust, nil) {
            return probe.check(.crit, "untrusted", message: "The certificate chain is not trusted")
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let expiry = notAfter(leaf) else {
            return probe.check(.unknown, "unreadable", message: "Could not read the certificate's expiry date")
        }
        let days = Int((expiry.timeIntervalSince(now) / 86400).rounded(.down))
        return probe.check(probe.tlsState(daysLeft: days), days < 0 ? "expired" : days == 1 ? "1 day" : "\(days) days", value: Double(days))
    }

    static func notAfter(_ certificate: SecCertificate) -> Date? {
        let key = kSecOIDX509V1ValidityNotAfter
        guard let values = SecCertificateCopyValues(certificate, [key] as CFArray, nil) as? [CFString: Any],
              let entry = values[key] as? [CFString: Any], let number = entry[kSecPropertyKeyValue] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }

    static func dns(_ probe: Probe, timeout: TimeInterval = 5) async -> Check {
        let host = NetworkCondition.hostName(probe.target)
        guard !host.isEmpty else { return probe.check(.unknown, "invalid target") }
        let address: String? = await withCheckedContinuation { continuation in
            let once = Once()
            DispatchQueue.global(qos: .utility).async {
                var result: UnsafeMutablePointer<addrinfo>?
                var text: String?
                if getaddrinfo(host, nil, nil, &result) == 0, let first = result {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        text = String(cString: buffer)
                    }
                    freeaddrinfo(result)
                }
                if once.claim() { continuation.resume(returning: text) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
        return address.map { probe.check(.ok, $0) } ?? probe.check(.crit, "no answer", message: "\(host) did not resolve")
    }
}

/// Keeps the server's trust from the TLS handshake, then cancels: only the certificate is needed.
private final class TrustCapture: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: SecTrust?
    var trust: SecTrust? { lock.lock(); defer { lock.unlock() }; return captured }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        keep(trust)
        return (.cancelAuthenticationChallenge, nil)
    }

    private func keep(_ trust: SecTrust) { lock.lock(); captured = trust; lock.unlock() }
}

/// Lets exactly one of two racing callbacks resume a continuation.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
