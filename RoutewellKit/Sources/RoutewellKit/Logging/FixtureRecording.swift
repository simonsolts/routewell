import Foundation

public struct FixtureCall: Sendable, Equatable {
    /// `ssh` calls name one fixed `SSHCommand` by key (chunk 15); nothing
    /// else can be run.
    public enum Transport: String, Sendable { case rpc, adGuard, ssh }
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
        // Candidate source for per-client signal, radio, and channel (chunks 12 and 14).
        .init(.rpc, object: "wifi", method: "get_status", fileName: "wifi-get_status.json"),
        .init(.rpc, object: "dhcp", method: "get_config", fileName: "dhcp-get_config.json"),
        .init(.rpc, object: "sqm", method: "get_config", fileName: "sqm-get_config.json"),
        .init(.rpc, object: "firmware", method: "get_info", fileName: "firmware-get_info.json"),
        .init(.rpc, object: "vpn-client", method: "get_config", fileName: "vpn-client-get_config.json"),
        .init(.rpc, object: "tailscale", method: "get_config", fileName: "tailscale-get_config.json"),
        .init(.rpc, object: "flow_statistics", method: "get_status", fileName: "flow_statistics-get_status.json"),
        // Chunk 14: the router asks GL.iNet's server whether newer firmware
        // exists. It downloads and installs nothing.
        .init(.rpc, object: "upgrade", method: "check_firmware_online", fileName: "upgrade-check_firmware_online.json"),
        .init(.adGuard, method: "control/status", fileName: "adguard-status.json"),
        .init(.adGuard, method: "control/stats", fileName: "adguard-stats.json"),
        .init(.adGuard, method: "control/clients", fileName: "adguard-clients.json"),
        .init(.adGuard, method: "control/querylog", fileName: "adguard-querylog.json"),
        .init(.adGuard, method: "control/filtering/status", fileName: "adguard-filtering-status.json"),
        // Chunk 17: Overview ranges. `recent` is the lookback in ms; an older
        // AdGuard Home ignores it or answers 400. Both are useful evidence.
        .init(.adGuard, method: "control/stats?recent=86400000", fileName: "adguard-stats-recent-24h.json"),
        .init(.adGuard, method: "control/stats?recent=604800000", fileName: "adguard-stats-recent-7d.json"),
        .init(.adGuard, method: "control/stats?recent=2592000000", fileName: "adguard-stats-recent-30d.json"),
        .init(.adGuard, method: "control/stats/config", fileName: "adguard-stats-config.json"),
        .init(.adGuard, method: "control/safebrowsing/status", fileName: "adguard-safebrowsing-status.json"),
        .init(.adGuard, method: "control/parental/status", fileName: "adguard-parental-status.json"),
        .init(.adGuard, method: "control/safesearch/status", fileName: "adguard-safesearch-status.json"),
        // Chunk 15: the SSH reads. Recorded only when SSH is set up for the
        // profile; otherwise they are skipped.
        .init(.ssh, method: "system-board", fileName: "ssh-ubus-system-board.json"),
        .init(.ssh, method: "log-tail", fileName: "ssh-logread-250.txt"),
        .init(.ssh, method: "root-filesystem", fileName: "ssh-df-h-root.txt"),
        .init(.ssh, method: "disk-usage", fileName: "ssh-df-k.txt"),
        .init(.ssh, method: "mount-table", fileName: "ssh-proc-mounts.txt"),
        .init(.ssh, method: "samba-shares", fileName: "ssh-samba-shares.txt"),
        .init(.ssh, method: "network-interfaces", fileName: "ssh-sys-class-net-interfaces.txt"),
        .init(.ssh, method: interfaceTelemetryKey, fileName: "ssh-sys-class-net-telemetry.txt"),
        .init(.ssh, method: "adguard-process", fileName: "ssh-pgrep-adguardhome.txt"),
    ]

    /// The fixed SSH reads the recorder may run, by key. The interface
    /// telemetry is not here: its names come from the enumeration first.
    public static let sshReads: [String: SSHCommand] = [
        "system-board": .systemBoard,
        "log-tail": .logTail,
        "root-filesystem": .rootFilesystem,
        "disk-usage": .diskUsage,
        "mount-table": .mountTable,
        "samba-shares": .sambaShares,
        "network-interfaces": .networkInterfaces,
        "adguard-process": .adGuardProcess,
    ]
    public static let interfaceTelemetryKey = "interface-telemetry"

    /// RPC reads whose names do not start with `get_`. Each one is named
    /// exactly; the prefix rule stays the only general rule.
    static let namedReads: Set<String> = ["upgrade.check_firmware_online"]

    public static func isReadOnly(_ call: FixtureCall) -> Bool {
        switch call.transport {
        case .rpc:
            guard let object = call.object else { return false }
            return call.method.hasPrefix("get_") || call.method == "list" || namedReads.contains("\(object).\(call.method)")
        case .adGuard:
            return call.method.hasPrefix("control/") && !call.method.contains("set") && !call.method.contains("update")
        case .ssh:
            return call.object == nil && (sshReads[call.method] != nil || call.method == interfaceTelemetryKey)
        }
    }
}

