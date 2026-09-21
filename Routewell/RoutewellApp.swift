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
                .onAppear { delegate.persistence = environment.persistence }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands { RoutewellCommands(environment: environment) }

        Settings {
            SettingsView(environment: environment).environment(model)
        }

        MenuBarExtra("Routewell", systemImage: "wifi.router", isInserted: $model.showInMenuBar) {
            MenuBarExtraView().environment(model)
        }
        .menuBarExtraStyle(.menu)
    }
}
