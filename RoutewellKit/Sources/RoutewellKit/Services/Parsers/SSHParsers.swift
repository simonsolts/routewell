import Foundation

// SSH output formats, first built from RouterPilot's source and the OpenWrt
// tools, then checked against the 4.9.1 recording: the board JSON
// keys, `logread` lines, `df -h /`, `df -k`, `/proc/mounts`, the Samba
// filter, the interface enumeration, and `pgrep -a` are `[verified live]`.
// The `/sys/class/net` telemetry values stay `[assumed]`. Each parser skips
// what it cannot read and never invents a value.

/// `ubus call system board`: a JSON object. `nil` when the output is not one.
public enum SystemBoardParser {
    public static func parse(_ text: String) -> SystemBoard? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), case .object = value else { return nil }
        let release = value["release"]
        return SystemBoard(model: value["model"]?.string, hostname: value["hostname"]?.string, boardName: value["board_name"]?.string,
                           releaseVersion: release?["version"]?.string, kernel: value["kernel"]?.string ?? release?["kernel"]?.string,
                           target: release?["target"]?.string)
    }
}

/// `logread -l 250`. OpenWrt's `logread` prints
/// `Thu Jan 15 10:01:20 2026 authpriv.info dropbear[1400]: message`; the kernel
/// tag is `kernel`, and GL.iNet daemons may leave the tag empty (`user.err : …`).
public enum LogReadParser {
    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    /// Newest first, at most `RouterLogTail.limit`. Times use `timeZone`;
    /// the router's own zone is not reported `[assumed]` to match the Mac's.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> RouterLogTail {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let entries = lines.suffix(RouterLogTail.limit).reversed().enumerated().map { index, line in
            entry(line, id: index, calendar: calendar)
        }
        return RouterLogTail(entries: entries)
    }

    static func entry(_ raw: String, id: Int, calendar: Calendar) -> RouterLogEntry {
        let stamp = /^\s*[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})\s+(.*)$/
        guard let match = raw.firstMatch(of: stamp) else {
            return RouterLogEntry(id: id, time: nil, facility: nil, severity: nil, source: "router", category: .system, message: raw, line: raw)
        }
        var components = DateComponents()
        components.month = months[match.1.lowercased()]
        components.day = Int(match.2)
        components.hour = Int(match.3)
        components.minute = Int(match.4)
        components.second = Int(match.5)
        components.year = Int(match.6)
        let time = components.month == nil ? nil : calendar.date(from: components)
        let line = String(match.7)

        var facility: String?
        var severity: RouterLogSeverity?
        var rest = line
        if let priority = line.firstMatch(of: /^([a-z0-9]+)\.([a-z]+)\s+(.*)$/), let parsed = RouterLogSeverity.parse(String(priority.2)) {
            facility = String(priority.1)
            severity = parsed
            rest = String(priority.3)
        }
        var tag = ""
        var message = rest
        if let tagged = rest.firstMatch(of: /^([^\s:\[]*)(?:\[\d+\])?:\s?(.*)$/) {
            tag = String(tagged.1)
            message = String(tagged.2)
        }
        let source = source(for: tag)
        return RouterLogEntry(id: id, time: time, facility: facility, severity: severity, source: source,
                              category: category(tag: tag, facility: facility), message: message, line: line)
    }

    /// GL.iNet's own daemons (`eco`, `gl-*`, an empty tag) read as "router";
    /// `dnsmasq-dhcp` and friends read as "dnsmasq".
    static func source(for tag: String) -> String {
        let lowered = tag.lowercased()
        if lowered.isEmpty || lowered == "eco" || lowered.hasPrefix("gl") { return "router" }
        if lowered.hasPrefix("dnsmasq") { return "dnsmasq" }
        return tag
    }

    static func category(tag: String, facility: String?) -> RouterLogCategory {
        let tag = tag.lowercased()
        if facility == "kern" || tag == "kernel" { return .kernel }
        func any(_ prefixes: [String]) -> Bool { prefixes.contains { tag.hasPrefix($0) } }
        if any(["dnsmasq", "odhcpd", "dhcp"]) { return .dhcpDNS }
        if tag.contains("adguard") { return .adGuard }
        if any(["hostapd", "wpa_supplicant", "wifi", "wireless", "mtk", "iwinfo"]) || tag.contains("wlan") { return .wifi }
        if any(["firewall", "fw3", "fw4", "iptables", "ip6tables", "nft", "ipset"]) { return .firewall }
        if any(["netifd", "pppd", "odhcp6c", "udhcpc", "mwan", "kmwan", "modem", "wan"]) { return .networkWAN }
        if any(["openvpn", "wireguard", "wg", "tailscale", "ovpn"]) || tag.contains("vpn") { return .vpn }
        if any(["block", "mountd", "mount", "smbd", "nmbd", "samba", "ksmbd", "ntfs", "e2fsck", "fstab"]) { return .storage }
        return .system
    }
}

