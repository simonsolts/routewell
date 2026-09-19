import SwiftUI

struct MainWindow: View {
    let environment: AppEnvironment
    var delegate: AppDelegate?
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $model.selection) {
                ForEach(SidebarGroup.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(SidebarDestination.allCases.filter { $0.group == group }) { destination in
                            Label(destination.title, systemImage: destination.symbol)
                                .tag(destination)
                                .badge(mockBadge(for: destination))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
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
                if model.showStatusBar && [.clients, .logs].contains(model.selection) {
                    Divider()
                    Text(model.selection == .logs
                         ? "Session-only observations — not a router audit log."
                         : "Client inventory is not available in this build.")
                        .font(.caption).foregroundStyle(.secondary).padding(7)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(model.selection.title)
            .navigationSubtitle(model.mode == .mock ? (model.session.expectedToken?.profileID ?? "Sample router") : "Not connected")
            .toolbar { toolbar }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(MainWindowLifecycle(delegate: delegate, refresh: environment.refresh))
        .onAppear {
            delegate?.reopenMainWindow = { openWindow(id: "main") }
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 9) {
            StatusDot(tone: model.snapshot?.router.reachability.tone ?? .unknown)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.snapshot?.router.hostname ?? "No router connected").font(.callout)
                Text(footerDetail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }

    private func mockBadge(for destination: SidebarDestination) -> Int {
        guard model.mode == .mock else { return 0 }
        switch destination { case .clients: return 3; case .notifications: return 1; default: return 0 }
    }

    private var footerDetail: String {
        guard let router = model.snapshot?.router else { return "Connection setup coming later" }
        let uptime = router.uptimeSeconds.map { " · \($0 / 86400)d \(($0 % 86400) / 3600)h up" } ?? ""
        return (router.lanAddress ?? "Unknown address") + uptime
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 12) {
                if !model.selection.segments.isEmpty {
                    Picker("Section", selection: Binding(
                        get: { model.subpages[model.selection] ?? model.selection.segments.first ?? "" },
                        set: { model.subpages[model.selection] = $0 }
                    )) {
                        ForEach(model.selection.segments, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                }
                if model.selection.showsStatusPill {
                    Button { model.selection = .overview } label: { StatusPillView(snapshot: model.snapshot) }
                        .buttonStyle(.plain).help("Show Overview")
                }
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
        ToolbarItem(placement: .primaryAction) {
            Button("Refresh", systemImage: "arrow.clockwise") { environment.refresh.refreshNow() }
                .labelStyle(.iconOnly)
                .disabled(!environment.refresh.isAvailable || model.isRefreshing)
                .help("Refresh sample data (⌘R)")
        }
    }
}
