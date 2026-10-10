import Foundation

// MARK: - System board

/// `ubus call system board`: `model`, `hostname`, `board_name`,
/// `release.version/kernel/target` `[verified in source: RouterInfoService.cs:38-97]`.
public struct SystemBoard: Sendable, Equatable {
    public var model: String?
    public var hostname: String?
    public var boardName: String?
    public var releaseVersion: String?
    public var kernel: String?
    public var target: String?

    public init(model: String? = nil, hostname: String? = nil, boardName: String? = nil,
                releaseVersion: String? = nil, kernel: String? = nil, target: String? = nil) {
        self.model = model
        self.hostname = hostname
        self.boardName = boardName
        self.releaseVersion = releaseVersion
        self.kernel = kernel
        self.target = target
    }
}

// MARK: - Ports

public enum LinkState: Sendable, Equatable, Hashable {
    case up, down, unknown
}

/// One `/sys/class/net` entry from the `networkInterfaces` enumeration.
public struct NetworkInterfaceEntry: Sendable, Equatable {
    public var name: NetworkInterfaceName
    /// `type` (1 is Ethernet, `ARPHRD_ETHER`).
    public var type: Int?
    public var hasDevice: Bool
    public var isWireless: Bool
    public var isBridge: Bool

    public init(name: NetworkInterfaceName, type: Int?, hasDevice: Bool, isWireless: Bool, isBridge: Bool) {
        self.name = name
        self.type = type
        self.hasDevice = hasDevice
        self.isWireless = isWireless
        self.isBridge = isBridge
    }

    /// A physical Ethernet port: Ethernet type, backed by a device, not a
    /// radio and not a bridge. On 4.9.1 this keeps `eth0`–`eth2` and
    /// `lan5`–`lan8`, and drops the VLAN `eth1.1`, the radios, `br-lan`,
    /// `lo`, and `pppoe-wan` `[verified live]`.
    public var isEthernetPort: Bool { type == 1 && hasDevice && !isWireless && !isBridge }
}

/// One Ethernet interface from the fixed `/sys/class/net/<iface>` reads.
/// Every value the router did not report stays `nil`.
public struct EthernetPortStatus: Sendable, Equatable {
    public var name: String
    public var link: LinkState
    /// `speed` in Mb/s; `nil` when the link is down (the kernel reports -1
    /// or refuses the read).
    public var speedMbps: Int?
    /// `full` or `half`, lower case, verbatim.
    public var duplex: String?
    public var rxBytes: Int64?
    public var txBytes: Int64?
    public var rxErrors: Int64?
    public var txErrors: Int64?
    public var rxDropped: Int64?
    public var txDropped: Int64?

    public init(name: String, link: LinkState = .unknown, speedMbps: Int? = nil, duplex: String? = nil,
                rxBytes: Int64? = nil, txBytes: Int64? = nil, rxErrors: Int64? = nil, txErrors: Int64? = nil,
                rxDropped: Int64? = nil, txDropped: Int64? = nil) {
        self.name = name
        self.link = link
        self.speedMbps = speedMbps
        self.duplex = duplex
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.rxErrors = rxErrors
        self.txErrors = txErrors
        self.rxDropped = rxDropped
        self.txDropped = txDropped
    }
}

public struct RouterPortsStatus: Sendable, Equatable {
    public var ports: [EthernetPortStatus]

    public init(ports: [EthernetPortStatus] = []) { self.ports = ports }
}

public struct LinkChange: Sendable, Equatable {
    public var interface: String
    public var from: LinkState
    public var to: LinkState
    public var at: Date

    public init(interface: String, from: LinkState, to: LinkState, at: Date) {
        self.interface = interface
        self.from = from
        self.to = to
        self.at = at
    }
}

/// Link changes seen while Routewell runs. Session-only by design: it is
/// not `Codable`, and a session switch starts a new one. The first reading
/// of an interface, and any reading that is unknown, is not a change.
public struct LinkChangeLog: Sendable, Equatable {
    public static let capacity = 100
    /// Oldest first, at most `capacity`.
    public private(set) var changes: [LinkChange] = []
    private var last: [String: LinkState] = [:]

    public init() {}

    public mutating func observe(_ status: RouterPortsStatus, at date: Date) {
        for port in status.ports where port.link != .unknown {
            if let previous = last[port.name], previous != port.link {
                changes.append(LinkChange(interface: port.name, from: previous, to: port.link, at: date))
            }
            last[port.name] = port.link
        }
        if changes.count > Self.capacity { changes.removeFirst(changes.count - Self.capacity) }
    }
}

// MARK: - Storage

/// `df -h /`, verbatim human sizes (`7.2G`) as the router prints them.
public struct RootFilesystem: Sendable, Equatable {
    public var filesystem: String?
    public var size: String
    public var used: String
    public var available: String
    public var usePercent: Int?
    public var mountPoint: String

    public init(filesystem: String? = nil, size: String, used: String, available: String, usePercent: Int?, mountPoint: String) {
        self.filesystem = filesystem
        self.size = size
        self.used = used
        self.available = available
        self.usePercent = usePercent
        self.mountPoint = mountPoint
    }
}

/// One `df -k` row, joined with `/proc/mounts` for its type.
public struct MountedVolume: Sendable, Equatable {
    public var device: String
    public var mountPoint: String
    public var fileSystemType: String?
    public var totalBytes: Int64?
    public var usedBytes: Int64?
    public var availableBytes: Int64?

    public init(device: String, mountPoint: String, fileSystemType: String? = nil,
                totalBytes: Int64? = nil, usedBytes: Int64? = nil, availableBytes: Int64? = nil) {
        self.device = device
        self.mountPoint = mountPoint
        self.fileSystemType = fileSystemType
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
    }