/// `df` output. BusyBox wraps a long filesystem name onto its own line;
/// both parsers join such a line with the next one.
public enum DiskFreeParser {
    /// `df -h /`: the row whose mount point is `/`.
    public static func parseRoot(_ text: String) -> RootFilesystem? {
        rows(text).last { $0.count >= 6 && $0[5...].joined(separator: " ") == "/" }.map { fields in
            RootFilesystem(filesystem: fields[0], size: fields[1], used: fields[2], available: fields[3],
                           usePercent: Int(fields[4].trimmingCharacters(in: CharacterSet(charactersIn: "%"))), mountPoint: "/")
        }
    }

    /// `df -k`: every row, sizes converted from KiB to bytes.
    public static func parseKilobytes(_ text: String) -> [MountedVolume] {
        rows(text).compactMap { fields in
            guard fields.count >= 6 else { return nil }
            func bytes(_ field: String) -> Int64? { Int64(field).map { $0 * 1024 } }
            return MountedVolume(device: fields[0], mountPoint: fields[5...].joined(separator: " "),
                                 totalBytes: bytes(fields[1]), usedBytes: bytes(fields[2]), availableBytes: bytes(fields[3]))
        }
    }

    private static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var carried: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if fields.first == "Filesystem" { continue }
            if fields.count == 1 && carried.isEmpty { carried = fields; continue }
            rows.append(carried + fields)
            carried = []
        }
        return rows
    }
}

/// `/proc/mounts`: `device mountpoint type options 0 0`, with `\040`-style
/// octal escapes in paths.
public enum MountTableParser {
    public struct Mount: Sendable, Equatable {
        public let device: String
        public let mountPoint: String
        public let type: String
    }

    public static func parse(_ text: String) -> [Mount] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count >= 3 else { return nil }
            return Mount(device: unescape(fields[0]), mountPoint: unescape(fields[1]), type: fields[2])
        }
    }

    static func unescape(_ field: String) -> String {
        field.replacing(/\\([0-7]{3})/) { match in
            UInt8(match.1, radix: 8).map { String(UnicodeScalar($0)) } ?? String(match.0)
        }
    }

    /// External volumes from `df -k`, each with its type from `/proc/mounts`.
    public static func externalVolumes(diskFree: String, mounts: String) -> [MountedVolume] {
        let types = Dictionary(parse(mounts).map { ($0.mountPoint, $0.type) }, uniquingKeysWith: { first, _ in first })
        return DiskFreeParser.parseKilobytes(diskFree).filter(\.isExternal).map { volume in
            var volume = volume
            volume.fileSystemType = types[volume.mountPoint]
            return volume
        }
    }
}

