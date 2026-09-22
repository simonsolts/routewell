import Foundation

/// The Names pop-up above the client table.
public enum ClientNameMode: String, CaseIterable, Sendable, Codable {
    case automatic, hostname, displayName
}

public enum ClientNameSource: Sendable, Equatable {
    case user, router, hostname, adGuard
    /// No source has a name. The app shows "Unknown device", never a MAC or IP.
    case none
}

public struct ResolvedClientName: Sendable, Equatable {
    public var text: String?
    public var source: ClientNameSource

    public init(_ text: String?, source: ClientNameSource) {
        self.text = text
        self.source = text == nil ? .none : source
    }
}

/// Automatic naming order (architecture 03): user name, router client name,
/// DHCP hostname, AdGuard client name, then none.
public enum ClientNaming {
    public static func automatic(client: Client?, record: DeviceRecord?) -> ResolvedClientName {
        if let name = record?.userName, !name.isEmpty { return ResolvedClientName(name, source: .user) }
        if let name = client?.routerName ?? (client == nil ? record?.lastRouterName : nil) {
            return ResolvedClientName(name, source: .router)
        }
        if let name = client?.hostname ?? (client == nil ? record?.lastHostname : nil) {
            return ResolvedClientName(name, source: .hostname)
        }
        if let name = client?.adGuardName { return ResolvedClientName(name, source: .adGuard) }
        return ResolvedClientName(nil, source: .none)
    }

    /// Hostname and Display name show only that source, with no fallback, so
    /// each mode means what it says.
    public static func name(_ mode: ClientNameMode, client: Client?, record: DeviceRecord?) -> ResolvedClientName {
        switch mode {
        case .automatic:
            return automatic(client: client, record: record)
        case .hostname:
            return ResolvedClientName(client?.hostname ?? (client == nil ? record?.lastHostname : nil), source: .hostname)
        case .displayName:
            let name = record?.userName.flatMap { $0.isEmpty ? nil : $0 }
            return ResolvedClientName(name, source: .user)
        }
    }
}

public enum ClientPresence: Int, Sendable, Equatable, Comparable {
    case online, offline
    /// Known on this Mac, but the router no longer lists it.
    case absent
    case unknown

    public static func < (lhs: ClientPresence, rhs: ClientPresence) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One table row: a router client, a remembered device the router no longer
/// lists, or both joined by MAC.
public struct ClientListEntry: Sendable, Equatable, Identifiable {
    public var mac: MACAddress
    public var client: Client?
    public var record: DeviceRecord?

    public var id: MACAddress { mac }
    public var isFavourite: Bool { record?.favourite == true }

    public var presence: ClientPresence {
        guard let client else { return .absent }
        switch client.online {
        case .value(true): return .online
        case .value(false): return .offline
        case .unavailable, .unknown: return .unknown
        }
    }

    public var queries: Observed<Int> { client?.dnsQueries ?? .unknown }
    public var blocked: Observed<Int> { client?.dnsBlocked ?? .unknown }
    public var blockRate: Observed<Double> { ClientListing.blockRate(queries: queries, blocked: blocked) }

