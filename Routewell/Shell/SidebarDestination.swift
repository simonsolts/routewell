import SwiftUI

enum SidebarGroup: String, CaseIterable { case monitoring = "Monitoring", operations = "Operations" }

enum SidebarDestination: String, CaseIterable, Identifiable {
    case overview, router, network, clients, protection, analytics
    case maintenance, notifications, applications, dnsActivity, vpn, logs

    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .router: "Router"
        case .network: "Network"
        case .clients: "Clients"
        case .protection: "Protection"
        case .analytics: "Analytics"
        case .maintenance: "Maintenance"
        case .notifications: "Notifications"
        case .applications: "Applications"
        case .dnsActivity: "DNS Activity"
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
        case .protection: "shield"
        case .analytics: "chart.bar"
        case .maintenance: "wrench.and.screwdriver"
        case .notifications: "bell"
        case .applications: "square.grid.2x2"
        case .dnsActivity: "list.bullet"
        case .vpn: "key"
        case .logs: "doc.text"
        }
    }
    var group: SidebarGroup {
        switch self {
        case .overview, .router, .network, .clients, .protection, .analytics: .monitoring
        default: .operations
        }
    }
    var shortcut: KeyEquivalent? {
        guard let index = Self.allCases.firstIndex(of: self), index < 9 else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }
    var segments: [String] {
        switch self {
        case .protection: ["Protection", "Insights", "Filters", "Blocklists", "Services", "Schedules"]
        case .analytics: ["Overview", "Data", "DNS"]
        case .network: ["Overview", "Map", "Wi-Fi", "DHCP", "Ports", "Health", "Quality"]
        case .router: RouterSegment.allCases.map(\.rawValue)
        case .maintenance: ["Operations", "Health", "Snapshots", "Reports", "Support"]
        case .clients: ["All Clients", "Known Clients"]
        default: []
        }
    }
    /// Clients shows its count above the table; Router has ten segments and
    /// no subtitle in any mockup.
    var showsSubtitle: Bool { self != .clients && self != .router }
}