    /// A USB, SD, or NVMe block device mounted under `/mnt` or `/tmp/mountd`
    /// `[assumed]` for GL.iNet's automount.
    public var isExternal: Bool {
        let blockDevice = ["/dev/sd", "/dev/mmcblk", "/dev/nvme", "/dev/usb"].contains { device.hasPrefix($0) }
        let mounted = mountPoint.hasPrefix("/mnt/") || mountPoint.hasPrefix("/tmp/mountd/")
        return blockDevice && mounted
    }
}

/// One Samba share: its name and two flags. No path, user, or password is
/// ever read (the filter runs on the router).
public struct SambaShare: Sendable, Equatable {
    public var name: String
    public var readOnly: Observed<Bool>
    public var guestAccess: Observed<Bool>

    public init(name: String, readOnly: Observed<Bool> = .unknown, guestAccess: Observed<Bool> = .unknown) {
        self.name = name
        self.readOnly = readOnly
        self.guestAccess = guestAccess
    }
}

public enum SambaStatus: Sendable, Equatable {
    case notConfigured
    case configured([SambaShare])
}

/// Each part is read on its own; one failed read leaves only that part unknown.
public struct StorageStatus: Sendable, Equatable {
    public var root: Observed<RootFilesystem>
    public var external: Observed<[MountedVolume]>
    public var samba: Observed<SambaStatus>

    public init(root: Observed<RootFilesystem> = .unknown, external: Observed<[MountedVolume]> = .unknown,
                samba: Observed<SambaStatus> = .unknown) {
        self.root = root
        self.external = external
        self.samba = samba
    }
}

// MARK: - Logs

/// Syslog priorities, most severe first.
public enum RouterLogSeverity: Int, Sendable, Equatable, Comparable, CaseIterable {
    case emergency, alert, critical, error, warning, notice, info, debug

    /// `emerg`, `crit`, `err`, `warn`, … as `logread` prints them.
    public static func parse(_ token: String) -> RouterLogSeverity? {
        switch token.lowercased() {
        case "emerg", "panic": .emergency
        case "alert": .alert
        case "crit": .critical
        case "err", "error": .error
        case "warn", "warning": .warning
        case "notice": .notice
        case "info": .info
        case "debug": .debug
        default: nil
        }
    }

    public var label: String {
        switch self {
        case .emergency: "emerg"
        case .alert: "alert"
        case .critical: "crit"
        case .error: "err"
        case .warning: "warn"
        case .notice: "notice"
        case .info: "info"
        case .debug: "debug"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// RouterPilot's Logs categories, with the mockup's display names.
public enum RouterLogCategory: String, Sendable, Equatable, CaseIterable {
    case system = "System"
    case networkWAN = "Network / WAN"
    case dhcpDNS = "DHCP / DNS"
    case wifi = "Wi-Fi"
    case firewall = "Firewall"
    case vpn = "VPN"
    case adGuard = "AdGuard"
    case storage = "Storage"
    case kernel = "Kernel"
}

/// RouterPilot's grouped Severity pop-up. "Info" and "Debug" are bands, not
/// thresholds: Info is notice and info, Debug is debug only.
public enum RouterLogSeverityFilter: String, Sendable, Equatable, CaseIterable {
    case all = "All"
    case errorAndAbove = "Error+"
    case warningAndAbove = "Warning+"
    case info = "Info"
    case debug = "Debug"

    public func matches(_ severity: RouterLogSeverity?) -> Bool {
        switch self {
        case .all: return true
        case .errorAndAbove: return severity.map { $0 <= .error } ?? false
        case .warningAndAbove: return severity.map { $0 <= .warning } ?? false
        case .info: return severity == .notice || severity == .info
        case .debug: return severity == .debug
        }
    }
}

/// One `logread` line. `line` is the raw text after the timestamp, shown
/// as-is on screen.
public struct RouterLogEntry: Sendable, Equatable, Identifiable {
    /// Position in the tail, newest first, so it is unique within one read.
    public var id: Int
    public var time: Date?
    public var facility: String?
    public var severity: RouterLogSeverity?
    public var source: String
    public var category: RouterLogCategory
    /// The text after the program tag.
    public var message: String
    public var line: String

    public init(id: Int, time: Date?, facility: String?, severity: RouterLogSeverity?, source: String,
                category: RouterLogCategory, message: String, line: String) {
        self.id = id
        self.time = time
        self.facility = facility
        self.severity = severity
        self.source = source
        self.category = category
        self.message = message
        self.line = line
    }

    /// `user.err`, or the part the router reported.
    public var facilityPriority: String? {
        switch (facility, severity) {
        case let (facility?, severity?): "\(facility).\(severity.label)"
        case let (nil, severity?): severity.label
        case let (facility?, nil): facility
        case (nil, nil): nil
        }
    }

    /// Case-insensitive match on the raw line, source, and category.
    public func matches(search: String) -> Bool {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return true }
        return line.localizedCaseInsensitiveContains(term) || source.localizedCaseInsensitiveContains(term)
            || category.rawValue.localizedCaseInsensitiveContains(term)
    }
}

/// The last `limit` router log lines, newest first.
public struct RouterLogTail: Sendable, Equatable {
    public static let limit = 250
    public var entries: [RouterLogEntry]

    public init(entries: [RouterLogEntry] = []) { self.entries = Array(entries.prefix(Self.limit)) }

    public func filtered(severity: RouterLogSeverityFilter, category: RouterLogCategory?, search: String) -> [RouterLogEntry] {
        entries.filter { entry in
            severity.matches(entry.severity) && (category == nil || entry.category == category) && entry.matches(search: search)
        }
    }
}
