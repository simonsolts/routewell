import Foundation

public struct FixtureCall: Sendable, Equatable {
    public enum Transport: String, Sendable { case rpc, adGuard }
    public let transport: Transport
    public let object: String?
    public let method: String
    public let fileName: String

    public init(_ transport: Transport, object: String? = nil, method: String, fileName: String) {
        self.transport = transport
        self.object = object
        self.method = method
        self.fileName = fileName
    }
}

public enum FixtureRecordingPlan {
    /// Candidates beyond the calls already used by Overview are assumed until
    /// a person records them on their router. Errors are useful evidence.
    public static let calls: [FixtureCall] = [
        .init(.rpc, object: "system", method: "get_status", fileName: "system-get_status.json"),
        .init(.rpc, object: "system", method: "get_info", fileName: "system-get_info.json"),
        .init(.rpc, object: "cable", method: "get_status", fileName: "cable-get_status.json"),
        .init(.rpc, object: "clients", method: "get_list", fileName: "clients-get_list.json"),
        .init(.rpc, object: "adguardhome", method: "get_config", fileName: "adguardhome-get_config.json"),
        .init(.rpc, object: "wifi", method: "get_config", fileName: "wifi-get_config.json"),
        .init(.rpc, object: "dhcp", method: "get_config", fileName: "dhcp-get_config.json"),
        .init(.rpc, object: "sqm", method: "get_config", fileName: "sqm-get_config.json"),
        .init(.rpc, object: "firmware", method: "get_info", fileName: "firmware-get_info.json"),
        .init(.rpc, object: "vpn-client", method: "get_config", fileName: "vpn-client-get_config.json"),
        .init(.rpc, object: "tailscale", method: "get_config", fileName: "tailscale-get_config.json"),
        .init(.rpc, object: "flow_statistics", method: "get_status", fileName: "flow_statistics-get_status.json"),
        .init(.adGuard, method: "control/status", fileName: "adguard-status.json"),
        .init(.adGuard, method: "control/stats", fileName: "adguard-stats.json"),
        .init(.adGuard, method: "control/clients", fileName: "adguard-clients.json"),
        .init(.adGuard, method: "control/querylog", fileName: "adguard-querylog.json"),
        .init(.adGuard, method: "control/filtering/status", fileName: "adguard-filtering-status.json")
    ]

    public static func isReadOnly(_ call: FixtureCall) -> Bool {
        switch call.transport {
        case .rpc: call.object != nil && (call.method.hasPrefix("get_") || call.method == "list")
        case .adGuard: call.method.hasPrefix("control/") && !call.method.contains("set") && !call.method.contains("update")
        }
    }
}

/// Applies a deny-by-default transform to every string leaf. This keeps the
/// JSON shape and numeric values while names, addresses, SSIDs, and secrets
/// cannot leave memory. One alias map spans an entire export.
public enum RecordedFixtureRedactor {
    public static func collectAliases(_ value: JSONValue, into aliases: inout FixtureAliases) {
        collect(value, key: nil, aliases: &aliases)
    }

    private static func collect(_ value: JSONValue, key: String?, aliases: inout FixtureAliases) {
        switch value {
        case .object(let object):
            for (field, child) in object.sorted(by: { $0.key < $1.key }) { collect(child, key: field, aliases: &aliases) }
        case .array(let array):
            for child in array { collect(child, key: key, aliases: &aliases) }
        case .string(let string):
            let field = key?.lowercased() ?? ""
            if field.contains("mac"), aliases.macAddresses[string] == nil {
                aliases.macAddresses[string] = String(format: "02:00:00:00:%02X:%02X", aliases.macAddresses.count / 256, aliases.macAddresses.count % 256)
            } else if (field.contains("ip") || field.contains("address") || field.contains("gateway") || field.contains("dns")), aliases.ipAddresses[string] == nil {
                let index = aliases.ipAddresses.count
                aliases.ipAddresses[string] = "198.51.\(100 + index / 254).\(1 + index % 254)"
            } else if (field.contains("ssid") || field.contains("name") || field.contains("host")), aliases.names[string] == nil {
                aliases.names[string] = "Example \(aliases.names.count + 1)"
            }
        default: break
        }
    }

    public static func redact(_ value: JSONValue, aliases: FixtureAliases = .init()) -> JSONValue {
        transform(value, key: nil, aliases: aliases)
    }

    private static func transform(_ value: JSONValue, key: String?, aliases: FixtureAliases) -> JSONValue {
        if let key, ["token", "password", "sid", "cookie", "hash", "nonce", "salt", "secret", "auth"].contains(where: key.lowercased().contains) {
            return .string("[REDACTED]")
        }
        switch value {
        case .object(let object):
            var output: [String: JSONValue] = [:]
            for (index, entry) in object.sorted(by: { $0.key < $1.key }).enumerated() {
                let field = entry.key
                let safeKey = field.range(of: #"(?:\d{1,3}\.){3}\d{1,3}|(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}|@|secret|password|token"#, options: .regularExpression) == nil
                    ? field : "redacted-key-\(index)"
                output[safeKey] = transform(entry.value, key: field, aliases: aliases)
            }
            return .object(output)
        case .array(let array): return .array(array.map { transform($0, key: key, aliases: aliases) })
        case .string(let string):
            let field = key?.lowercased() ?? ""
            if ["token", "password", "sid", "cookie", "hash", "nonce", "salt", "secret", "auth"].contains(where: field.contains) { return .string("[REDACTED]") }
            if field.contains("mac") { return .string(aliases.macAddresses[string] ?? "02:00:00:00:00:01") }
            if field.contains("ip") || field.contains("address") || field.contains("gateway") || field.contains("dns") { return .string(aliases.ipAddresses[string] ?? "198.51.100.1") }
            if field.contains("ssid") || field.contains("name") || field.contains("host") { return .string(aliases.names[string] ?? "Example") }
            if ["enabled", "disabled", "running", "stopped", "online", "offline", "up", "down", "unknown"].contains(string.lowercased()) { return .string(string) }
            return .string("[REDACTED TEXT]")
        default: return value
        }
    }
}

public protocol FixtureRecordableBackend: Sendable {
    func recordFixture(_ call: FixtureCall) async -> JSONValue
}

public actor FixtureRecorder {
    public init() {}

    public func record(session: RouterSession, lease: SessionLease, to directory: URL,
                       calls: [FixtureCall] = FixtureRecordingPlan.calls) async throws -> Int {
        guard calls.allSatisfy(FixtureRecordingPlan.isReadOnly) else { throw RecorderError.unsafePlan }
        guard let backend = lease.backend as? any FixtureRecordableBackend else { throw RecorderError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var count = 0
        var aliases = FixtureAliases()
        for call in calls {
            try Task.checkCancellation()
            try await session.validateBefore(lease)
            let value = await backend.recordFixture(call)
            try Task.checkCancellation()
            try await session.validateAfter(lease)
            RecordedFixtureRedactor.collectAliases(value, into: &aliases)
            let data = try PayloadRedactor.redact(JSONEncoder().encode(value), schema: .recordedFixture, aliases: aliases)
            try data.write(to: directory.appendingPathComponent(call.fileName), options: .atomic)
            count += 1
        }
        return count
    }
}

public enum RecorderError: Error, Sendable { case unsafePlan, unavailable }
