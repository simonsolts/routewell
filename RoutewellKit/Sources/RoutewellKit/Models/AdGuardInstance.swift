import Foundation

/// `POST control/version.json` `[assumed]`: `disabled`, `new_version`,
/// `announcement`, `announcement_url`. With `disabled` true the other
/// fields are absent.
public struct AdGuardVersionCheck: Sendable, Equatable, Codable {
    public var disabled: Bool?
    public var newVersion: String?
    public var announcement: String?
    public var announcementURL: String?

    public init(disabled: Bool? = nil, newVersion: String? = nil, announcement: String? = nil, announcementURL: String? = nil) {
        self.disabled = disabled
        self.newVersion = newVersion
        self.announcement = announcement
        self.announcementURL = announcementURL
    }

    public static func parse(_ json: JSONValue) -> AdGuardVersionCheck {
        AdGuardVersionCheck(disabled: json["disabled"]?.bool, newVersion: json["new_version"]?.string,
                            announcement: json["announcement"]?.string, announcementURL: json["announcement_url"]?.string)
    }

    public enum Update: Sendable, Equatable {
        case available(String)
        case upToDate
        case unknown
    }

    /// Unknown when the check is off or says nothing. A `new_version` equal
    /// to the running one is up to date.
    public func update(current: String?) -> Update {
        guard disabled == false else { return .unknown }
        let new = (newVersion ?? "").trimmingCharacters(in: .whitespaces)
        if new.isEmpty || Self.normalized(new) == current.map(Self.normalized) { return .upToDate }
        return .available(new)
    }

    private static func normalized(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }
}

/// `GET control/querylog/config` `[verified live]` (chunk 18 recording):
/// `enabled`, `interval` (ms), `anonymize_client_ip`, `ignored`,
/// `ignored_enabled`.
public struct AdGuardQueryLogConfig: Sendable, Equatable, Codable {
    public var enabled: Bool?
    /// Retention in milliseconds.
    public var intervalMilliseconds: Int?
    public var anonymizeClientIP: Bool?

    public init(enabled: Bool? = nil, intervalMilliseconds: Int? = nil, anonymizeClientIP: Bool? = nil) {
        self.enabled = enabled
        self.intervalMilliseconds = intervalMilliseconds
        self.anonymizeClientIP = anonymizeClientIP
    }

    public static func parse(_ json: JSONValue) -> AdGuardQueryLogConfig {
        AdGuardQueryLogConfig(enabled: json["enabled"]?.bool,
                              intervalMilliseconds: json["interval"]?.int,
                              anonymizeClientIP: json["anonymize_client_ip"]?.bool)
    }
}

/// The "Keep … for" pop-ups. AdGuard Home accepts whole hours.
public enum AdGuardRetention {
    public static let hour = 3_600_000
    public static let options: [Int] = [24 * hour, 7 * 24 * hour, 30 * 24 * hour, 90 * 24 * hour]

    public static func isValid(_ milliseconds: Int) -> Bool {
        milliseconds >= hour && milliseconds % hour == 0
    }
}

/// The Instance tab's own reads, saved as the archive's `instance` section.
public struct AdGuardInstanceInfo: Sendable, Equatable, Codable {
    public var version: AdGuardVersionCheck?
    public var queryLog: AdGuardQueryLogConfig?

    public init(version: AdGuardVersionCheck? = nil, queryLog: AdGuardQueryLogConfig? = nil) {
        self.version = version
        self.queryLog = queryLog
    }
}

/// Memory and the query log's size on the router, over SSH.
public struct AdGuardResources: Sendable, Equatable {
    public var memoryBytes: Observed<Int>
    public var queryLogBytes: Observed<Int>

    public init(memoryBytes: Observed<Int> = .unknown, queryLogBytes: Observed<Int> = .unknown) {
        self.memoryBytes = memoryBytes
        self.queryLogBytes = queryLogBytes
    }
}

