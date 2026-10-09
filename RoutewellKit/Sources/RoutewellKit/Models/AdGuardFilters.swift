import Foundation

/// AdGuard Home calls allowlists `whitelist`.
public enum FilterListKind: String, Sendable, Equatable, CaseIterable, Codable {
    case blocklist, allowlist

    public var isAllowlist: Bool { self == .allowlist }
}

/// "Check every" values, in hours. 0 is "Never".
public enum FilterUpdateInterval {
    public static let hours: [Int] = [1, 12, 24, 72, 168, 0]

    public static func isValid(_ hours: Int) -> Bool { Self.hours.contains(hours) }
}

/// List URLs: what Routewell lets a person add, and when two are the same
/// list.
public enum FilterListURL {
    /// `http` or `https` with a host, no spaces. Leading and trailing
    /// spaces are dropped first.
    public static func validated(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        return trimmed
    }

    /// Same list: equal after the scheme and host are lowercased.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? trimmed
    }
}

/// Custom rules as editor text: one rule per line.
public enum CustomRulesText {
    public static func text(_ rules: [String]) -> String { rules.joined(separator: "\n") }

    /// Empty text is no rules. Windows line ends become `\n`.
    public static func rules(_ text: String) -> [String] {
        let normal = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normal.isEmpty else { return [] }
        return normal.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

/// The bundled list catalog. It has no rule counts.
public struct AdGuardListCatalog: Sendable, Equatable, Decodable {
    public struct Group: Sendable, Equatable, Decodable, Identifiable {
        public let id: Int
        public let name: String
        let displayNumber: Int?

        enum CodingKeys: String, CodingKey {
            case id = "groupId", name = "groupName", displayNumber
        }
    }

    public struct Entry: Sendable, Equatable, Decodable, Identifiable {
        public let id: Int
        public let group: Int
        public let name: String
        public let url: String
        let displayNumber: Int?
        let deprecated: Bool?

        enum CodingKeys: String, CodingKey {
            case id = "filterId", group = "groupId", name, url = "downloadUrl", displayNumber, deprecated
        }
    }

    public let groups: [Group]
    public let lists: [Entry]

    enum CodingKeys: String, CodingKey {
        case groups, lists = "filters"
    }

    /// Deprecated lists and empty groups are left out.
    public var sections: [(group: Group, lists: [Entry])] {
        groups.sorted { ($0.displayNumber ?? .max, $0.id) < ($1.displayNumber ?? .max, $1.id) }.compactMap { group in
            let members = lists.filter { $0.group == group.id && $0.deprecated != true }
                .sorted { ($0.displayNumber ?? .max, $0.id) < ($1.displayNumber ?? .max, $1.id) }
            return members.isEmpty ? nil : (group, members)
        }
    }

    /// Already a blocklist on AdGuard Home (same URL).
    public func isAdded(_ entry: Entry, in status: AdGuardFilteringStatus?) -> Bool {
        status?.list(.blocklist, url: entry.url) != nil
    }

    public static func decode(_ data: Data) throws -> AdGuardListCatalog {
        try JSONDecoder().decode(AdGuardListCatalog.self, from: data)
    }

    /// The copy in the package. Empty when the file is missing.
    public static let bundled: AdGuardListCatalog = {
        guard let url = Bundle.module.url(forResource: "adguard-filters", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? decode(data) else {
            return AdGuardListCatalog(groups: [], lists: [])
        }
        return catalog
    }()

    public init(groups: [Group], lists: [Entry]) {
        self.groups = groups
        self.lists = lists
    }
}
