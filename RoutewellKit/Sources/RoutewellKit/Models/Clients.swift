import Foundation

/// A client's identity: the MAC address normalized to uppercase hex with no
/// separators (architecture 03). IPs churn under DHCP and are never identity.
public struct MACAddress: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let normalized: String

    /// Accepts `aa:bb:cc:dd:ee:ff`, `AA-BB-CC-DD-EE-FF`, `aabb.ccdd.eeff`, or
    /// bare hex. Rejects anything else, and the all-zero address.
    public init?(_ raw: String) {
        let hex = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .uppercased()
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit), hex != "000000000000" else { return nil }
        normalized = hex
    }

    /// Lowercase, colon-separated: the verbatim technical form shown on screen.
    public var colonSeparated: String {
        stride(from: 0, to: 12, by: 2).map { offset -> String in
            let start = normalized.index(normalized.startIndex, offsetBy: offset)
            return normalized[start..<normalized.index(start, offsetBy: 2)].lowercased()
        }.joined(separator: ":")
    }

    /// The "locally administered" bit (0x02 of the first octet). Phones and
    /// laptops set it when they randomise their address per network.
    public var isLocallyAdministered: Bool {
        guard let first = UInt8(normalized.prefix(2), radix: 16) else { return false }
        return first & 0x02 != 0
    }

    public var description: String { colonSeparated }

    public static func < (lhs: MACAddress, rhs: MACAddress) -> Bool { lhs.normalized < rhs.normalized }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = MACAddress(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a MAC address")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(normalized)
    }
}

public enum ClientMedium: String, Sendable, Equatable, Codable {
    case wifi, wired
}

/// How a client is attached. Live firmware 4.9.1 reports only the router's
/// `iface` token; medium, band, and SSID stay unknown until a source for them
/// is verified. Values are technical and shown verbatim.
public struct ClientConnection: Sendable, Equatable {
    public var medium: Observed<ClientMedium>
    public var band: String?
    public var ssid: String?
    public var interface: String?

    public init(medium: Observed<ClientMedium> = .unknown, band: String? = nil, ssid: String? = nil, interface: String? = nil) {
        self.medium = medium
        self.band = band
        self.ssid = ssid
        self.interface = interface
    }
}

/// Where the Vendor row comes from. No OUI database is shipped or consulted.
public enum ClientVendor: Sendable, Equatable {
    /// The router reported a vendor string.
    case reported(String)
    /// No router vendor, and the MAC is locally administered.
    case randomised
    case unknown

    public static func resolve(reported: String?, mac: MACAddress) -> ClientVendor {
        if let reported { return .reported(reported) }
        return mac.isLocallyAdministered ? .randomised : .unknown
    }
}

/// One client as the router reports it, enriched with AdGuard Home data where
/// the join succeeded. Each name source stays separate; `ClientNaming` picks
/// the displayed one.
public struct Client: Sendable, Equatable, Identifiable {
    public var mac: MACAddress
    public var ip: String?
    /// The client name set in the router's own UI (`alias`) `[assumed]`.
    public var routerName: String?
    /// The name the client reported to the router (`name`, the DHCP hostname) `[assumed]`.
    public var hostname: String?
    public var adGuardName: String?
    public var online: Observed<Bool>
    public var connection: ClientConnection
    /// Received signal in dBm. No 4.9.1 source is known yet.
    public var signal: Observed<Int>
    /// AdGuard Home queries over its statistics window (24 h by default).
    public var dnsQueries: Observed<Int>
    /// AdGuard Home blocked queries. `control/stats` has no per-client count.
    public var dnsBlocked: Observed<Int>
    public var reportedVendor: String?

    public var id: MACAddress { mac }
    public var vendor: ClientVendor { .resolve(reported: reportedVendor, mac: mac) }

    public init(
        mac: MACAddress, ip: String? = nil, routerName: String? = nil, hostname: String? = nil,
        adGuardName: String? = nil, online: Observed<Bool> = .unknown, connection: ClientConnection = .init(),
        signal: Observed<Int> = .unknown, dnsQueries: Observed<Int> = .unknown, dnsBlocked: Observed<Int> = .unknown,
        reportedVendor: String? = nil
    ) {
        self.mac = mac
        self.ip = ip
        self.routerName = routerName
        self.hostname = hostname
        self.adGuardName = adGuardName
        self.online = online
        self.connection = connection
        self.signal = signal
        self.dnsQueries = dnsQueries
        self.dnsBlocked = dnsBlocked
        self.reportedVendor = reportedVendor
    }
}

/// The state of the AdGuard Home join for one inventory. A failed join
/// degrades names and DNS counts; it never fails the Clients area.
public enum ClientEnrichment: Sendable, Equatable {
    case joined
    /// One of the two AdGuard reads failed; the other was joined.
    case partial(RefreshFailureCategory)
    case failed(RefreshFailureCategory)
    case notConfigured
}

public struct ClientInventory: Sendable, Equatable {
    public var clients: [Client]
    public var enrichment: ClientEnrichment
    /// Router entries without a usable MAC address. They cannot be keyed, so
    /// they are left out rather than given an invented identity.
    public var skippedEntries: Int

    public init(clients: [Client], enrichment: ClientEnrichment, skippedEntries: Int = 0) {
        self.clients = clients
        self.enrichment = enrichment
        self.skippedEntries = skippedEntries
    }
}

/// One Clients read. The capability comes from the same response: success
/// proves support, only an exact method-not-found proves the opposite.
public struct ClientInventoryResult: Sendable {
    public var area: AreaRefreshResult<ClientInventory>
    public var capability: Capability

    public init(area: AreaRefreshResult<ClientInventory>, capability: Capability) {
        self.area = area
        self.capability = capability
    }
}