/// Applies a deny-by-default transform to every string leaf. This keeps the
/// JSON shape and numeric values while names, addresses, SSIDs, and secrets
/// cannot leave memory. One alias map spans an entire export.
///
/// Narrow rules keep review evidence that is not private: empty strings stay
/// empty, any IP or MAC value (or object key) gets its stable alias, short
/// technical tokens pass for a few known enum fields, and numeric strings and
/// timestamps pass for known counter and time fields.
public enum RecordedFixtureRedactor {
    public static func collectAliases(_ value: JSONValue, into aliases: inout FixtureAliases) {
        collect(value, key: nil, aliases: &aliases)
    }

    private static func collect(_ value: JSONValue, key: String?, aliases: inout FixtureAliases) {
        switch value {
        case .object(let object):
            for (field, child) in object.sorted(by: { $0.key < $1.key }) {
                collectAddress(field, aliases: &aliases)
                collect(child, key: field, aliases: &aliases)
            }
        case .array(let array):
            for child in array { collect(child, key: key, aliases: &aliases) }
        case .string(let string):
            guard !string.isEmpty else { return }
            if collectAddress(string, aliases: &aliases) { return }
            let field = key?.lowercased() ?? ""
            if field.contains("mac"), aliases.macAddresses[string] == nil {
                addMAC(string, aliases: &aliases)
            } else if (field.contains("ip") || field.contains("address") || field.contains("gateway") || field.contains("dns")), aliases.ipAddresses[string] == nil {
                addIP(string, aliases: &aliases)
            } else if isNameField(field), aliases.names[string] == nil {
                aliases.names[string] = "Example \(aliases.names.count + 1)"
            }
        default: break
        }
    }

    /// Returns true when `string` is an IP or MAC address, adding an alias if needed.
    @discardableResult
    private static func collectAddress(_ string: String, aliases: inout FixtureAliases) -> Bool {
        if isMAC(string) {
            if aliases.macAddresses[string] == nil { addMAC(string, aliases: &aliases) }
            return true
        }
        if isIPAddress(string) {
            if aliases.ipAddresses[string] == nil { addIP(string, aliases: &aliases) }
            return true
        }
        return false
    }

    private static func addMAC(_ string: String, aliases: inout FixtureAliases) {
        aliases.macAddresses[string] = String(format: "02:00:00:00:%02X:%02X", aliases.macAddresses.count / 256, aliases.macAddresses.count % 256)
    }

    private static func addIP(_ string: String, aliases: inout FixtureAliases) {
        let index = aliases.ipAddresses.count
        aliases.ipAddresses[string] = "198.51.\(100 + index / 254).\(1 + index % 254)"
    }

    public static func redact(_ value: JSONValue, aliases: FixtureAliases = .init()) -> JSONValue {
        transform(value, key: nil, aliases: aliases)
    }

