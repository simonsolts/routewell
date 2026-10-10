import Foundation

public struct AreaCadence: Sendable, Equatable {
    public let area: DataArea
    public let interval: Duration

    public init(_ area: DataArea, every interval: Duration = .seconds(30)) {
        self.area = area
        self.interval = interval
    }
}

/// The shell passes a destination and segment identifier. Unbuilt segments
/// request no feature area, while the four Overview areas remain global.
public enum ScreenRefreshPlan {
    public static let overviewAreas: Set<DataArea> = [.router, .internet, .adGuard, .clients]

    public static func resolve(destination: String, segment: String? = nil,
                               defaultInterval: Duration = .seconds(30)) -> [AreaCadence] {
        var intervals = Dictionary(uniqueKeysWithValues: overviewAreas.map { ($0, defaultInterval) })
        let area: DataArea? = switch destination {
        case "clients": .clients
        case "network": .network
        case "maintenance": .maintenance
        case "vpn": .vpn
        case "applications": .plugins
        case "analytics": .telemetry
        case "router": .routerDetail
        default: nil
        }
        if let area { intervals[area] = defaultInterval }
        if destination == "analytics", segment == "Overview" { intervals[.telemetry] = .seconds(2) }
        if destination == "network", segment == "Overview" { intervals[.publicIP] = .seconds(600) }
        // Chunk 15: SSH reads for the segments that need them. Logs reads
        // only on demand; the refresh loop skips it on timed ticks.
        if destination == "router", let segment, ["Overview", "Ports", "Storage", "Logs"].contains(segment) {
            intervals[.ssh] = defaultInterval
        }
        // Chunk 17: the Overview tab's stats, switches, and blocklists.
        // Chunk 18: the Query Log needs the blocklist names for its Reason.
        // The Instance tab: the update check, retention, memory, and log size.
        if destination == "adGuard", segment == nil || ["Overview", "Query Log", "Filters", "DNS", "Instance"].contains(segment) {
            intervals[.adGuardOverview] = defaultInterval
        }
        if destination == "adGuard", segment == "Instance" { intervals[.ssh] = defaultInterval }
        return intervals.map { AreaCadence($0.key, every: $0.value) }.sorted { $0.area.rawValue < $1.area.rawValue }
    }
}
