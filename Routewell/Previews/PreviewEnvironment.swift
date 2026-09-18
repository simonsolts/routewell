#if DEBUG
import SwiftUI
import RoutewellMock

@MainActor
private func previewEnvironment(scenario: MockRouterBackend.Scenario = .healthy) -> AppEnvironment {
    AppEnvironment(
        model: AppModel(mode: .mock, snapshot: MockRouterBackend.snapshot(scenario: scenario, at: .now)),
        backend: MockRouterBackend(scenario: scenario)
    )
}

#Preview("Overview") {
    let environment = previewEnvironment()
    MainWindow(environment: environment).environment(environment.model)
}

#Preview("Unknown observations") {
    let environment = previewEnvironment(scenario: .unknown)
    OverviewScreen().environment(environment.model).frame(width: 980, height: 700)
}

#Preview("Settings") {
    SettingsView().environment(AppModel(mode: .mock))
}
#endif
