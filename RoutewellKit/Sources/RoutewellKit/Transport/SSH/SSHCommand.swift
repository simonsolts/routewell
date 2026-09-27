import Foundation

/// A dotted-decimal IPv4 address, validated and re-rendered from its four
/// octets, so its text is only digits and dots.
public struct IPv4Literal: Sendable, Hashable, CustomStringConvertible {
    public let octets: [UInt8]

    public init?(_ raw: String) {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let octet = UInt8(part) else { return nil }
            octets.append(octet)
        }
        self.octets = octets
    }

    public var description: String { octets.map(String.init).joined(separator: ".") }
}

/// A Linux network interface name read from the router's own enumeration
/// (`networkInterfaces`), never from user text. Only ASCII letters, digits,
/// `.`, `_`, and `-`, at most 15 characters (`IFNAMSIZ - 1`), and never a
/// leading `-` or a `.`/`..` path segment, so it is safe inside a
/// `/sys/class/net/<name>/` path.
public struct NetworkInterfaceName: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let description: String

    public init?(_ raw: String) {
        guard (1...15).contains(raw.utf8.count), raw != ".", raw != "..", !raw.hasPrefix("-") else { return nil }
        let allowed = raw.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122: true   // 0-9 A-Z a-z
            case 45, 46, 95: true                    // - . _
            default: false
            }
        }
        guard allowed else { return nil }
        description = raw
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

/// A fixed, allow-listed remote command. The remote side is a shell, so this
/// enum is only safe because every rendered string is a constant or a typed
/// value whose text is re-rendered from validated parts: an `IPv4Literal`
/// renders only digits and dots, a `MACAddress` only hex digits and colons,
/// a `NetworkInterfaceName` only letters, digits, `.`, `_`, and `-`.
/// No other value is ever interpolated into the command text, and there is
/// no case that takes a string.
public enum SSHCommand: Sendable, Hashable {
    case uptime
    case dhcpLeases
    case diskUsage
    /// RouterPilot's client ping: 3 packets, 2 s wait each
    /// (`RouterManager.Operations.cs:21-62`).
    case pingClient(IPv4Literal)
    /// RouterPilot's Wake-on-LAN: `etherwake` on `br-lan`, else `wol`, else a
    /// marker saying no tool is installed (`RouterManager.Operations.cs:64-105`).
    case wakeClient(MACAddress)
    /// Chunk 15: the SSH capability probe (`RouterInfoService.cs:38-97`).
    case systemBoard
    /// Chunk 15: the router log tail, always the last 250 lines
    /// (`RouterManager.RouterLogs.cs:5-6`).
    case logTail
    /// Chunk 15: the root filesystem in human units (`RouterInfoService.cs:344-479`).
    case rootFilesystem
    /// Chunk 15: the kernel mount table, for external storage types.
    case mountTable
    /// Chunk 15: Samba share names and flags only. The filter runs on the
    /// router, so share paths, users, and passwords never leave it.
    case sambaShares
    /// Chunk 15: one line per `/sys/class/net` entry: name, `type`, and
    /// whether it has a device, is wireless, or is a bridge.
    case networkInterfaces
    /// Chunk 15: the fixed per-interface reads for names that came from
    /// `networkInterfaces` (`RouterPortTelemetryService.cs:24-25`).
    case interfaceTelemetry([NetworkInterfaceName])
    /// Chunk 15: the AdGuard Home process ID. Only the first field is used.
    case adGuardProcess

    public static let wakeToolMissingMarker = "__WOL_TOOL_MISSING__"
    /// Printed when `samba4` has no configuration on the router.
    public static let sambaNotConfiguredMarker = "__SAMBA_NOT_CONFIGURED__"
    /// The per-interface files `interfaceTelemetry` reads, in output order.
    public static let interfaceFiles = [
        "operstate", "carrier", "speed", "duplex",
        "statistics/rx_bytes", "statistics/tx_bytes",
        "statistics/rx_errors", "statistics/tx_errors",
        "statistics/rx_dropped", "statistics/tx_dropped",
    ]

    public var rendered: String {
        switch self {
        case .uptime: "uptime"
        case .dhcpLeases: "cat /tmp/dhcp.leases"
        case .diskUsage: "df -k"
        case .pingClient(let address): "ping -c 3 -W 2 \(address)"
        case .wakeClient(let mac):
            "if command -v etherwake >/dev/null 2>&1; then etherwake -i br-lan \(mac.uppercaseColonSeparated) 2>&1; "
                + "elif command -v wol >/dev/null 2>&1; then wol \(mac.uppercaseColonSeparated) 2>&1; "
                + "else echo '\(Self.wakeToolMissingMarker)'; fi"
        case .systemBoard: "ubus call system board"
        case .logTail: "logread -l 250"
        case .rootFilesystem: "df -h /"
        case .mountTable: "cat /proc/mounts"
        case .sambaShares:
            "if uci -q show samba4 >/dev/null 2>&1; then "
                + "uci -q show samba4 | grep -E '^samba4\\.@sambashare\\[[0-9]+\\]\\.(name|read_only|guest_ok)='; true; "
                + "else echo '\(Self.sambaNotConfiguredMarker)'; fi"
        case .networkInterfaces:
            "for p in /sys/class/net/*; do n=${p##*/}; t=$(cat \"$p/type\" 2>/dev/null); "
                + "d=0; [ -e \"$p/device\" ] && d=1; w=0; { [ -e \"$p/wireless\" ] || [ -e \"$p/phy80211\" ]; } && w=1; "
                + "b=0; [ -e \"$p/bridge\" ] && b=1; echo \"$n ${t:--} $d $w $b\"; done"
        case .interfaceTelemetry(let names):
            // One short loop: Dropbear refuses an exec command longer than
            // its `MAX_CMD_LEN` (9000 bytes by default), and one `printf`
            // per file grew past that with 28 interfaces.
            "for i in \(names.map(\.description).joined(separator: " ")); do "
                + "for f in \(Self.interfaceFiles.joined(separator: " ")); do "
                + "printf '%s %s %s\\n' \"$i\" \"$f\" \"$(cat \"/sys/class/net/$i/$f\" 2>/dev/null || echo -)\"; done; done"
        case .adGuardProcess: "pgrep -a AdGuardHome"
        }
    }
}

extension MACAddress {
    /// `AA:BB:CC:DD:EE:FF`, the form `etherwake` and `wol` accept.
    var uppercaseColonSeparated: String { colonSeparated.uppercased() }
}
