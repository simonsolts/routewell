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
    /// The last Save Profile. `nil` when the profile was never saved or was
    /// cleared.
    public var personalisedAt: Date?

    public var id: MACAddress { mac }

    public init(
        mac: MACAddress, userName: String? = nil, favourite: Bool = false, hiddenFromAlerts: Bool = false,
        monitored: Bool = false, firstSeen: Date, lastSeen: Date? = nil, notes: String = "",
        category: DeviceCategory? = nil, lastIP: String? = nil, lastHostname: String? = nil,
        lastRouterName: String? = nil, awaitingReview: Bool = false, personalisedAt: Date? = nil
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
        self.personalisedAt = personalisedAt
    }

    private enum CodingKeys: String, CodingKey {
        case mac, userName, favourite, hiddenFromAlerts, monitored, firstSeen, lastSeen, notes, category
        case lastIP, lastHostname, lastRouterName, awaitingReview, personalisedAt
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
        personalisedAt = try values.decodeIfPresent(Date.self, forKey: .personalisedAt)
    }

    public var profile: DeviceProfile {
        DeviceProfile(userName: userName, category: category, notes: notes, favourite: favourite,
                      monitored: monitored, personalisedAt: personalisedAt)
    }
}

/// The part of a `DeviceRecord` the person edits. Local only: it never
/// reaches the router.
public struct DeviceProfile: Sendable, Equatable {
    public var userName: String?
    public var category: DeviceCategory?
    public var notes: String
    public var favourite: Bool
    public var monitored: Bool
    public var personalisedAt: Date?

    public init(userName: String? = nil, category: DeviceCategory? = nil, notes: String = "", favourite: Bool = false,
                monitored: Bool = false, personalisedAt: Date? = nil) {
        self.userName = userName
        self.category = category
        self.notes = notes
        self.favourite = favourite
        self.monitored = monitored
        self.personalisedAt = personalisedAt
    }
}

/// One profile write. Save Profile sets the form fields; the switches save
/// on their own; Clear Profile resets every field.
public enum DeviceProfileEdit: Sendable, Equatable {
    case save(userName: String?, category: DeviceCategory?, notes: String)
    case setFavourite(Bool)
    case setMonitored(Bool)
    case clear

    public static let maxNameLength = 64
    public static let maxNotesLength = 2_000

    public func validate() -> MutationRejection? {
        guard case .save(let name, _, let notes) = self else { return nil }
        if (name?.count ?? 0) > Self.maxNameLength { return .invalidIntent("Display name is longer than 64 characters") }
        if notes.count > Self.maxNotesLength { return .invalidIntent("Notes are longer than 2,000 characters") }
        return nil
    }

    /// The profile this edit produces. Blank names read as no name.
    public func applied(to profile: DeviceProfile, at now: Date) -> DeviceProfile {
        var next = profile
        switch self {
        case .save(let name, let category, let notes):
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            next.userName = trimmed?.isEmpty == false ? trimmed : nil
            next.category = category
            next.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            next.personalisedAt = now
        case .setFavourite(let value):
            next.favourite = value
        case .setMonitored(let value):
            next.monitored = value
        case .clear:
            next = DeviceProfile()
        }
        return next
    }
}

extension DeviceRecord {
    mutating func apply(_ profile: DeviceProfile) {
        userName = profile.userName
        category = profile.category
        notes = profile.notes
        favourite = profile.favourite
        monitored = profile.monitored
        personalisedAt = profile.personalisedAt
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
