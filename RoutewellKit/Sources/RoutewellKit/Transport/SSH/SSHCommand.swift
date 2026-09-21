import Foundation

/// A fixed, allow-listed remote command. The remote side is a shell, so this enum is
/// only safe because every rendered string is a constant: there is no interpolation
/// of any value (host, user, or otherwise) into the command text.
public enum SSHCommand: Sendable, Equatable {
    case uptime
    case dhcpLeases
    case diskUsage

    public var rendered: String {
        switch self {
        case .uptime: "uptime"
        case .dhcpLeases: "cat /tmp/dhcp.leases"
        case .diskUsage: "df -k"
        }
    }
}
