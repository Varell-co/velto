import Foundation
import Network
import VeltoCore

/// Decides whether a source's network condition holds, and says when the network changes so paused
/// sources resume without waiting for the timer.
@MainActor
final class NetworkGate {
    var onChange: (() -> Void)?
    private let monitor = NWPathMonitor()

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.onChange?() }
        }
        monitor.start(queue: DispatchQueue(label: "co.varell.velto.network"))
    }

    nonisolated static func satisfied(_ condition: NetworkCondition) async -> Bool {
        switch condition {
        case .vpn: vpnIsUp()
        case .resolves(let host): await resolves(NetworkCondition.hostName(host))
        }
    }

    /// Any up utun/ppp/ipsec interface with an IPv4 or a non-link-local IPv6 address. macOS keeps a few
    /// utun interfaces around for its own services, but those carry only link-local addresses.
    nonisolated static func vpnIsUp() -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard ["utun", "ppp", "ipsec"].contains(where: name.hasPrefix), entry.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                return true
            case AF_INET6:
                let linkLocal = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { six in
                    six.pointee.sin6_addr.__u6_addr.__u6_addr8.0 == 0xfe && six.pointee.sin6_addr.__u6_addr.__u6_addr8.1 & 0xc0 == 0x80
                }
                if !linkLocal { return true }
            default:
                continue
            }
        }
        return false
    }

    /// getaddrinfo can block well past any sane wait when DNS is unreachable, so it runs on its own
    /// thread and loses to a 3 s timer.
    nonisolated static func resolves(_ host: String, timeout: TimeInterval = 3) async -> Bool {
        guard !host.isEmpty else { return false }
        return await withCheckedContinuation { continuation in
            let once = Once()
            DispatchQueue.global(qos: .utility).async {
                var result: UnsafeMutablePointer<addrinfo>?
                let ok = getaddrinfo(host, nil, nil, &result) == 0 && result != nil
                if let result { freeaddrinfo(result) }
                if once.claim() { continuation.resume(returning: ok) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }
}

/// Lets exactly one of two racing callbacks resume a continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
