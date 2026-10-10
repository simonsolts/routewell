import SwiftUI

@main
struct RoutewellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var environment = AppEnvironment.configured(persist: ProcessInfo.processInfo.environment["ROUTEWELL_TESTING"] != "1")

    var body: some Scene {
        @Bindable var model = environment.model
        Window("Routewell", id: "main") {
            MainWindow(environment: environment, delegate: delegate)
                .environment(model)
                .environment(environment)
                .onAppear {
                    delegate.persistence = environment.persistence
                    delegate.clients = environment.clients
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(environment.launchShowsOnboarding ? .suppressed : .presented)
        .commands { RoutewellCommands(environment: environment) }

        // First run: the main window opens at Finish.
        Window("Set Up Routewell", id: "onboarding") {
            OnboardingWindow(environment: environment, delegate: delegate)
                .environment(model)
                .onAppear {
                    delegate.persistence = environment.persistence
                    delegate.clients = environment.clients
                }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(environment.launchShowsOnboarding ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(environment: environment).environment(model)
        }

        MenuBarExtra("Routewell", systemImage: "wifi.router", isInserted: $model.showInMenuBar) {
            MenuBarExtraView().environment(model)
        }
        .menuBarExtraStyle(.menu)
    }
}