    private static func transform(_ value: JSONValue, key: String?, aliases: FixtureAliases) -> JSONValue {
        if let key, secretFragments.contains(where: key.lowercased().contains) {
            return .string("[REDACTED]")
        }
        switch value {
        case .object(let object):
            var output: [String: JSONValue] = [:]
            for (index, entry) in object.sorted(by: { $0.key < $1.key }).enumerated() {
                let field = entry.key
                let safeKey: String
                if let alias = aliases.macAddresses[field] ?? aliases.ipAddresses[field] {
                    safeKey = alias
                } else if field.range(of: #"(?:\d{1,3}\.){3}\d{1,3}|(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}|@|secret|password|token"#, options: .regularExpression) == nil, !isIPAddress(field) {
                    safeKey = field
                } else {
                    safeKey = "redacted-key-\(index)"
                }
                output[safeKey] = transform(entry.value, key: field, aliases: aliases)
            }
            return .object(output)
        case .array(let array): return .array(array.map { transform($0, key: key, aliases: aliases) })
        case .string(let string):
            let field = key?.lowercased() ?? ""
            if secretFragments.contains(where: field.contains) { return .string("[REDACTED]") }
            if string.isEmpty { return .string("") }
            if isMAC(string) { return .string(aliases.macAddresses[string] ?? "02:00:00:00:00:01") }
            if isIPAddress(string) { return .string(aliases.ipAddresses[string] ?? "198.51.100.1") }
            if field.contains("mac") { return .string(aliases.macAddresses[string] ?? "02:00:00:00:00:01") }
            if field.contains("ip") || field.contains("address") || field.contains("gateway") || field.contains("dns") { return .string(aliases.ipAddresses[string] ?? "198.51.100.1") }
            if isNameField(field) { return .string(aliases.names[string] ?? "Example") }
            if ["enabled", "disabled", "running", "stopped", "online", "offline", "up", "down", "unknown"].contains(string.lowercased()) { return .string(string) }
            if tokenFields.contains(field), string.range(of: #"^[A-Za-z0-9._:/+()-]{1,40}$"#, options: .regularExpression) != nil { return .string(string) }
            if numericFields.contains(field), string.range(of: #"^-?\d{1,20}(\.\d{1,12})?$"#, options: .regularExpression) != nil { return .string(string) }
            if timeFields.contains(field), string.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil { return .string(string) }
            return .string("[REDACTED TEXT]")
        default: return value
        }
    }

    private static let secretFragments = ["token", "password", "sid", "cookie", "hash", "nonce", "salt", "secret", "auth"]
    /// Router and AdGuard enum-like fields whose values are technical tokens,
    /// never personal text: interface names, device class, vendor, AdGuard
    /// client source, query result reason, DNS status, protocol, record type.
    /// Chunk 14 adds version, kernel, architecture, radio, and SQM tokens.
    private static let tokenFields: Set<String> = ["iface", "class", "vendor", "source", "reason", "status", "client_proto", "type", "band", "time_units",
        "firmware_version", "current_version", "new_firmware_version", "version", "kernel_version", "openwrt_version", "architecture",
        "firmware_type", "htmode", "hwmode", "txpower", "qdisc", "protocol", "device", "state", "interface"]
    private static let numericFields: Set<String> = ["total_rx", "total_tx", "total_rx_init", "total_tx_init", "online_time", "elapsedms", "upload", "download"]
    private static let timeFields: Set<String> = ["time", "oldest"]

    private static func isNameField(_ field: String) -> Bool {
        field.contains("ssid") || field.contains("name") || field.contains("host") || field == "alias"
    }

    static func isMAC(_ string: String) -> Bool {
        string.range(of: #"^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil
    }

    static func isIPAddress(_ string: String) -> Bool { IPAddressText.isValid(string) }
}

public protocol FixtureRecordableBackend: Sendable {
    func recordFixture(_ call: FixtureCall) async -> JSONValue
    /// The raw text of one SSH read, or `nil` when SSH is not set up.
    func recordSSHFixture(_ call: FixtureCall) async -> String?
}

public extension FixtureRecordableBackend {
    func recordSSHFixture(_ call: FixtureCall) async -> String? { nil }
}

/// Redacts SSH text output before it is written: IP and MAC addresses get
/// the export's stable aliases, quoted text becomes an example name (yes/no
/// flags stay), key fingerprints, DHCP host names, queried domains, and
/// e-mail addresses are removed. Log messages can still hold other private
/// text, so every recorded file is reviewed before any fixture is committed.
public enum RecordedTextRedactor {
    public static func redact(_ text: String, aliases: inout FixtureAliases) -> String {
        var names = aliases
        var output = text.replacing(/(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}/) { match in
            let mac = String(match.0)
            if names.macAddresses[mac] == nil {
                names.macAddresses[mac] = String(format: "02:00:00:00:%02X:%02X", names.macAddresses.count / 256, names.macAddresses.count % 256)
            }
            return names.macAddresses[mac]!
        }
        output = output.replacing(/(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}|\b(?:\d{1,3}\.){3}\d{1,3}\b/) { match in
            let address = String(match.0)
            guard IPAddressText.isValid(address) else { return address }
            if names.ipAddresses[address] == nil {
                let index = names.ipAddresses.count
                names.ipAddresses[address] = "198.51.\(100 + index / 254).\(1 + index % 254)"
            }
            return names.ipAddresses[address]!
        }
        output = output.replacing(/SHA256:[A-Za-z0-9+\/=]+/) { _ in "SHA256:[REDACTED]" }
        output = output.replacing(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/) { _ in "[REDACTED EMAIL]" }
        output = output.replacing(/(DHCP[A-Z]+\([^)]*\) \S+ \S+) \S+/) { match in "\(match.1) [REDACTED HOST]" }
        output = output.replacing(/(query\[[A-Za-z0-9]+\]|reply|forwarded|cached|config) (\S+)/) { match in "\(match.1) [REDACTED DOMAIN]" }
        output = output.replacing(/'([^'\n]*)'/) { match in "'\(quoted(String(match.1), names: &names))'" }
        output = output.replacing(/"([^"\n]*)"/) { match in "\"\(quoted(String(match.1), names: &names))\"" }
        aliases = names
        return output
    }

    /// Flags and aliases stay; any other quoted text becomes "Example N".
    private static func quoted(_ value: String, names: inout FixtureAliases) -> String {
        let safe = value.isEmpty || ["yes", "no", "0", "1", "true", "false", "on", "off"].contains(value.lowercased())
            || value.hasPrefix("198.51.") || value.hasPrefix("02:00:00:00:") || value.hasPrefix("[REDACTED")
        if safe { return value }
        if names.names[value] == nil { names.names[value] = "Example \(names.names.count + 1)" }
        return names.names[value]!
    }
}