public enum AdGuardResourceParser {
    /// `VmRSS:   51234 kB` lines, one per AdGuard Home process; the sum.
    /// Unavailable when the command found no process.
    public static func memoryBytes(_ text: String, exitStatus: Int32) -> Observed<Int> {
        var total = 0
        var found = false
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("VmRSS:") {
            let fields = line.dropFirst("VmRSS:".count).split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == "kB", let kilobytes = Int(fields[0]) else { return .unknown }
            total += kilobytes * 1024
            found = true
        }
        if found { return .value(total) }
        return exitStatus == 0 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unavailable : .unknown
    }

    /// `du -k` lines (`<kilobytes>\t<path>`); the sum.
    public static func diskBytes(_ text: String) -> Observed<Int> {
        var total = 0
        var found = false
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.split(whereSeparator: \.isWhitespace).first, let kilobytes = Int(first) else { return .unknown }
            total += kilobytes * 1024
            found = true
        }
        return found ? .value(total) : .unknown
    }
}

/// AdGuard Home's `config.yaml`, as read from the router. It holds password
/// hashes: never log it, and never put it anywhere but the backups folder
/// and a place the person chooses.
public struct AdGuardConfigFile: Sendable, Equatable {
    public static let maximumBytes = 1 << 20

    public let data: Data
    /// The few `dns:` values a restore can compare with `dns_info`.
    public let dns: DNSValues

    public struct DNSValues: Sendable, Equatable {
        public var upstreams: [String]?
        public var blockingMode: String?
        public var cacheSize: Int?
        public var rateLimit: Int?

        /// Only the values both sides have are compared.
        public func matches(_ settings: AdGuardDNSSettings) -> Bool {
            if let upstreams, let live = settings.upstreams, upstreams != live { return false }
            if let blockingMode, let live = settings.blockingMode, blockingMode != live.rawValue { return false }
            if let cacheSize, let live = settings.cacheSize, cacheSize != live { return false }
            if let rateLimit, let live = settings.rateLimit, rateLimit != live { return false }
            return true
        }
    }

    /// `nil` unless it is UTF-8 text with a top-level `dns:` section
    /// `[assumed]` and at most `maximumBytes`.
    public init?(_ data: Data) {
        guard !data.isEmpty, data.count <= Self.maximumBytes, let text = String(data: data, encoding: .utf8),
              let dns = Self.dnsSection(text) else { return nil }
        self.data = data
        self.dns = dns
    }

    /// Reads scalars and simple lists one level under `dns:`. Enough for
    /// the four values above; anything else is skipped.
    static func dnsSection(_ text: String) -> DNSValues? {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("dns:") && $0.dropFirst(4).allSatisfy(\.isWhitespace) }) else { return nil }
        var scalars: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var childIndent: Int?
        var listKey: String?
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 && !trimmed.hasPrefix("-") { break }
            if childIndent == nil { childIndent = indent }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                if let listKey, indent >= childIndent! {
                    lists[listKey, default: []].append(unquoted(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
                }
                continue
            }
            guard indent == childIndent, let colon = trimmed.firstIndex(of: ":") else {
                if indent <= childIndent! { listKey = nil }
                continue
            }
            let key = String(trimmed[..<colon])
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                listKey = key
                lists[key] = lists[key] ?? []
            } else {
                listKey = nil
                if value == "[]" { lists[key] = [] } else { scalars[key] = unquoted(value) }
            }
        }
        return DNSValues(upstreams: lists["upstream_dns"], blockingMode: scalars["blocking_mode"],
                         cacheSize: scalars["cache_size"].flatMap { Int($0) }, rateLimit: scalars["ratelimit"].flatMap { Int($0) })
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "'" || first == "\"", value.last == first else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "'" ? inner.replacingOccurrences(of: "''", with: "'") : inner
    }
}

/// One saved copy of `config.yaml` on the Mac. The file itself sits next
/// to this record.
public struct AdGuardBackup: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case manual
        case beforeRestore
    }

    public var id: UUID
    public var createdAt: Date
    public var kind: Kind
    public var size: Int
    /// AdGuard Home's version when the copy was made, if known.
    public var version: String?

    public init(id: UUID = UUID(), createdAt: Date, kind: Kind, size: Int, version: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.size = size
        self.version = version
    }
}
