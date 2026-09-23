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

/// A fixed, allow-listed remote command. The remote side is a shell, so this
/// enum is only safe because every rendered string is a constant or a typed
/// value whose text is re-rendered from validated parts: an `IPv4Literal`
/// renders only digits and dots, a `MACAddress` only hex digits and colons.
/// No other value is ever interpolated into the command text.
public enum SSHCommand: Sendable, Equatable {
    case uptime
    case dhcpLeases
    case diskUsage
    /// RouterPilot's client ping: 3 packets, 2 s wait each
    /// (`RouterManager.Operations.cs:21-62`).
    case pingClient(IPv4Literal)
    /// RouterPilot's Wake-on-LAN: `etherwake` on `br-lan`, else `wol`, else a
    /// marker saying no tool is installed (`RouterManager.Operations.cs:64-105`).
    case wakeClient(MACAddress)

    public static let wakeToolMissingMarker = "__WOL_TOOL_MISSING__"

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
        }
    }
}

extension MACAddress {
    /// `AA:BB:CC:DD:EE:FF`, the form `etherwake` and `wol` accept.
    var uppercaseColonSeparated: String { colonSeparated.uppercased() }
}
