import SwiftUI

struct DetailRouter: View {
    let destination: SidebarDestination
    var body: some View {
        switch destination {
        case .overview: OverviewScreen()
        case .protection: ProtectionScreen()
        case .analytics: AnalyticsScreen()
        case .network: NetworkScreen()
        case .router: RouterScreen()
        case .vpn: VPNScreen()
        case .applications: ApplicationsScreen()
        case .maintenance: MaintenanceScreen()
        case .clients: ClientsScreen()
        case .dnsActivity: DNSActivityScreen()
        case .notifications: NotificationsScreen()
        case .logs: LogsScreen()
        }
    }
}

struct PlaceholderScreen: View {
    let destination: SidebarDestination
    @Environment(AppModel.self) private var model
    var body: some View {
        ContentUnavailableView {
            Label(model.subpages[destination] ?? destination.title, systemImage: destination.symbol)
        } description: {
            Text("This feature is not available yet.")
        }
    }
}