    public init(mac: MACAddress, client: Client?, record: DeviceRecord?) {
        self.mac = mac
        self.client = client
        self.record = record
    }
}

public struct ClientFilter: Sendable, Equatable {
    public var onlineOnly = false
    public var favouritesOnly = false
    public var hideUnknown = false
    public var search = ""
    public init(onlineOnly: Bool = false, favouritesOnly: Bool = false, hideUnknown: Bool = false, search: String = "") {
        self.onlineOnly = onlineOnly
        self.favouritesOnly = favouritesOnly
        self.hideUnknown = hideUnknown
        self.search = search
    }
}

public enum ClientSortColumn: String, Sendable, CaseIterable {
    case name, ip, connection, signal, queries, blocked, rate, status, favourite
}

public struct ClientSort: Sendable, Equatable {
    public var column: ClientSortColumn
    public var ascending: Bool
    /// The v2 default: Blocked, descending.
    public static let standard = ClientSort(column: .blocked, ascending: false)
    public init(column: ClientSortColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

public enum ClientListing {
    /// Router clients first in router order, then remembered devices the
    /// router no longer lists.
    public static func entries(clients: [Client], records: [MACAddress: DeviceRecord]) -> [ClientListEntry] {
        var result = clients.map { ClientListEntry(mac: $0.mac, client: $0, record: records[$0.mac]) }
        let listed = Set(clients.map(\.mac))
        result += records.values.filter { !listed.contains($0.mac) }.sorted { $0.mac < $1.mac }
            .map { ClientListEntry(mac: $0.mac, client: nil, record: $0) }
        return result
    }

    /// `.unavailable` when there were no queries (the table shows a dash),
    /// `.unknown` when either count is unknown.
    public static func blockRate(queries: Observed<Int>, blocked: Observed<Int>) -> Observed<Double> {
        guard case .value(let total) = queries, case .value(let count) = blocked else { return .unknown }
        guard total > 0 else { return .unavailable }
        return .value(Double(count) / Double(total))
    }

    public static func matches(_ entry: ClientListEntry, filter: ClientFilter, nameMode: ClientNameMode) -> Bool {
        if filter.onlineOnly, entry.presence != .online { return false }
        if filter.favouritesOnly, !entry.isFavourite { return false }
        if filter.hideUnknown, ClientNaming.automatic(client: entry.client, record: entry.record).source == .none { return false }
        let query = filter.search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let client = entry.client
        let texts = [
            ClientNaming.name(nameMode, client: client, record: entry.record).text,
            client?.hostname, client?.routerName, client?.adGuardName, entry.record?.userName,
            client?.ip ?? entry.record?.lastIP, entry.mac.colonSeparated
        ].compactMap { $0 }
        if texts.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        let hex = query.uppercased().filter(\.isHexDigit)
        return hex.count >= 4 && hex.count == query.filter { $0 != ":" && $0 != "-" }.count
            && entry.mac.normalized.contains(hex)
    }

    public static func apply(filter: ClientFilter, sort: ClientSort, nameMode: ClientNameMode,
                             to entries: [ClientListEntry]) -> [ClientListEntry] {
        entries.filter { matches($0, filter: filter, nameMode: nameMode) }
            .sorted { ordered($0, $1, sort: sort, nameMode: nameMode) }
    }

    /// Unknown values sort last in both directions; ties fall back to name,
    /// then MAC, so the order is stable.
    static func ordered(_ lhs: ClientListEntry, _ rhs: ClientListEntry, sort: ClientSort, nameMode: ClientNameMode) -> Bool {
        let primary: ComparisonResult? = switch sort.column {
        case .name: compareText(name(lhs, nameMode), name(rhs, nameMode), ascending: sort.ascending)
        case .ip: compare(lhs.client?.ip.flatMap(IPAddressText.ipv4Key), rhs.client?.ip.flatMap(IPAddressText.ipv4Key), ascending: sort.ascending)
            ?? compareText(lhs.client?.ip, rhs.client?.ip, ascending: sort.ascending)
        case .connection: compareText(connectionKey(lhs), connectionKey(rhs), ascending: sort.ascending)
        case .signal: compare(value(lhs.client?.signal), value(rhs.client?.signal), ascending: sort.ascending)
        case .queries: compare(value(lhs.queries), value(rhs.queries), ascending: sort.ascending)
        case .blocked: compare(value(lhs.blocked), value(rhs.blocked), ascending: sort.ascending)
        case .rate: compare(rateKey(lhs.blockRate), rateKey(rhs.blockRate), ascending: sort.ascending)
        case .status: compare(lhs.presence.rawValue, rhs.presence.rawValue, ascending: sort.ascending)
        case .favourite: compare(lhs.isFavourite ? 1 : 0, rhs.isFavourite ? 1 : 0, ascending: sort.ascending)
        }
        if let primary, primary != .orderedSame { return primary == .orderedAscending }
        if let byName = compareText(name(lhs, nameMode), name(rhs, nameMode), ascending: true), byName != .orderedSame {
            return byName == .orderedAscending
        }
        return lhs.mac < rhs.mac
    }

    private static func name(_ entry: ClientListEntry, _ mode: ClientNameMode) -> String? {
        ClientNaming.name(mode, client: entry.client, record: entry.record).text
    }

    private static func value(_ observed: Observed<Int>?) -> Int? {
        if case .value(let value) = observed { return value }
        return nil
    }

    /// No-query rows (a dash) sort after real rates; unknown sorts last.
    private static func rateKey(_ rate: Observed<Double>) -> Double? {
        switch rate {
        case .value(let value): value
        case .unavailable: -1
        case .unknown: nil
        }
    }

    private static func connectionKey(_ entry: ClientListEntry) -> String? {
        guard let connection = entry.client?.connection else { return nil }
        let medium: String? = switch connection.medium {
        case .value(let medium): medium.rawValue
        case .unavailable, .unknown: nil
        }
        let parts = [medium, connection.band, connection.ssid, connection.interface].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// `nil` result means "both unknown": the caller falls through to the tie-break.
    private static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?, ascending: Bool) -> ComparisonResult? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (let lhs?, let rhs?):
            if lhs == rhs { return .orderedSame }
            return (lhs < rhs) == ascending ? .orderedAscending : .orderedDescending
        }
    }

    private static func compareText(_ lhs: String?, _ rhs: String?, ascending: Bool) -> ComparisonResult? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (let lhs?, let rhs?):
            let result = lhs.localizedStandardCompare(rhs)
            guard result != .orderedSame, !ascending else { return result }
            return result == .orderedAscending ? .orderedDescending : .orderedAscending
        }
    }
}