public struct FixtureRecordingManifest: Sendable, Codable, Equatable {
    public let source: String
    public let privacy: String
    public let files: [String]

    public init(source: String, files: [String]) {
        self.source = source
        self.privacy = "Addresses, MACs, names, SSIDs, credentials, and other text are replaced before writing. Example values are privacy aliases."
        self.files = files
    }
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
        var written: [String] = []
        for call in calls {
            try Task.checkCancellation()
            try await session.validateBefore(lease)
            let data: Data
            if call.transport == .ssh {
                // Skipped, not written, when SSH is not set up for the profile.
                guard let text = await backend.recordSSHFixture(call) else { continue }
                try Task.checkCancellation()
                try await session.validateAfter(lease)
                if call.fileName.hasSuffix(".json"), let body = Self.jsonBody(text) {
                    RecordedFixtureRedactor.collectAliases(body, into: &aliases)
                    data = try PayloadRedactor.redact(JSONEncoder().encode(body), schema: .recordedFixture, aliases: aliases)
                } else {
                    data = Data(RecordedTextRedactor.redact(text, aliases: &aliases).utf8)
                }
            } else {
                let value = await backend.recordFixture(call)
                try Task.checkCancellation()
                try await session.validateAfter(lease)
                RecordedFixtureRedactor.collectAliases(value, into: &aliases)
                data = try PayloadRedactor.redact(JSONEncoder().encode(value), schema: .recordedFixture, aliases: aliases)
            }
            try data.write(to: directory.appendingPathComponent(call.fileName), options: .atomic)
            written.append(call.fileName)
            count += 1
        }
        try Task.checkCancellation()
        try await session.validateAfter(lease)
        let manifest = FixtureRecordingManifest(
            source: backend is LiveRouterBackend ? "live-router" : "synthetic-test-backend",
            files: written
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("_recording-manifest.json"), options: .atomic)
        return count
    }
}

public enum RecorderError: Error, Sendable { case unsafePlan, unavailable }

extension FixtureRecorder {
    /// The JSON after the `# ...` header lines of an SSH recording, if any.
    static func jsonBody(_ text: String) -> JSONValue? {
        let body = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        return try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
    }
}
