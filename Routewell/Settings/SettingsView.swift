import SwiftUI
import RoutewellKit

/// The Settings tabs (chunk 15B). The raw value is the tab's title.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case router = "Router"
    case notifications = "Notifications"
    case advanced = "Advanced"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .router: "wifi.router"
        case .notifications: "bell"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

struct SettingsView: View {
    let environment: AppEnvironment
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettingsTab()
                .tabItem { Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general)
            routerTab
                .tabItem { Label(SettingsTab.router.rawValue, systemImage: SettingsTab.router.symbol) }
                .tag(SettingsTab.router)
            NotificationsSettingsTab()
                .tabItem { Label(SettingsTab.notifications.rawValue, systemImage: SettingsTab.notifications.symbol) }
                .tag(SettingsTab.notifications)
            AdvancedSettingsTab()
                .tabItem { Label(SettingsTab.advanced.rawValue, systemImage: SettingsTab.advanced.symbol) }
                .tag(SettingsTab.advanced)
        }
        .disabled(environment.persistence.isLoading || environment.persistence.credentialBusy)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(environment.persistence.status)
                        .foregroundStyle(environment.persistence.errors.isEmpty ? Color.secondary : Color.red)
                    Spacer()
                    if !environment.persistence.errors.isEmpty {
                        Button("Retry Save") { Task { await environment.persistence.flush() } }
                    }
                }
                if let notice = environment.persistence.recoveryNotice { Text(notice).foregroundStyle(.orange) }
            }.font(.caption).padding(12)
        }
        .formStyle(.grouped)
        .frame(width: 680, height: 640)
    }

    /// A new profile (Start Setup Again, a mock profile switch) gets a new
    /// tab model: fresh drafts and no test results.
    @ViewBuilder private var routerTab: some View {
        if let services = Self.services(environment) {
            RouterSettingsTab(environment: environment, services: services, app: model)
                .id(environment.persistence.profiles.selectedID)
        } else {
            NoRouterSettingsTab()
        }
    }

    /// Live mode with a finished router, or mock mode with a mock profile.
    static func services(_ environment: AppEnvironment) -> (any RouterSettingsServices)? {
        guard let profile = environment.persistence.selectedProfile else { return nil }
        #if DEBUG
        if environment.model.mode == .mock { return environment.mockRouterSettings }
        #endif
        guard environment.model.mode == .live, profile.liveEndpoint != nil, profile.setupComplete else { return nil }
        return environment.liveRouterSettings
    }
}

/// No router on this Mac yet: onboarding is open.
private struct NoRouterSettingsTab: View {
    var body: some View {
        ContentUnavailableView("No Router", systemImage: "wifi.router",
                               description: Text("Finish setting up a router to see its settings here."))
    }
}
