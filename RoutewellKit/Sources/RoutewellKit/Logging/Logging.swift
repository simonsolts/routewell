import Foundation

/// The only error classes that may be presented outside the service boundary.
/// Error descriptions and transport details are deliberately not user-facing.
public enum FailureCategory: String, Sendable, Equatable, Hashable, Codable {
    case timeout, unreachable, authFailed, decodeFailed, unsupported, privacyDenied

    public var message: String {
        switch self {
        case .timeout: "The router took too long to respond. Try again."
        case .unreachable: "The router could not be reached. Check the connection and try again."
        case .authFailed: "Authentication failed. Check the saved credentials and try again."
        case .decodeFailed: "The router returned data Routewell could not read."
        case .unsupported: "This router feature is not supported."
        case .privacyDenied: "Routewell could not access the requested private data."
        }
    }
}

public extension RefreshFailureCategory {
    var failureCategory: FailureCategory {
        switch self {
        case .timeout: .timeout
        case .network, .unavailable: .unreachable
        case .authentication: .authFailed
        case .malformedResponse: .decodeFailed
        }
    }
}

public struct LogEvent: Sendable, Equatable, Codable, Identifiable {
    public enum Level: String, Sendable, Equatable, Codable { case info, warning, error }
    public enum Kind: String, Sendable, Equatable, Codable { case session, refresh, persistence }

    public let id: UUID
    public let occurredAt: Date
    public let level: Level
    public let kind: Kind
    public let message: String
    public let fields: [String: String]

    public init(id: UUID = UUID(), occurredAt: Date = .now, level: Level, kind: Kind,
                message: String, fields: [String: String] = [:]) {
        self.id = id
        self.occurredAt = occurredAt
        self.level = level
        self.kind = kind
        self.message = message
        self.fields = fields
    }
}

/// A bounded, process-lifetime diagnostic log. Its inputs are sanitized again
/// at this boundary so callers cannot accidentally retain a secret by mistake.
public actor SessionEventLog {
    private let limit: Int
    private var stored: [LogEvent] = []

    public init(limit: Int = 200) { self.limit = max(1, limit) }

    public func record(_ event: LogEvent) {
        stored.append(LogRedactor.sanitize(event))
        if stored.count > limit { stored.removeFirst(stored.count - limit) }
    }

    public func events() -> [LogEvent] { stored }
    public func clear() { stored.removeAll() }
}

public enum PayloadSchema: String, Sendable, Equatable, Codable {
    case loginResponse, adGuardStatus
}

public enum RedactionError: Error, Sendable, Equatable { case invalidJSON, unsupportedPayload }

/// A mapping belongs to one export. Supplying it explicitly makes aliases stable
/// inside that export without keeping identities in the session log.
public struct FixtureAliases: Sendable, Equatable {
    public var ipAddresses: [String: String]
    public var macAddresses: [String: String]
    public var names: [String: String]
    public var identifiers: [String: String]

    public init(ipAddresses: [String: String] = [:], macAddresses: [String: String] = [:],
                names: [String: String] = [:], identifiers: [String: String] = [:]) {
        self.ipAddresses = ipAddresses
        self.macAddresses = macAddresses
        self.names = names
        self.identifiers = identifiers
    }

    public init(ipAddresses: [String], macAddresses: [String] = [], names: [String] = [], identifiers: [String] = []) {
        self.init(
            ipAddresses: Dictionary(uniqueKeysWithValues: ipAddresses.enumerated().map { ($0.element, "198.51.100.\($0.offset + 1)") }),
            macAddresses: Dictionary(uniqueKeysWithValues: macAddresses.enumerated().map { ($0.element, String(format: "02:00:00:00:00:%02X", $0.offset + 1)) }),
            names: Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, "Device \($0.offset + 1)") }),
            identifiers: Dictionary(uniqueKeysWithValues: identifiers.enumerated().map { ($0.element, "client-\($0.offset + 1)") })
        )
    }
}

public enum PayloadRedactor {
    /// Redacts only payload schemas Routewell understands. Unknown schemas are
    /// rejected instead of being guessed at or stored as arbitrary text.
    public static func redact(_ body: Data, schema: PayloadSchema, aliases: FixtureAliases) throws -> Data {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: body) }
        catch { throw RedactionError.invalidJSON }
        let transformed = redact(object, key: nil, schema: schema, aliases: aliases)
        return try JSONSerialization.data(withJSONObject: transformed, options: [.sortedKeys])
    }

    private static func redact(_ value: Any, key: String?, schema: PayloadSchema, aliases: FixtureAliases) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, item in
                result[item.key] = redact(item.value, key: item.key, schema: schema, aliases: aliases)
            }
        }
        if let array = value as? [Any] {
            return array.map { redact($0, key: key, schema: schema, aliases: aliases) }
        }
        guard let string = value as? String else { return value }
        let normalized = key?.lowercased() ?? ""
        if secretKeys.contains(normalized) { return "[REDACTED]" }
        if ipKeys.contains(normalized) { return aliases.ipAddresses[string] ?? "[REDACTED IP]" }
        if macKeys.contains(normalized) { return aliases.macAddresses[string] ?? "[REDACTED MAC]" }
        if nameKeys.contains(normalized) { return aliases.names[string] ?? "[REDACTED NAME]" }
        if identifierKeys.contains(normalized) { return aliases.identifiers[string] ?? "[REDACTED ID]" }
        return string
    }

    private static let secretKeys: Set<String> = ["token", "password", "session", "sid", "cookie", "authorization", "auth"]
    private static let ipKeys: Set<String> = ["ip", "ipaddress", "ip_address", "clientip", "client_ip", "address"]
    private static let macKeys: Set<String> = ["mac", "macaddress", "mac_address"]
    private static let nameKeys: Set<String> = ["name", "hostname", "clientname", "client_name"]
    private static let identifierKeys: Set<String> = ["id", "clientid", "client_id", "deviceid", "device_id"]
}

public enum LogRedactor {
    public static func sanitize(_ event: LogEvent) -> LogEvent {
        let fields = event.fields.reduce(into: [String: String]()) { result, item in
            result[item.key] = isSensitiveKey(item.key) ? "[REDACTED]" : sanitizeText(item.value)
        }
        return LogEvent(id: event.id, occurredAt: event.occurredAt, level: event.level, kind: event.kind,
                        message: sanitizeText(event.message), fields: fields)
    }

    public static func export(_ events: [LogEvent]) throws -> Data {
        try JSONEncoder.routewellExport.encode(events.map(sanitize))
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let key = key.lowercased()
        return ["password", "token", "secret", "cookie", "authorization", "credential", "body", "url", "query", "ssh"].contains { key.contains($0) }
    }

    private static func sanitizeText(_ text: String) -> String {
        text.replacingOccurrences(of: "(?i)(bearer\\s+|token[=:]\\s*|password[=:]\\s*)[^\\s,;]+", with: "$1[REDACTED]", options: .regularExpression)
    }
}

private extension JSONEncoder {
    static var routewellExport: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
