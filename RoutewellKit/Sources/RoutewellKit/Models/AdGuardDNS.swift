import Foundation

/// `upstream_mode`. An empty string is the older name of load balancing.
public enum AdGuardUpstreamMode: String, CaseIterable, Sendable {
    case loadBalance = "load_balance"
    case parallel
    case fastestAddress = "fastest_addr"

    init?(wire: String) {
        if wire.isEmpty { self = .loadBalance } else { self.init(rawValue: wire) }
    }
}

/// `blocking_mode`.
public enum AdGuardBlockingMode: String, CaseIterable, Sendable {
    case `default`
    case nullIP = "null_ip"
    case refused
    case nxdomain
    case customIP = "custom_ip"
}

/// `GET control/dns_info`, shaped as in the AdGuard Home 0.107 schema.
/// The whole object is kept as read; the accessors read and change single
/// fields, so a field the app does not know stays as AdGuard Home sent it.
/// A missing or differently typed field reads as `nil` (Unknown).
public struct AdGuardDNSSettings: Sendable, Equatable, Codable {
    public private(set) var fields: [String: JSONValue]

    public init(fields: [String: JSONValue] = [:]) {
        self.fields = fields
    }

    /// `nil` when the reply is not an object.
    public static func parse(_ json: JSONValue) -> AdGuardDNSSettings? {
        json.object.map(AdGuardDNSSettings.init(fields:))
    }

    public var upstreams: [String]? {
        get { lines("upstream_dns") }
        set { setLines(newValue, "upstream_dns") }
    }

    public var fallback: [String]? {
        get { lines("fallback_dns") }
        set { setLines(newValue, "fallback_dns") }
    }

    public var bootstrap: [String]? {
        get { lines("bootstrap_dns") }
        set { setLines(newValue, "bootstrap_dns") }
    }

    public var upstreamMode: AdGuardUpstreamMode? {
        get { fields["upstream_mode"]?.string.flatMap(AdGuardUpstreamMode.init(wire:)) }
        set { fields["upstream_mode"] = newValue.map { .string($0.rawValue) } }
    }

    public var blockingMode: AdGuardBlockingMode? {
        get { fields["blocking_mode"]?.string.flatMap(AdGuardBlockingMode.init(rawValue:)) }
        set { fields["blocking_mode"] = newValue.map { .string($0.rawValue) } }
    }

    public var blockingIPv4: String? {
        get { fields["blocking_ipv4"]?.string }
        set { fields["blocking_ipv4"] = newValue.map(JSONValue.string) }
    }

    public var blockingIPv6: String? {
        get { fields["blocking_ipv6"]?.string }
        set { fields["blocking_ipv6"] = newValue.map(JSONValue.string) }
    }

    /// Seconds.
    public var blockedResponseTTL: Int? {
        get { fields["blocked_response_ttl"]?.int }
        set { setInt(newValue, "blocked_response_ttl") }
    }

    public var cacheEnabled: Bool? {
        get { fields["cache_enabled"]?.bool }
        set { fields["cache_enabled"] = newValue.map(JSONValue.bool) }
    }

    public var cacheOptimistic: Bool? {
        get { fields["cache_optimistic"]?.bool }
        set { fields["cache_optimistic"] = newValue.map(JSONValue.bool) }
    }

    /// Bytes.
    public var cacheSize: Int? {
        get { fields["cache_size"]?.int }
        set { setInt(newValue, "cache_size") }
    }

    /// Seconds; 0 does not override the answer's own TTL.
    public var cacheTTLMin: Int? {
        get { fields["cache_ttl_min"]?.int }
        set { setInt(newValue, "cache_ttl_min") }
    }

    public var cacheTTLMax: Int? {
        get { fields["cache_ttl_max"]?.int }
        set { setInt(newValue, "cache_ttl_max") }
    }

    public var dnssecEnabled: Bool? {
        get { fields["dnssec_enabled"]?.bool }
        set { fields["dnssec_enabled"] = newValue.map(JSONValue.bool) }
    }

    public var ednsClientSubnet: Bool? {
        get { fields["edns_cs_enabled"]?.bool }
        set { fields["edns_cs_enabled"] = newValue.map(JSONValue.bool) }
    }

