import Foundation

public enum DeviceCategory: String, CaseIterable, Sendable, Codable {
    case phone, desktop, laptop, smartHome, tv, server, printer, watch, tablet
}

/// What Routewell keeps about one device on this Mac, keyed by normalized MAC
/// and persisted in `devices.json`. Router configuration is never changed.
public struct DeviceRecord: Sendable, Equatable, Codable, Identifiable {
    public let mac: MACAddress
    public var userName: String?
    public var favourite: Bool
    public var hiddenFromAlerts: Bool
    /// Notify when this device goes offline (chunk 13 wires the alert).
    public var monitored: Bool
    /// When Routewell first saw this MAC in a client list.
    public var firstSeen: Date
    /// The last refresh that saw this device online. `nil` until then.
    public var lastSeen: Date?
    public var notes: String
    public var category: DeviceCategory?
    /// The most recent router-reported values, kept so Known Clients can show
    /// a device after the router stops listing it.
    public var lastIP: String?
    public var lastHostname: String?
    public var lastRouterName: String?
    /// Found after the baseline and not yet opened from the review sheet.
    public var awaitingReview: Bool

    public var id: MACAddress { mac }

    public init(
        mac: MACAddress, userName: String? = nil, favourite: Bool = false, hiddenFromAlerts: Bool = false,
        monitored: Bool = false, firstSeen: Date, lastSeen: Date? = nil, notes: String = "",
        category: DeviceCategory? = nil, lastIP: String? = nil, lastHostname: String? = nil,
        lastRouterName: String? = nil, awaitingReview: Bool = false
    ) {
        self.mac = mac
        self.userName = userName
        self.favourite = favourite
        self.hiddenFromAlerts = hiddenFromAlerts
        self.monitored = monitored
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.notes = notes
        self.category = category
        self.lastIP = lastIP
        self.lastHostname = lastHostname
        self.lastRouterName = lastRouterName
        self.awaitingReview = awaitingReview
    }

    private enum CodingKeys: String, CodingKey {
        case mac, userName, favourite, hiddenFromAlerts, monitored, firstSeen, lastSeen, notes, category
        case lastIP, lastHostname, lastRouterName, awaitingReview
    }

    /// Only `mac` and `firstSeen` are required, so fields added later in
    /// schema version 1 still decode from older files. An unknown category
    /// reads as none rather than failing the whole file.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mac = try values.decode(MACAddress.self, forKey: .mac)
        firstSeen = try values.decode(Date.self, forKey: .firstSeen)
        userName = try values.decodeIfPresent(String.self, forKey: .userName)
        favourite = try values.decodeIfPresent(Bool.self, forKey: .favourite) ?? false
        hiddenFromAlerts = try values.decodeIfPresent(Bool.self, forKey: .hiddenFromAlerts) ?? false
        monitored = try values.decodeIfPresent(Bool.self, forKey: .monitored) ?? false
        lastSeen = try values.decodeIfPresent(Date.self, forKey: .lastSeen)
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        category = try values.decodeIfPresent(String.self, forKey: .category).flatMap(DeviceCategory.init(rawValue:))
        lastIP = try values.decodeIfPresent(String.self, forKey: .lastIP)
        lastHostname = try values.decodeIfPresent(String.self, forKey: .lastHostname)
        lastRouterName = try values.decodeIfPresent(String.self, forKey: .lastRouterName)
        awaitingReview = try values.decodeIfPresent(Bool.self, forKey: .awaitingReview) ?? false
    }
}

/// The whole `devices.json` value.
public struct DeviceRegistryState: Sendable, Equatable, Codable {
    /// Set once the first non-empty client list has been recorded without
    /// events. Until then, nothing counts as new.
    public var baselineEstablished: Bool
    public var records: [MACAddress: DeviceRecord]

    public init(baselineEstablished: Bool = false, records: [DeviceRecord] = []) {
        self.baselineEstablished = baselineEstablished
        self.records = Dictionary(records.map { ($0.mac, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var awaitingReview: [DeviceRecord] {
        records.values.filter(\.awaitingReview).sorted { ($0.firstSeen, $0.mac) < ($1.firstSeen, $1.mac) }
    }

    private enum CodingKeys: String, CodingKey { case baselineEstablished, records }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baselineEstablished = try values.decodeIfPresent(Bool.self, forKey: .baselineEstablished) ?? false
        let list = try values.decodeIfPresent([DeviceRecord].self, forKey: .records) ?? []
        records = Dictionary(list.map { ($0.mac, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Records are written as an array sorted by MAC so the file is stable.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baselineEstablished, forKey: .baselineEstablished)
        try container.encode(records.values.sorted { $0.mac < $1.mac }, forKey: .records)
    }
}
