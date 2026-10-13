import Foundation

// MARK: - SQM

/// `sqm get_config`: `enable`, `qdisc`, `upload`, `download`
/// keys. On 4.9.1 `upload` and `download` are strings, empty when unset;
/// they stay verbatim because their unit is not known.
public struct SQMConfiguration: Sendable, Equatable {
    public var enabled: Observed<Bool>
    public var queueDiscipline: String?
    public var upload: String?
    public var download: String?

    public init(enabled: Observed<Bool> = .unknown, queueDiscipline: String? = nil, upload: String? = nil, download: String? = nil) {
        self.enabled = enabled
        self.queueDiscipline = queueDiscipline
        self.upload = upload
        self.download = download
    }
}

// MARK: - Firmware

public enum FirmwareCheckFailure: Sendable, Equatable {
    /// `-32601`: this firmware has no online check.
    case notSupported
    /// The reply said neither "available" nor "current". Never read as up to date.
    case ambiguousReply
    case failed(RefreshFailureCategory)
}

public enum FirmwareUpdateStatus: Sendable, Equatable {
    case upToDate, updateAvailable
    case unableToCheck(FirmwareCheckFailure)
}

/// One `upgrade check_firmware_online` result. 4.9.1 with no update sends
/// only `current_version`, not `new_firmware_version`, `update_available`,
/// or `release_note(s)`.
public struct FirmwareCheck: Sendable, Equatable {
    public var current: Observed<String>
    public var latest: Observed<String>
    public var status: FirmwareUpdateStatus
    public var releaseNotes: String?
    public var checkedAt: Date

    public init(current: Observed<String> = .unknown, latest: Observed<String> = .unknown, status: FirmwareUpdateStatus,
                releaseNotes: String? = nil, checkedAt: Date) {
        self.current = current
        self.latest = latest
        self.status = status
        self.releaseNotes = releaseNotes
        self.checkedAt = checkedAt
    }
}

// MARK: - Multi-WAN

public enum WANConnectionType: Sendable, Equatable {
    /// The interface `cable get_status` describes (`wan`).
    case ethernet
    case unknown
}

public struct WANInterfaceStatus: Sendable, Equatable {
    public var name: String
    /// `network[].up`.
    public var up: Observed<Bool>
    public var connection: WANConnectionType
    public var address: String?
    /// No RPC field reports these; they stay unknown.
    public var active: Observed<Bool> = .unknown
    public var isDefault: Observed<Bool> = .unknown
    public var metric: Observed<Int> = .unknown
}

public struct WANPath: Sendable, Equatable {
    public var interface: String
    public var gateway: String
}

/// Honest Multi-WAN state. RouterPilot hardcodes mode and capability as
/// unknown too; no RPC reports Multi-WAN mode, policy, or failover.
public struct MultiWANStatus: Sendable, Equatable {
    public var interfaces: [WANInterfaceStatus]
    /// The `wan` interface and its gateway, only when `cable get_status`
    /// gave a gateway and `wan` is the one interface reported up.
    public var activePath: WANPath?

    public static func derive(from internet: InternetStatus) -> MultiWANStatus {
        let interfaces = internet.uplinks.map { uplink in
            let isCable = uplink.name == "wan"
            return WANInterfaceStatus(name: uplink.name, up: uplink.up,
                                      connection: isCable ? .ethernet : .unknown,
                                      address: isCable ? internet.publicAddress : nil)
        }
        let upNames = internet.uplinks.filter { $0.up == .value(true) }.map(\.name)
        var path: WANPath?
        if upNames == ["wan"], let gateway = internet.gateway { path = WANPath(interface: "wan", gateway: gateway) }
        return MultiWANStatus(interfaces: interfaces, activePath: path)
    }
}

/// Counts changes of the active path while Routewell runs. Session-only:
/// the first observation, or one after an unknown path, is not a change.
public struct WANPathTracker: Sendable, Equatable {
    public private(set) var changes: [Date] = []
    private var last: WANPath?

    public init() {}

    public mutating func observe(_ status: MultiWANStatus, at date: Date) {
        guard let path = status.activePath else { return }
        if let last, last != path { changes.append(date) }
        last = path
        if changes.count > 100 { changes.removeFirst(changes.count - 100) }
    }
}

// MARK: - DNS

/// Where client DNS goes, from what the router and AdGuard Home report.
/// Mode and encrypted DNS are not reported over RPC and stay unknown.
public struct DNSConfiguration: Sendable, Equatable {
    public enum Path: Sendable, Equatable { case throughAdGuard, direct }

    public var upstreams: [String]
    public var advertisedResolver: String?
    public var adGuardRunning: Observed<Bool>
    public var adGuardPort: Int?
    public var handlesClientRequests: Observed<Bool>
    public var resolutionPath: Observed<Path>

    public static func derive(router: RouterStatus, internet: InternetStatus, adGuard: AdGuardStatus) -> DNSConfiguration {
        let path: Observed<Path> = switch (adGuard.handlesClientRequests, adGuard.running) {
        case (.value(true), .value(true)): .value(.throughAdGuard)
        case (.value(false), _): .value(.direct)
        default: .unknown
        }
        return DNSConfiguration(upstreams: internet.dnsServers, advertisedResolver: router.lanAddress,
                                adGuardRunning: adGuard.running, adGuardPort: adGuard.dnsPort,
                                handlesClientRequests: adGuard.handlesClientRequests, resolutionPath: path)
    }
}
