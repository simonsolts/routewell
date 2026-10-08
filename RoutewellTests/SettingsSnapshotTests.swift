import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

/// Writes PNGs of the Settings tabs and the Router tab's mock scenarios,
/// light and dark, to the test host's temporary folder (`settings-snapshots`)
/// when `ROUTEWELL_SNAPSHOTS=1`. For reviewing the layout; it checks nothing else.
@MainActor @Test func writeSettingsSnapshotsWhenAsked() async throws {
    guard ProcessInfo.processInfo.environment["ROUTEWELL_SNAPSHOTS"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let environment = AppEnvironment(model: AppModel(mode: .mock), backend: MockRouterBackend())
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    let services = environment.mockRouterSettings
    services.delay = .zero

    func write(_ name: String, height: CGFloat = 1500, _ view: some View) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: view.environment(environment.model).formStyle(.grouped))
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(x: 0, y: 0, width: 680, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let file = "\(name)-\(appearance == .aqua ? "light" : "dark").png"
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(file))
        }
    }

    for tab in SettingsTab.allCases {
        environment.model.settingsTab = tab
        write("tab-\(tab.rawValue.lowercased())", height: 640, SettingsView(environment: environment))
    }

    func router(_ setUp: (RouterSettingsModel) async -> Void) async -> some View {
        let model = RouterSettingsModel(services: services, app: environment.model)
        await model.load()
        await setUp(model)
        return RouterSettingsTab(environment: environment, model: model)
    }

    write("router-default", await router { _ in })
    write("router-tested", await router { model in
        model.runTest()
        await model.settleTest()
    })
    write("router-password-edit", await router { $0.beginPasswordChange() })
    services.adGuardOffOnRouter = true
    write("router-adguard-off-open", await router { $0.adGuardExpanded = true })
    write("router-adguard-off-closed", await router { _ in })
    services.adGuardOffOnRouter = false
    services.testFails = true
    write("router-test-fails", await router { model in
        model.runTest()
        await model.settleTest()
    })
    services.testFails = false
    services.certificateTrusted = false
    services.hostKeyTrusted = false
    write("router-not-trusted", await router { _ in })
    services.certificateTrusted = true
    services.hostKeyTrusted = true
    environment.setMockSSHScenario(.off)
    write("router-ssh-off", await router { _ in })
    environment.setMockSSHScenario(.populated)
    services.mockSectionExpanded = true
    write("router-mock-open", height: 2600, await router { _ in })
    services.mockSectionExpanded = false
}