    /// "Resolve IPv6 addresses": the opposite of `disable_ipv6`.
    public var resolvesIPv6: Bool? {
        get { fields["disable_ipv6"]?.bool.map { !$0 } }
        set { fields["disable_ipv6"] = newValue.map { .bool(!$0) } }
    }

    /// Requests per second per client; 0 is off.
    public var rateLimit: Int? {
        get { fields["ratelimit"]?.int }
        set { setInt(newValue, "ratelimit") }
    }

    /// The fields that differ from `loaded`: the body of `dns_config`.
    public func changes(from loaded: AdGuardDNSSettings) -> [String: JSONValue] {
        fields.filter { key, value in !Self.same(key, value, loaded.fields[key]) }
    }

    /// True when every field in `changes` already has that value here.
    public func contains(_ changes: [String: JSONValue]) -> Bool {
        changes.allSatisfy { key, value in Self.same(key, value, fields[key]) }
    }

    /// These values with `changes` on top.
    public func applying(_ changes: [String: JSONValue]) -> AdGuardDNSSettings {
        AdGuardDNSSettings(fields: fields.merging(changes) { $1 })
    }

    /// Why Apply cannot send these settings, or `nil`.
    public var problem: String? {
        if let upstreams, !upstreams.contains(where: { UpstreamLine($0).address != nil }) {
            return "Add at least one upstream server."
        }
        if blockingMode == .customIP {
            let v4 = (blockingIPv4 ?? "").trimmingCharacters(in: .whitespaces)
            let v6 = (blockingIPv6 ?? "").trimmingCharacters(in: .whitespaces)
            if v4.isEmpty && v6.isEmpty { return "Enter a custom IPv4 or IPv6 address." }
            if !v4.isEmpty && !Self.isIPv4(v4) { return "The custom IPv4 address is not valid." }
            if !v6.isEmpty && !Self.isIPv6(v6) { return "The custom IPv6 address is not valid." }
        }
        if let min = cacheTTLMin, let max = cacheTTLMax, max > 0, min > max {
            return "The cache minimum is longer than the maximum."
        }
        return nil
    }

    public static func isIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }

    public static func isIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }

    /// AdGuard Home may report the older empty `upstream_mode` for load
    /// balancing.
    private static func same(_ key: String, _ lhs: JSONValue?, _ rhs: JSONValue?) -> Bool {
        if key == "upstream_mode" {
            return lhs?.string.flatMap(AdGuardUpstreamMode.init(wire:)) == rhs?.string.flatMap(AdGuardUpstreamMode.init(wire:))
                && (lhs?.string != nil) == (rhs?.string != nil)
        }
        return lhs == rhs
    }

    /// `null` is an empty list.
    private func lines(_ key: String) -> [String]? {
        switch fields[key] {
        case .array(let values)?: values.compactMap(\.string)
        case .null?: []
        default: nil
        }
    }

    private mutating func setLines(_ value: [String]?, _ key: String) {
        fields[key] = value.map { .array($0.map(JSONValue.string)) }
    }

    private mutating func setInt(_ value: Int?, _ key: String) {
        fields[key] = value.map { .number(Double($0)) }
    }
}

/// One line of `upstream_dns`: a server, a `#` comment, or a line for some
/// domains only (`[/example.com/]…`), which is kept and shown as text.
public struct UpstreamLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case server, comment, domainSpecific }

    public let text: String

    public init(_ text: String) { self.text = text }

    public var kind: Kind {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return .comment }
        if trimmed.hasPrefix("[/") { return .domainSpecific }
        return .server
    }

    /// The server address, for server lines only.
    public var address: String? {
        kind == .server ? text.trimmingCharacters(in: .whitespaces) : nil
    }
}

/// The protocol badge, from the address scheme.
public enum UpstreamProtocol: String, Sendable {
    case plain = "Plain"
    case doh = "DoH"
    case dot = "DoT"
    case doq = "DoQ"
    case dnsCrypt = "DNSCrypt"
    case other = "Other"

    public init(address: String) {
        switch UpstreamAddress.scheme(address) {
        case nil, "udp", "tcp": self = .plain
        case "https", "h3": self = .doh
        case "tls": self = .dot
        case "quic": self = .doq
        case "sdns": self = .dnsCrypt
        default: self = .other
        }
    }
}

