import SwiftUI

struct MenuBarExtraView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.mode == .mock ? "Routewell · Mock data" : "Routewell · Not connected")
        Divider()
        Text("Router: \(model.snapshot?.router.reachability.label ?? "Unknown")")
        Text("Internet: \(model.snapshot?.internet.reachability.label ?? "Unknown")")
        Text("AdGuard Home: \(model.snapshot?.adGuard.reachability.label ?? "Unknown")")
        Text("VPN: Unknown")
        Divider()
        Button("Open Routewell") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut("o", modifiers: .command)
        Button("Settings…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Routewell") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