/// The filtered `uci show samba4` lines: `samba4.@sambashare[0].name='Backups'`.
public enum SambaSharesParser {
    public static func parse(_ text: String) -> SambaStatus {
        if text.contains(SSHCommand.sambaNotConfiguredMarker) { return .notConfigured }
        var names: [Int: String] = [:]
        var readOnly: [Int: Observed<Bool>] = [:]
        var guest: [Int: Observed<Bool>] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: /^samba4\.@sambashare\[(\d+)\]\.(name|read_only|guest_ok)='?([^']*)'?\s*$/),
                  let index = Int(match.1) else { continue }
            let value = String(match.3)
            switch match.2 {
            case "name": names[index] = value
            case "read_only": readOnly[index] = flag(value)
            default: guest[index] = flag(value)
            }
        }
        return .configured(names.keys.sorted().compactMap { index in
            guard let name = names[index], !name.isEmpty else { return nil }
            return SambaShare(name: name, readOnly: readOnly[index] ?? .unknown, guestAccess: guest[index] ?? .unknown)
        })
    }

    private static func flag(_ value: String) -> Observed<Bool> {
        switch value.lowercased() {
        case "yes", "1", "true", "on": .value(true)
        case "no", "0", "false", "off": .value(false)
        default: .unknown
        }
    }
}

/// The `networkInterfaces` enumeration and the `interfaceTelemetry` reads.
public enum InterfaceParser {
    /// `name type hasDevice isWireless isBridge` per line. A name that is not
    /// a valid `NetworkInterfaceName` is dropped, so it can never reach a command.
    public static func parseEnumeration(_ text: String) -> [NetworkInterfaceEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count == 5, let name = NetworkInterfaceName(fields[0]) else { return nil }
            return NetworkInterfaceEntry(name: name, type: Int(fields[1]), hasDevice: fields[2] == "1",
                                         isWireless: fields[3] == "1", isBridge: fields[4] == "1")
        }
    }

    /// `name file value` per line, `-` for a file that could not be read.
    /// Ports keep the order of `names`; a name with no readable file at all
    /// is returned in `missing` (the interface went away).
    public static func parseTelemetry(_ text: String, names: [NetworkInterfaceName]) -> (status: RouterPortsStatus, missing: [NetworkInterfaceName]) {
        var values: [String: [String: String]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard fields.count == 3, fields[2] != "-" else { continue }
            values[fields[0], default: [:]][fields[1]] = fields[2].trimmingCharacters(in: .whitespaces)
        }
        var ports: [EthernetPortStatus] = []
        var missing: [NetworkInterfaceName] = []
        for name in names {
            guard let files = values[name.description], !files.isEmpty else { missing.append(name); continue }
            func counter(_ file: String) -> Int64? { files[file].flatMap { Int64($0) }.flatMap { $0 >= 0 ? $0 : nil } }
            let link: LinkState = switch files["operstate"]?.lowercased() {
            case "up"?: .up
            case "down"?, "lowerlayerdown"?, "notpresent"?, "dormant"?: .down
            default:
                switch files["carrier"] { case "1"?: .up; case "0"?: .down; default: .unknown }
            }
            let speed = files["speed"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            let duplex = files["duplex"].map { $0.lowercased() }.flatMap { $0 == "full" || $0 == "half" ? $0 : nil }
            ports.append(EthernetPortStatus(
                name: name.description, link: link, speedMbps: link == .up ? speed : nil, duplex: link == .up ? duplex : nil,
                rxBytes: counter("statistics/rx_bytes"), txBytes: counter("statistics/tx_bytes"),
                rxErrors: counter("statistics/rx_errors"), txErrors: counter("statistics/tx_errors"),
                rxDropped: counter("statistics/rx_dropped"), txDropped: counter("statistics/tx_dropped")))
        }
        return (RouterPortsStatus(ports: ports), missing)
    }
}

/// `pgrep -a AdGuardHome`: `4321 /usr/bin/AdGuardHome …`. Only the process
/// ID is kept; the rest of the command line is dropped unread.
public enum ProcessIDParser {
    /// "Not running" needs exit status 1 with nothing on stdout or stderr:
    /// a `pgrep` without `-a` also exits 1, but prints its usage.
    public static func adGuardProcessID(_ text: String, stderr: String = "", exitStatus: Int32) -> Observed<Int> {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1)
            if let first = fields.first, let pid = Int(first), pid > 0 { return .value(pid) }
        }
        // `pgrep` exits 1 with no output when nothing matches.
        let blank = (text + stderr).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return exitStatus == 1 && blank ? .unavailable : .unknown
    }
}
