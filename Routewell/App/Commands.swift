import SwiftUI

struct RoutewellCommands: Commands {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .newItem) {
            Button("Export Logs…") {}.disabled(true)
            Button("Back Up Router…") {}.disabled(true)
        }
        CommandGroup(after: .sidebar) {
            ForEach(SidebarDestination.allCases) { destination in
                if let shortcut = destination.shortcut {
                    Button(destination.title) { select(destination) }
                        .keyboardShortcut(shortcut, modifiers: .command)
                } else {
                    Button(destination.title) { select(destination) }
                }
            }
            Divider()
            Button("Show Inspector") {}.disabled(true)
            Button(environment.model.showStatusBar ? "Hide Status Bar" : "Show Status Bar") {
                environment.model.showStatusBar.toggle()
            }
            .disabled(![.clients, .logs].contains(environment.model.selection))
            Button("Refresh") { environment.refresh.refreshNow() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!environment.refresh.isAvailable || environment.model.isRefreshing)
        }
        CommandMenu("Router") {
            Button("Restart Wi-Fi") {}.disabled(true)
            Button("Restart AdGuard Home") {}.disabled(true)
            Button("Reconnect WAN") {}.disabled(true)
            Button("Reboot Router…") {}.disabled(true)
            Divider()
            Button("Enable Protection") {}.disabled(true)
            Menu("Pause Protection") {
                Button("30 Minutes") {}.disabled(true)
            }.disabled(true)
            Divider()
            Button("Open Router UI") {}.disabled(true)
            Button("Open AdGuard Home UI") {}.disabled(true)
        }
    }

    private func select(_ destination: SidebarDestination) {
        environment.model.selection = destination
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
