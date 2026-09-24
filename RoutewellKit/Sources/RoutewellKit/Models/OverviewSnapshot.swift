import Foundation

public enum Reachability: Sendable, Equatable {
    case connected, unreachable, unknown
}

public enum Observed<Value: Sendable & Equatable>: Sendable, Equatable {
    case value(Value)
    case unavailable
    case unknown
}

public enum ProtectionState: Sendable, Equatable {
    case enabled, disabled, paused(until: Date), unknown
}

public struct RouterStatus: Sendable, Equatable {
    public var reachability: Reachability = .unknown
    public var hostname: String?
    public var model: String?
    public var firmware: String?
    public var openWrtVersion: String?
    public var lanAddress: String?
    public var uptimeSeconds: Int?
    public var loadAverages: [Double] = []
    public var memoryUsedBytes: Int64?
    public var memoryTotalBytes: Int64?
    public var memoryHistory: [Double] = []
    public var temperatureCelsius: Observed<Double> = .unknown
    /// Chunk 14, from the same two reads. `board_info.kernel_version` and
    /// `board_info.architecture` `[verified live]`.
    public var kernelVersion: String?
    public var architecture: String?
    /// `system.memory_free` and `system.memory_buff_cache` `[verified live]`.
    /// The router reports buffers and cache as one number.
    public var memoryFreeBytes: Int64?
    public var memoryBuffersAndCacheBytes: Int64?
    /// `system.flash_total` and `system.flash_free` `[verified live]`.
    public var storageTotalBytes: Int64?
    public var storageFreeBytes: Int64?
    /// The router's clock, `system.timestamp` `[verified live]`.
    public var routerTime: Date?
    /// No RPC field reports CPU utilization; live stays unknown and load
    /// averages are never converted into a percentage.
    public var cpuUtilizationPercent: Observed<Double> = .unknown
    /// `system.sqm_enabled` `[verified live]`: the legacy read-only flag.
    public var sqmEnabled: Observed<Bool> = .unknown
    public init() {}

    /// Free memory plus buffers and cache, which the kernel can reclaim.
    public var memoryAvailableBytes: Int64? {
        guard let memoryFreeBytes else { return nil }
        return memoryFreeBytes + (memoryBuffersAndCacheBytes ?? 0)
    }

    public var storageUsedBytes: Int64? {
        guard let storageTotalBytes, let storageFreeBytes, storageTotalBytes >= storageFreeBytes else { return nil }
        return storageTotalBytes - storageFreeBytes
    }

    /// The router's clock minus its uptime, so a wrong Mac clock does not move it.
    public var lastBoot: Date? {
        guard let routerTime, let uptimeSeconds else { return nil }
        return routerTime.addingTimeInterval(-TimeInterval(uptimeSeconds))
    }
}

/// One entry of `system get_status` `network[]`: the router's uplink
/// interfaces (`wan`, `wwan`, `tethering`, modems in the public client).
public struct UplinkInterface: Sendable, Equatable {
    public var name: String
    public var up: Observed<Bool>
    public var online: Observed<Bool>

    public init(name: String, up: Observed<Bool> = .unknown, online: Observed<Bool> = .unknown) {
        self.name = name
        self.up = up
        self.online = online
    }
}

public struct InternetStatus: Sendable, Equatable {
    public var reachability: Reachability = .unknown
    public var publicAddress: String?
    public var gateway: String?
    public var gatewayLatencyMilliseconds: Double?
    public var dnsServers: [String] = []
    /// `cable get_status` `protocol` `[verified live]`, for example `dhcp`.
    public var wanProtocol: String?
    public var uplinks: [UplinkInterface] = []
    public init() {}
}

public struct AdGuardStatus: Sendable, Equatable {
    public var reachability: Reachability = .unknown
    public var version: String?
    public var protection: ProtectionState = .unknown
    public var queriesToday: Int?
    public var blockedToday: Int?
    /// `control/status` `running` and `dns_port` `[verified live]`.
    public var running: Observed<Bool> = .unknown
    public var dnsPort: Int?
    /// `adguardhome get_config` `dns_enabled` `[verified live]` key. Its
    /// meaning, the router UI's "Handle client requests", is `[assumed]`.
    public var handlesClientRequests: Observed<Bool> = .unknown
    public init() {}
}

public struct ClientStatus: Sendable, Equatable {
    public var activeCount: Observed<Int> = .unknown
    /// Each listed client's online flag, keyed by MAC. `nil` when the full
    /// list was not read (only totals), so no presence sample is taken.
    public var listed: [MACAddress: Observed<Bool>]?
    /// Online Wi-Fi clients per band, from the list's `iface` tokens. `nil`
    /// when the full list was not read.
    public var onlineByBand: [WirelessBand: Int]?
    public init() {}
}

public struct OverviewSnapshot: Sendable, Equatable {
    public var router: RouterStatus
    public var internet: InternetStatus
    public var adGuard: AdGuardStatus
    public var clients: ClientStatus
    public var observedAt: Date

    public init(
        router: RouterStatus = .init(),
        internet: InternetStatus = .init(),
        adGuard: AdGuardStatus = .init(),
        clients: ClientStatus = .init(),
        observedAt: Date
    ) {
        self.router = router
        self.internet = internet
        self.adGuard = adGuard
        self.clients = clients
        self.observedAt = observedAt
    }
}
