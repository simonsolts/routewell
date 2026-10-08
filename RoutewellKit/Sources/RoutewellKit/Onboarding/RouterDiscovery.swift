import Foundation

/// What one unauthenticated `challenge` for `root` found at an address.
/// Discovery sends nothing else, and nothing secret.
public enum ChallengeProbeOutcome: Sendable, Equatable {
    /// A GL.iNet router answered with `salt` and `nonce`. `fingerprint` is
    /// the SHA-256 of the leaf certificate it presented (nil over plain HTTP),
    /// kept for the Certificate step.
    case glinet(fingerprint: CertificateFingerprint?)
    /// Something answered, but not with a GL.iNet challenge.
    case notGLiNet
    /// No answer: refused, unreachable, or timed out. Worth trying again
    /// while macOS shows its Local Network prompt.
    case noAnswer
}

/// Sends one unauthenticated `challenge`. Accepts any certificate, because
/// nothing secret is sent and the person checks the fingerprint next.
public protocol RouterChallengeProbing: Sendable {
    func probe(_ endpoint: RouterEndpoint) async -> ChallengeProbeOutcome
}

/// The router of the Mac's primary IPv4 service, if any.
public protocol GatewayLocating: Sendable {
    func gatewayAddress() async -> String?
}

/// Resolves a host name to IPv4 literals.
public protocol HostResolving: Sendable {
    func ipv4Addresses(for host: String) async -> [String]
}

/// Says whether macOS refused Local Network access for connections to `host`.
public protocol LocalNetworkAccessChecking: Sendable {
    func isDenied(host: String) async -> Bool
}

/// Where a candidate address came from.
public enum DiscoverySource: String, Sendable, Equatable {
    case gateway, console, fallback, manual
}

/// A GL.iNet router that answered `challenge`, ready for the Certificate step.
public struct DiscoveredRouter: Sendable, Equatable {
    public var endpoint: RouterEndpoint
    public var source: DiscoverySource
    public var fingerprint: CertificateFingerprint?

    public init(endpoint: RouterEndpoint, source: DiscoverySource, fingerprint: CertificateFingerprint?) {
        self.endpoint = endpoint
        self.source = source
        self.fingerprint = fingerprint
    }
}

public enum DiscoveryResult: Sendable, Equatable {
    case found(DiscoveredRouter)
    case notFound
    case localNetworkDenied
}

/// The result of "Connect" on the Manual step.
public enum ManualProbeResult: Sendable, Equatable {
    case found(DiscoveredRouter)
    case notGLiNet
    case noAnswer
    case localNetworkDenied
}

/// Finds the router without a password (onboarding step 1).
///
/// Row 1 tries the gateway and `console.gl-inet.com` at the same time; row 2
/// tries 192.168.8.1. Each attempt has its own deadline, and an address that
/// gives no answer is tried again until its row's time is up, because the
/// first attempt makes macOS show the Local Network prompt. The whole search
/// stays within `total`.
public struct RouterDiscovery: Sendable {
    public struct Timing: Sendable, Equatable {
        public var attempt: Duration
        public var firstRow: Duration
        public var total: Duration
        public var retryPause: Duration
        /// How long a console answer waits for the gateway, which wins a tie.
        public var gatewayGrace: Duration

        public init(attempt: Duration = .milliseconds(1500), firstRow: Duration = .seconds(3), total: Duration = .seconds(6),
                    retryPause: Duration = .milliseconds(250), gatewayGrace: Duration = .milliseconds(1500)) {
            self.attempt = attempt
            self.firstRow = firstRow
            self.total = total
            self.retryPause = retryPause
            self.gatewayGrace = gatewayGrace
        }
    }

    public static let consoleHost = "console.gl-inet.com"
    public static let fallbackHost = "192.168.8.1"

    private let prober: any RouterChallengeProbing
    private let gateway: any GatewayLocating
    private let resolver: any HostResolving
    private let localNetwork: any LocalNetworkAccessChecking
    private let timing: Timing

    public init(prober: any RouterChallengeProbing, gateway: any GatewayLocating, resolver: any HostResolving,
                localNetwork: any LocalNetworkAccessChecking, timing: Timing = Timing()) {
        self.prober = prober
        self.gateway = gateway
        self.resolver = resolver
        self.localNetwork = localNetwork
        self.timing = timing
    }

    /// `onFallback` runs once when row 1 has failed and row 2 starts.
    public func run(onFallback: @escaping @Sendable () async -> Void = {}) async -> DiscoveryResult {
        let clock = ContinuousClock()
        let start = clock.now
        let firstRowEnd = start.advanced(by: min(timing.firstRow, timing.total))
        let end = start.advanced(by: timing.total)

        let gatewayHost = await gateway.gatewayAddress().flatMap(Self.ipv4Literal)
        if let found = await firstRow(gatewayHost: gatewayHost, until: firstRowEnd) { return .found(found) }
        guard !Task.isCancelled else { return .notFound }

        await onFallback()
        if let fallback = Self.endpoint(Self.fallbackHost),
           case .found(let fingerprint) = await attempt(fallback, until: end) {
            return .found(DiscoveredRouter(endpoint: fallback, source: .fallback, fingerprint: fingerprint))
        }
        guard !Task.isCancelled else { return .notFound }
        let checked = gatewayHost ?? Self.fallbackHost
        return await localNetwork.isDenied(host: checked) ? .localNetworkDenied : .notFound
    }

