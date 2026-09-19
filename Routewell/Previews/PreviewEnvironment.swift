#if DEBUG
import SwiftUI
import RoutewellKit
import RoutewellMock

@MainActor
private func previewEnvironment(scenario: MockRouterBackend.Scenario = .healthy) -> AppEnvironment {
    AppEnvironment(
        model: AppModel(mode: .mock, snapshot: MockRouterBackend.snapshot(at: .now)),
        backend: MockRouterBackend(scenario: scenario)
    )
}

#Preview("Overview") {
    let environment = previewEnvironment()
    MainWindow(environment: environment).environment(environment.model)
}

#Preview("Unknown observations") {
    OverviewScreen()
        .environment(AppModel(mode: .mock, snapshot: OverviewSnapshot(observedAt: .now)))
        .frame(width: 980, height: 700)
}

#Preview("Settings") {
    let environment = previewEnvironment()
    SettingsView(environment: environment).environment(environment.model)
}
#endif
