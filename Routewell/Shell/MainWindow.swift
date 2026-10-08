import SwiftUI
import RoutewellKit

struct MainWindow: View {
    let environment: AppEnvironment
    var delegate: AppDelegate?
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $model.selection) {
                ForEach(SidebarGroup.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(SidebarDestination.allCases.filter { $0.group == group }) { destination in
                            sidebarRow(destination)
                                .tag(destination)
                                .badge(badge(for: destination))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            Group {
                if model.needsSetup {
                    // Onboarding has its own window; this one closes below.
                    Color.clear
                } else {
                    VStack(spacing: 0) {
                        if model.mode == .mock {
                            HStack {
                                Label("Mock data", systemImage: "testtube.2").fontWeight(.medium)
                                Text("\(model.session.expectedToken?.profileID ?? "Sample router") · no network connection").foregroundStyle(.secondary)
                                Spacer()
                            }
                            .font(.subheadline).padding(.horizontal, 20).padding(.vertical, 9)
                            .background(.quaternary)
                        }
                        DetailRouter(destination: model.selection)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if model.showStatusBar && model.selection == .logs {
                            Divider()
                            Text("Session-only observations — not a router audit log.")
                                .font(.caption).foregroundStyle(.secondary).padding(7)
                        }
                    }
                    .navigationTitle(model.selection.title)
                    .navigationSubtitle(subtitle)
                    .toolbar { toolbar }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(MainWindowLifecycle(delegate: delegate, refresh: environment.refresh))
        .onAppear {
            delegate?.reopen = { [environment, openWindow] in
                openWindow(id: environment.model.needsSetup ? "onboarding" : "main")
            }
        }
        .task(id: model.needsSetup) {
            // Restored at launch, or the router was removed: onboarding takes over.
            await environment.waitUntilReady()
            if model.needsSetup {
                openWindow(id: "onboarding")
                dismissWindow(id: "main")
            }
        }
        .sheet(isPresented: trustPromptPresented) {
            if let request = environment.trustPrompt.pending {
                TrustPromptView(
                    request: request,
                    onCancel: { environment.trustPrompt.resolve(false) },
                    onApprove: { environment.trustPrompt.resolve(true) }
                )
            }
        }
    }

    private var trustPromptPresented: Binding<Bool> {
        Binding(
            get: { environment.trustPrompt.pending != nil },
            set: { if !$0 { environment.trustPrompt.resolve(false) } }
        )
    }

    private var sidebarFooter: some View {
        HStack(spacing: 9) {
            StatusDot(tone: model.snapshot?.router.reachability.tone ?? .unknown)
            VStack(alignment: .leading, spacing: 3) {
                // The name from Settings › Router, so a rename shows here at once.
                Text(environment.persistence.selectedProfile?.name ?? model.snapshot?.router.hostname ?? "No router connected").font(.callout)
                Text(footerDetail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }

    /// AdGuard Home carries a status dot (green running, orange paused, grey
    /// saved copy, red not answering); no dot when off.
    @ViewBuilder private func sidebarRow(_ destination: SidebarDestination) -> some View {
        if destination == .adGuard,
           let tone = AdGuardPresentation.sidebarTone(environment.adGuard.availability, protection: model.snapshot?.adGuard.protection) {
            HStack {
                Label(destination.title, systemImage: destination.symbol)
                Spacer()
                StatusDot(tone: tone)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(Self.adGuardDotDescription(tone))
        } else {
            Label(destination.title, systemImage: destination.symbol)
        }
    }

    static func adGuardDotDescription(_ tone: StatusTone) -> String {
        switch tone {
        case .healthy: "Running"
        case .degraded: "Paused"
        case .error: "Not answering"
        default: "Off, saved copy"
        }
    }

    /// Clients counts devices awaiting review. Notifications keeps its mock
    /// count until the event centre exists (chunk 24).
    private func badge(for destination: SidebarDestination) -> Int {
        switch destination {
        case .clients: model.newDeviceCount
        case .notifications: model.mode == .mock ? 1 : 0
        default: 0
        }
    }

    /// Clients and Router have no toolbar subtitle (architecture 06; Router
    /// has ten segments, design/router-screen.md).
    private var subtitle: String {
        if !model.selection.showsSubtitle { return "" }
        // AdGuard Home's subtitle is the router model (design).
        if model.selection == .adGuard { return model.snapshot?.router.model ?? "" }
        return model.mode == .mock ? (model.session.expectedToken?.profileID ?? "Sample router") : "Not connected"
    }

    private var footerDetail: String {
        guard let router = model.snapshot?.router else { return "Connection setup coming later" }
        let uptime = router.uptimeSeconds.map { " · \($0 / 86400)d \(($0 % 86400) / 3600)h up" } ?? ""
        return (router.lanAddress ?? "Unknown address") + uptime
    }

    /// AdGuard Home hides its tabs in the empty state.
    private var showsSegments: Bool {
        !model.selection.segments.isEmpty && (model.selection != .adGuard || environment.adGuard.showsTabs)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if showsSegments {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: Binding(
                    get: { model.subpages[model.selection] ?? model.selection.segments.first ?? "" },
                    set: { model.subpages[model.selection] = $0 }
                )) {
                    ForEach(model.selection.segments, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
            }
        }
        if model.selection == .overview {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu("Restart") {
                    Button("Restart Wi-Fi") {}.disabled(true)
                    Button("Restart AdGuard Home") {}.disabled(true)
                    Button("Reboot Router…") {}.disabled(true)
                }.disabled(true).help("Router actions are not available yet")
                Button("Back Up…") {}.disabled(true)
                Button("Router UI", systemImage: "arrow.up.right.square") {}.disabled(true)
            }
        }
        if model.selection == .adGuard {
            ToolbarItem(placement: .primaryAction) {
                Text(AdGuardPresentation.freshness(environment.adGuard.availability, archive: environment.adGuard.archive,
                                                   observedAt: environment.adGuard.reading?.observedAt, now: model.evaluatedAt))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Refresh", systemImage: "arrow.clockwise") { environment.refresh.refreshNow() }
                .labelStyle(.iconOnly)
                .disabled(!environment.refresh.isAvailable || model.isRefreshing)
                .help("Refresh sample data (⌘R)")
        }
    }
}