    /// One attempt at an address the person typed. Plain HTTP is not offered.
    public func probe(manual endpoint: RouterEndpoint) async -> ManualProbeResult {
        let deadline = ContinuousClock.now.advanced(by: timing.attempt * 2)
        switch await attempt(endpoint, until: deadline) {
        case .found(let fingerprint): return .found(DiscoveredRouter(endpoint: endpoint, source: .manual, fingerprint: fingerprint))
        case .notGLiNet: return .notGLiNet
        case .noAnswer: return await localNetwork.isDenied(host: endpoint.host) ? .localNetworkDenied : .noAnswer
        }
    }

    // MARK: Row 1

    private enum RowAnswer: Sendable {
        case gateway(AttemptResult)
        case console(String, AttemptResult)
        /// The console answered and the gateway had `gatewayGrace` to answer too.
        case graceOver
    }

    /// The gateway and the console name run together. A gateway answer wins
    /// at once; a console answer waits `gatewayGrace` for the gateway.
    private func firstRow(gatewayHost: String?, until deadline: ContinuousClock.Instant) async -> DiscoveredRouter? {
        await withTaskGroup(of: RowAnswer.self) { group in
            if let gatewayHost, let endpoint = Self.endpoint(gatewayHost) {
                group.addTask { .gateway(await attempt(endpoint, until: deadline)) }
            }
            group.addTask {
                // Only a private address counts: off the router's own network the
                // name resolves to GL.iNet's public site.
                let addresses = await resolver.ipv4Addresses(for: Self.consoleHost)
                    .filter { Self.isPrivateIPv4($0) && $0 != gatewayHost }
                for address in addresses {
                    guard let endpoint = Self.endpoint(address) else { continue }
                    let result = await attempt(endpoint, until: deadline)
                    if case .found = result { return .console(address, result) }
                }
                return .console("", .noAnswer)
            }

            var gatewayDone = gatewayHost == nil
            var consoleFound: DiscoveredRouter?
            while let answer = await group.next() {
                switch answer {
                case .gateway(.found(let fingerprint)):
                    group.cancelAll()
                    guard let gatewayHost, let endpoint = Self.endpoint(gatewayHost) else { return nil }
                    return DiscoveredRouter(endpoint: endpoint, source: .gateway, fingerprint: fingerprint)
                case .gateway:
                    gatewayDone = true
                case .console(let address, .found(let fingerprint)):
                    if let endpoint = Self.endpoint(address) {
                        consoleFound = DiscoveredRouter(endpoint: endpoint, source: .console, fingerprint: fingerprint)
                        let grace = timing.gatewayGrace
                        group.addTask {
                            try? await Task.sleep(for: grace)
                            return .graceOver
                        }
                    }
                case .console:
                    break
                case .graceOver:
                    gatewayDone = true
                }
                if gatewayDone, let consoleFound {
                    group.cancelAll()
                    return consoleFound
                }
            }
            return consoleFound
        }
    }

    // MARK: One address

    private enum AttemptResult: Sendable {
        case found(CertificateFingerprint?)
        case notGLiNet
        case noAnswer
    }

    /// Tries `endpoint` until it answers or `deadline` passes. Each attempt
    /// gets at most `timing.attempt`.
    private func attempt(_ endpoint: RouterEndpoint, until deadline: ContinuousClock.Instant) async -> AttemptResult {
        while !Task.isCancelled {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return .noAnswer }
            let outcome = await Self.withDeadline(min(timing.attempt, remaining)) { await prober.probe(endpoint) } ?? .noAnswer
            switch outcome {
            case .glinet(let fingerprint): return .found(fingerprint)
            case .notGLiNet: return .notGLiNet
            case .noAnswer:
                let left = ContinuousClock.now.duration(to: deadline)
                guard left > .zero else { return .noAnswer }
                try? await Task.sleep(for: min(timing.retryPause, left))
            }
        }
        return .noAnswer
    }

    /// Runs `operation` and cancels it after `limit`; `nil` on timeout.
    static func withDeadline<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Addresses

    static func endpoint(_ host: String) -> RouterEndpoint? {
        try? RouterEndpoint(scheme: .https, host: host, port: 443)
    }

    /// A dotted IPv4 literal, or `nil`.
    static func ipv4Literal(_ text: String) -> String? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && UInt8($0) != nil }) else { return nil }
        return text
    }

    /// RFC 1918 (10/8, 172.16/12, 192.168/16) or 100.64/10 (carrier NAT, used by some travel routers).
    static func isPrivateIPv4(_ text: String) -> Bool {
        guard ipv4Literal(text) != nil else { return false }
        let octets = text.split(separator: ".").compactMap { UInt8($0) }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (100, 64...127): return true
        default: return false
        }
    }
}
