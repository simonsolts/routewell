import Foundation

/// Text fields from router and AdGuard payloads. Blank strings and the
/// placeholders GL.iNet and dnsmasq use for "no name" are not names.
enum ClientText {
    static func meaningful(_ value: JSONValue?) -> String? {
        guard let raw = value?.string else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "*", trimmed.lowercased() != "unknown" else { return nil }
        return trimmed
    }
}

/// IPv4 or IPv6 literal check, shared by parsers and the fixture recorder.
enum IPAddressText {
    static func isValid(_ string: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return string.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    /// Numeric IPv4 order key; `nil` for anything else.
    static func ipv4Key(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var key: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            key = key << 8 | UInt32(octet)
        }
        return key
    }
}

/// One entry of RPC `clients get_list`, before the AdGuard join.
public struct RouterClientEntry: Sendable, Equatable {
    public var mac: MACAddress
    public var ip: String?
    public var routerName: String?
    public var hostname: String?
    public var online: Observed<Bool>
    public var interface: String?
    public var reportedVendor: String?
}

/// RPC `clients get_list` result: `clients[]` with `mac`, `ip`, `name`,
/// `online`, `iface` `[verified live]` on firmware 4.9.1; `alias` appears on
/// some entries `[verified live]`; `vendor` appears in the 2022 public client
/// only. No signal, SSID, or band field exists in the live shape.
public enum GLiNetClientListParser {
    public struct Parsed: Sendable, Equatable {
        public var entries: [RouterClientEntry]
        public var skippedEntries: Int
    }

    /// `nil` when the payload has no client array at all (a malformed reply).
    /// A `null` list reads as empty `[assumed]`.
    public static func parse(_ result: JSONValue) -> Parsed? {
        let list: [JSONValue]
        switch result["clients"] {
        case .array(let values): list = values
        case .null: list = []
        default: return nil
        }
        var entries: [RouterClientEntry] = []
        var seen: Set<MACAddress> = []
        var skipped = 0
        for item in list {
            guard let raw = item["mac"]?.string, let mac = MACAddress(raw) else {
                skipped += 1
                continue
            }
            let online: Observed<Bool> = item["online"]?.bool.map(Observed.value) ?? .unknown
            let entry = RouterClientEntry(
                mac: mac,
                ip: ClientText.meaningful(item["ip"]),
                routerName: ClientText.meaningful(item["alias"]),
                hostname: ClientText.meaningful(item["name"]),
                online: online,
                interface: ClientText.meaningful(item["iface"]),
                reportedVendor: ClientText.meaningful(item["vendor"])
            )
            if seen.insert(mac).inserted {
                entries.append(entry)
            } else if let index = entries.firstIndex(where: { $0.mac == mac }), entry.online == .value(true) {
                // A MAC listed twice keeps its online entry.
                entries[index] = entry
            }
        }
        return Parsed(entries: entries, skippedEntries: skipped)
    }
}

/// AdGuard Home `GET control/clients`. `auto_clients[]` carry `name` and `ip`
/// `[verified live]`. `clients` (persistent clients) was `null` live; when
/// present each has `name` and `ids[]` of MACs, IPs, or ClientIDs `[assumed]`.
public enum AdGuardClientsParser {
    public struct Persistent: Sendable, Equatable {
        public var name: String
        public var macs: [MACAddress]
        public var ips: [String]
    }

    public struct Directory: Sendable, Equatable {
        public var persistent: [Persistent] = []
        /// Runtime clients keyed by IP, with a meaningful name.
        public var automaticNames: [String: String] = [:]
    }

    /// `nil` when neither list is readable.
    public static func parse(_ json: JSONValue) -> Directory? {
        let persistentList = json["clients"]?.array
        let automaticList = json["auto_clients"]?.array
        guard persistentList != nil || automaticList != nil || json["clients"] == .null else { return nil }
        var directory = Directory()
        for item in persistentList ?? [] {
            guard let name = ClientText.meaningful(item["name"]) else { continue }
            let ids = item["ids"]?.array?.compactMap(\.string) ?? []
            directory.persistent.append(Persistent(
                name: name,
                macs: ids.compactMap(MACAddress.init),
                ips: ids.filter { IPAddressText.isValid($0) }
            ))
        }
        for item in automaticList ?? [] {
            guard let ip = ClientText.meaningful(item["ip"]), let name = ClientText.meaningful(item["name"]),
                  directory.automaticNames[ip] == nil else { continue }
            directory.automaticNames[ip] = name
        }
        return directory
    }
}

/// AdGuard Home `GET control/stats` `top_clients`: an array of one-key
/// objects, `{"<client>": <queries>}` `[verified live]`. The live keys were
/// hidden by the recorder because they look like IP addresses, so joining by
/// IP is `[assumed]` from that evidence. There is no per-client blocked count.
public enum AdGuardStatsParser {
    public static func topClientQueries(_ json: JSONValue) -> [String: Int]? {
        guard let list = json["top_clients"]?.array else { return nil }
        var result: [String: Int] = [:]
        for item in list {
            for (key, value) in item.object ?? [:] {
                guard let count = value.int, count >= 0 else { continue }
                result[key, default: 0] += count
            }
        }
        return result
    }
}