/// Upstream addresses as AdGuard Home's stats name them: the stats keys
/// carry the port (`https://host:443/dns-query`, `quic://host:853`),
/// the settings may not.
public enum UpstreamAddress {
    static func scheme(_ address: String) -> String? {
        guard let range = address.range(of: "://") else { return nil }
        return address[..<range.lowerBound].lowercased()
    }

    /// Scheme, lowercased host, port (the scheme's default when missing),
    /// and path. A plain address has scheme `udp`. `nil` when the address
    /// has no host.
    public static func key(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        let scheme = scheme(trimmed) ?? "udp"
        let text = Self.scheme(trimmed) == nil ? "udp://" + trimmed : trimmed
        if scheme == "sdns" { return text }
        guard let components = URLComponents(string: Self.bracketed(text)), var host = components.host, !host.isEmpty else { return nil }
        host = host.lowercased()
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        let port = components.port ?? defaultPort(scheme)
        return "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")\(components.path)"
    }

    static func defaultPort(_ scheme: String) -> Int? {
        switch scheme {
        case "udp", "tcp": 53
        case "https", "h3": 443
        case "tls", "quic": 853
        default: nil
        }
    }

    /// A bare IPv6 address after the scheme gets brackets, so it parses.
    private static func bracketed(_ text: String) -> String {
        guard let range = text.range(of: "://") else { return text }
        let rest = text[range.upperBound...]
        guard !rest.hasPrefix("["), AdGuardDNSSettings.isIPv6(String(rest)) else { return text }
        return text[..<range.upperBound] + "[\(rest)]"
    }
}

/// One upstream's share of answers and its average response time from the
/// stats. `nil` parts are Unknown.
public struct UpstreamUsage: Sendable, Equatable {
    /// 0...100.
    public var sharePercent: Double?
    public var averageMilliseconds: Double?

    public init(sharePercent: Double? = nil, averageMilliseconds: Double? = nil) {
        self.sharePercent = sharePercent
        self.averageMilliseconds = averageMilliseconds
    }

    /// Over half a second.
    public static let slowMilliseconds: Double = 500

    public var isSlow: Bool { (averageMilliseconds ?? 0) > Self.slowMilliseconds }
}

public extension AdGuardStats {
    /// Share and average time for `address`, joined by `UpstreamAddress.key`.
    /// Rows with the same key are added up.
    func usage(of address: String) -> UpstreamUsage {
        guard let key = UpstreamAddress.key(address) else { return UpstreamUsage() }
        let total = topUpstreams.reduce(0) { $0 + $1.count }
        let count = topUpstreams.filter { UpstreamAddress.key($0.name) == key }.reduce(0) { $0 + $1.count }
        var usage = UpstreamUsage()
        if total > 0, topUpstreams.contains(where: { UpstreamAddress.key($0.name) == key }) {
            usage.sharePercent = Double(count) / Double(total) * 100
        }
        if let seconds = topUpstreamTimes?.first(where: { UpstreamAddress.key($0.name) == key })?.seconds {
            usage.averageMilliseconds = seconds * 1000
        }
        return usage
    }
}

/// What Test Upstreams sends: the staged lists.
public struct UpstreamTestRequest: Sendable, Equatable {
    public var upstreams: [String]
    public var bootstrap: [String]
    public var fallback: [String]

    public init(upstreams: [String], bootstrap: [String], fallback: [String]) {
        self.upstreams = upstreams
        self.bootstrap = bootstrap
        self.fallback = fallback
    }
}

/// `POST control/test_upstream_dns` → one text per address: `OK` or an
/// error.
public struct UpstreamTestResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case ok
        case failed(String)
    }

    public var statuses: [String: Status]

    public init(statuses: [String: Status] = [:]) {
        self.statuses = statuses
    }

    public static func parse(_ json: JSONValue?) -> UpstreamTestResult {
        var result = UpstreamTestResult()
        for (address, value) in json?.object ?? [:] {
            guard let text = value.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            result.statuses[address] = trimmed == "OK" ? .ok : .failed(trimmed)
        }
        return result
    }

    /// The result for `address`: by exact text, else by key.
    public func status(of address: String) -> Status? {
        if let status = statuses[address] { return status }
        guard let key = UpstreamAddress.key(address) else { return nil }
        return statuses.first { UpstreamAddress.key($0.key) == key }?.value
    }
}
