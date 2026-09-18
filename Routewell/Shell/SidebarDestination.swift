import SwiftUI

enum SidebarGroup: String, CaseIterable { case monitoring = "Monitoring", operations = "Operations" }

enum SidebarDestination: String, CaseIterable, Identifiable {
    case overview, protection, analytics, network, router, vpn, applications
    case maintenance, clients, dnsActivity, notifications, logs

    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .protection: "Protection"
        case .analytics: "Analytics"
        case .network: "Network"
        case .router: "Router"
        case .vpn: "VPN"
        case .applications: "Applications"
        case .maintenance: "Maintenance"
        case .clients: "Clients"
        case .dnsActivity: "DNS Activity"
        case .notifications: "Notifications"
        case .logs: "Logs"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .protection: "shield"
        case .analytics: "chart.bar"
        case .network: "globe"
        case .router: "wifi.router"
        case .vpn: "key"
        case .applications: "square.grid.2x2"
        case .maintenance: "wrench.and.screwdriver"
        case .clients: "person.2"
        case .dnsActivity: "list.bullet"
        case .notifications: "bell"
        case .logs: "doc.text"
        }
    }
    var group: SidebarGroup {
        switch self {
        case .maintenance, .clients, .dnsActivity, .notifications, .logs: .operations
        default: .monitoring
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
        case .maintenance: ["Operations", "Health", "Snapshots", "Reports", "Support"]
        default: []
        }
    }
    var showsStatusPill: Bool { segments.count < 5 }
}
