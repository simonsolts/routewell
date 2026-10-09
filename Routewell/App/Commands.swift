import SwiftUI
import RoutewellKit

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
            .disabled(environment.model.selection != .logs)
            Button("Refresh") { environment.refresh.refreshFromPerson() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!environment.refresh.isAvailable || environment.model.isRefreshing)
        }
        CommandMenu("Router") {
            Button("Restart Wi-Fi") {}.disabled(true)
            Button("Restart AdGuard Home") {}.disabled(true)
            Button("Reconnect WAN") {}.disabled(true)
            Button("Reboot Router…") {}.disabled(true)
            Divider()
            // Chunk 17: the same writes and items as the Overview banner.
            Button("Enable Protection") { environment.adGuard.runSetting(.protection(.enable)) }
                .disabled(!canWriteProtection || environment.adGuard.protection == .enabled)
            Menu("Pause Protection") {
                ProtectionMenuItems(adGuard: environment.adGuard)
            }
            .disabled(!canWriteProtection || environment.adGuard.protection != .enabled)
            Divider()
            Button("Open Router UI") {}.disabled(true)
            Button("Open AdGuard Home UI") {}.disabled(true)
        }
        #if DEBUG
        CommandMenu("Debug") {
            Button("Record Fixtures…") { environment.recordFixtures() }
                .disabled(environment.model.mode != .live || !environment.model.session.isReady ||
                          !(environment.model.session.lease?.backend is LiveRouterBackend))
            Divider()
            if environment.model.mode == .mock {
                Menu("Show Onboarding") {
                    ForEach(MockOnboardingScenario.allCases) { scenario in
                        Button(scenario.title) {
                            environment.onboarding.showWindow = { openWindow(id: "onboarding") }
                            environment.onboarding.startMock(scenario)
                        }
                    }
                }
            }
        }
        #endif
    }

    private var canWriteProtection: Bool {
        environment.adGuard.availability == .running && !environment.adGuard.isWriting && environment.model.session.isReady
    }

    private func select(_ destination: SidebarDestination) {
        environment.model.selection = destination
        if environment.model.needsSetup {
            openWindow(id: "onboarding")
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
