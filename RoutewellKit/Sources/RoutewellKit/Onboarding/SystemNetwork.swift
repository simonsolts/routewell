import Foundation
import Network
import SystemConfiguration

/// Reads `State:/Network/Global/IPv4` → `Router`: the gateway of the primary
/// IPv4 service.
public struct SystemGatewayLocator: GatewayLocating {
    public init() {}

    public func gatewayAddress() async -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Routewell" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return value["Router"] as? String
    }
}

/// `getaddrinfo` for IPv4 only, off the caller's thread.
public struct SystemHostResolver: HostResolving {
    public init() {}

    public func ipv4Addresses(for host: String) async -> [String] {
        await Task.detached(priority: .userInitiated) { Self.resolve(host) }.value
    }

    private static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr, entry.pointee.ai_family == AF_INET {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4 in
                    var inAddr = ipv4.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &inAddr, &buffer, socklen_t(INET_ADDRSTRLEN))
                }
                let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !text.isEmpty, !addresses.contains(text) { addresses.append(text) }
            }
            cursor = entry.pointee.ai_next
        }
        return addresses
    }
}

/// Opens a TCP connection to `host:443` and reports a denial when the path
/// says `localNetworkDenied`. Sends no data; gives up after 1.5 s.
public struct SystemLocalNetworkCheck: LocalNetworkAccessChecking {
    public init() {}

    public func isDenied(host: String) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tcp)
        let answer = DeniedAnswer()
        let denied = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            answer.set(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .waiting, .failed:
                    answer.finish(connection.currentPath?.unsatisfiedReason == .localNetworkDenied)
                case .ready, .cancelled:
                    answer.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { answer.finish(false) }
        }
        connection.cancel()
        return denied
    }
}

/// Resumes a continuation once.
private final class DeniedAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func set(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func finish(_ value: Bool) {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
