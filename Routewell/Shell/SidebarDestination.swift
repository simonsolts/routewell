import SwiftUI

enum SidebarGroup: String, CaseIterable { case monitoring = "Monitoring", operations = "Operations" }

enum SidebarDestination: String, CaseIterable, Identifiable {
    case overview, router, network, clients, adGuard, analytics
    case maintenance, notifications, applications, vpn, logs

    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .router: "Router"
        case .network: "Network"
        case .clients: "Clients"
        case .adGuard: "AdGuard Home"
        case .analytics: "Analytics"
        case .maintenance: "Maintenance"
        case .notifications: "Notifications"
        case .applications: "Applications"
        case .vpn: "VPN"
        case .logs: "Logs"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .router: "wifi.router"
        case .network: "globe"
        case .clients: "person.2"
        case .adGuard: "shield"
        case .analytics: "chart.bar"
        case .maintenance: "wrench.and.screwdriver"
        case .notifications: "bell"
        case .applications: "square.grid.2x2"
        case .vpn: "key"
        case .logs: "doc.text"
        }
    }
    var group: SidebarGroup {
        switch self {
        case .overview, .router, .network, .clients, .adGuard, .analytics: .monitoring
        default: .operations
        }
    }
    var shortcut: KeyEquivalent? {
        guard let index = Self.allCases.firstIndex(of: self), index < 9 else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }
    var segments: [String] {
        switch self {
        case .adGuard: AdGuardTab.allCases.map(\.rawValue)
        case .analytics: ["Overview", "Data", "DNS"]
        case .network: ["Overview", "Map", "Wi-Fi", "DHCP", "Ports", "Health", "Quality"]
        case .router: RouterSegment.allCases.map(\.rawValue)
        case .maintenance: ["Operations", "Health", "Snapshots", "Reports", "Support"]
        case .clients: ["All Clients", "Known Clients"]
        default: []
        }
    }
    /// Clients shows its count above the table; Router has ten segments and
    /// no subtitle in any mockup. AdGuard Home shows the router model.
    var showsSubtitle: Bool { self != .clients && self != .router }
}

/// The AdGuard Home screen's tabs (design/adguard-home.md).
enum AdGuardTab: String, CaseIterable {
    case overview = "Overview"
    case queryLog = "Query Log"
    case filters = "Filters"
    case dns = "DNS"
    case instance = "Instance"
}
