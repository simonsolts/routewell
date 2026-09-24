import SwiftUI
import RoutewellKit

/// Router: ten segments in the toolbar (design/router-screen.md). Every
/// RPC segment is read-only; Ports, Storage, and Logs need SSH (chunk 15).
struct RouterScreen: View {
    @Environment(AppModel.self) private var model

    private var segment: RouterSegment {
        RouterSegment(rawValue: model.subpages[.router] ?? "") ?? .overview
    }

    var body: some View {
        if segment.requiresSSH {
            SSHRequiredView(title: segment.rawValue)
        } else if model.snapshot == nil {
            RouterUnavailableView()
        } else {
            ScrollView {
                Group {
                    switch segment {
                    case .overview: RouterOverviewSegment()
                    case .wifi: RouterWiFiSegment()
                    case .multiWAN: RouterMultiWANSegment()
                    case .dns: RouterDNSSegment()
                    case .sqm: RouterSQMSegment()
                    case .performance: RouterPerformanceSegment()
                    case .firmware: RouterFirmwareSegment()
                    case .ports, .storage, .logs: EmptyView()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Shown before the first router read in this session.
struct RouterUnavailableView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if model.session.lease == nil && !model.session.switching {
            ContentUnavailableView("No router connected", systemImage: "wifi.router",
                                   description: Text("Connect a router to see its status."))
        } else if let failure = model.freshness[.router]?.failure {
            ContentUnavailableView {
                Label("Router status unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.failureCategory.message)
            } actions: {
                Button("Refresh") { environment.refresh.refreshNow() }
                    .disabled(!environment.refresh.isAvailable || model.isRefreshing)
            }
        } else {
            ProgressView("Loading router status…")
        }
    }
}

/// Two equal columns, as in every Router mockup. The window's minimum
/// width leaves each column more than 300 pt.
private struct TwoColumns<Left: View, Right: View>: View {
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 22, content: left).frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 22, content: right).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Overview

struct RouterOverviewSegment: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let overview = RouterOverviewModel(snapshot: model.snapshot ?? OverviewSnapshot(observedAt: .now), wireless: model.wireless)
        VStack(alignment: .leading, spacing: 22) {
            MetricStrip(metrics: overview.strip)
            TwoColumns {
                HeaderInset(title: "Identity") { RouterRows(rows: overview.identity) }
                HeaderInset(title: "Memory") { RouterRows(rows: overview.memory) }
            } right: {
                HeaderInset(title: "Network") { RouterRows(rows: overview.network) }
                HeaderInset(title: "Services", footnote: RouterOverviewModel.footnote) { RouterRows(rows: overview.services) }
            }
        }
    }
}

// MARK: - Performance

struct RouterPerformanceSegment: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @State private var confirmingReset = false

    var body: some View {
        let snapshot = model.snapshot ?? OverviewSnapshot(observedAt: .now)
        let performance = RouterPerformanceModel(snapshot: snapshot, history: model.telemetryHistory, session: model.telemetrySession)
        VStack(alignment: .leading, spacing: 22) {
            MetricStrip(metrics: performance.strip)
            TwoColumns {
                HeaderInset(title: "Memory") { RouterRows(rows: performance.memory) }
                HeaderInset(title: "Storage", footnote: "Router storage as the router API reports it. Mount details need SSH.") {
                    RouterRows(rows: performance.storage)
                    Divider().padding(.leading, 12)
                    HStack(spacing: 12) {
                        Text("Usage")
                        Spacer()
                        if let fraction = performance.storageFraction {
                            ProgressView(value: fraction).frame(width: 120).accessibilityLabel("Storage used")
                            Text(RouterFormat.percent(fraction)).monospacedDigit().foregroundStyle(.secondary)
                        } else {
                            Text(RouterFormat.unknown).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12).frame(minHeight: 38)
                }
            } right: {
                HeaderInset(title: "Session", footnote: RouterPerformanceModel.footnote) {
                    Button("Reset Session…") { confirmingReset = true }
                } content: {
                    RouterRows(rows: performance.session)
                }
                Button("Copy Summary") {
                    environment.router.copy(performance.summary(hostname: snapshot.router.hostname))
                }
            }
        }
        .alert("Reset session values?", isPresented: $confirmingReset) {
            Button("Reset Session", role: .destructive) { Task { await environment.refresh.resetTelemetrySession() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The observation count and the peaks start again from now. The router is not changed.")
        }
    }
}

// MARK: - DNS

struct RouterDNSSegment: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dns = RouterDNSModel(snapshot: model.snapshot ?? OverviewSnapshot(observedAt: .now))
        VStack(alignment: .leading, spacing: 14) {
            TwoColumns {
                HeaderInset(title: "Configuration") {
                    RouterRows(rows: Array(dns.configuration.prefix(2)))
                    Divider().padding(.leading, 12)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Upstream resolvers")
                            Text("Reported by the WAN connection").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            if dns.upstreams.isEmpty { Text(RouterFormat.unknown) }
                            ForEach(dns.upstreams, id: \.self) { Text($0).font(.body.monospaced()) }
                        }
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    Divider().padding(.leading, 12)
                    RouterRows(rows: Array(dns.configuration.suffix(1)))
                }
            } right: {
                HeaderInset(title: "Services") { RouterRows(rows: dns.services) }
                HeaderInset(title: "Path") { RouterRow(row: RouterRowModel(label: "Resolution path", value: dns.path)) }
            }
            Text(RouterDNSModel.footnote).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Wi-Fi

struct RouterWiFiSegment: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if let wireless = model.wireless {
            let signals = model.clientInventory?.clients.compactMap { client -> Int? in
                if case .value(let dBm) = client.signal, client.online == .value(true) { return dBm }
                return nil
            }
            let wifi = RouterWiFiModel(wireless: wireless, onlineByBand: model.snapshot?.clients.onlineByBand,
                                       signals: signals.flatMap { $0.isEmpty ? nil : $0 })
            VStack(alignment: .leading, spacing: 14) {
                MetricStrip(metrics: wifi.strip)
                HStack {
                    RouterFreshnessNote(freshness: model.wirelessFreshness)
                    Spacer()
                    Button("Copy Summary") { environment.router.copy(wifi.summary(hostname: model.snapshot?.router.hostname)) }
                }
                ForEach(Array(wifi.bands.enumerated()), id: \.offset) { _, band in
                    HeaderInset(title: band.title) {
                        Text(band.radio).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                    } content: {
                        InsetTable(columns: RouterWiFiModel.columns, rows: band.rows, emptyText: "No networks on this radio")
                    }
                }
            }
        } else if let failure = model.wirelessFreshness.failure {
            ContentUnavailableView("Wi-Fi status unavailable", systemImage: "wifi.exclamationmark",
                                   description: Text(failure.failureCategory.message))
        } else {
            ProgressView("Loading Wi-Fi…").frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}

/// "Last read failed" under a segment whose previous values stay shown.
struct RouterFreshnessNote: View {
    let freshness: Freshness

    var body: some View {
        if let failure = freshness.failure {
            HStack(spacing: 6) {
                StatusDot(tone: .degraded)
                Text("\(failure.failureCategory.message) Showing the last values read.")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Multi-WAN

struct RouterMultiWANSegment: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let wan = RouterMultiWANModel(internet: model.snapshot?.internet ?? InternetStatus(), tracker: model.wanPaths)
        VStack(alignment: .leading, spacing: 22) {
            TwoColumns {
                HeaderInset(title: "Multi-WAN") { RouterRows(rows: wan.multiWAN) }
            } right: {
                HeaderInset(title: "Active path") { RouterRows(rows: wan.activePath) }
            }
            HeaderInset(title: "WAN interfaces", footnote: RouterMultiWANModel.footnote) {
                Button("Copy Summary") { environment.router.copy(wan.summary(hostname: model.snapshot?.router.hostname)) }
            } content: {
                InsetTable(columns: RouterMultiWANModel.columns, rows: wan.rows, emptyText: "The router reported no WAN interfaces")
            }
            HeaderInset(title: "Session history") { RouterRow(row: wan.history) }
        }
    }
}

// MARK: - SQM

struct RouterSQMSegment: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sqm = RouterSQMModel(capability: model.sqmCapability, configuration: model.sqm, failure: model.sqmFreshness.failure,
                                 legacyEnabled: model.snapshot?.router.sqmEnabled ?? .unknown)
        TwoColumns {
            HeaderInset(title: "Smart queue management", footnote: sqm.footnote) {
                Toggle(isOn: .constant(sqm.switchOn)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SQM")
                        Text("Shapes traffic on the WAN interface to reduce bufferbloat.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider().padding(.leading, 12)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Queue discipline")
                        Text("cake is recommended for most connections.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Queue discipline", selection: .constant(sqm.queueDiscipline)) {
                        ForEach(Set(RouterSQMModel.queueDisciplines + [sqm.queueDiscipline]).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider().padding(.leading, 12)
                limitRow("Upload", value: sqm.upload)
                Divider().padding(.leading, 12)
                limitRow("Download", value: sqm.download)
            }
            .disabled(sqm.controlsDisabled)
        } right: {
            HeaderInset(title: "Status", footnote: sqm.statusFootnote) { RouterRows(rows: sqm.status) }
        }
    }

    private func limitRow(_ title: String, value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("Whole Mbps, 1–10000").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                TextField("", text: .constant(value), prompt: nil).labelsHidden().accessibilityLabel(title)
                    .multilineTextAlignment(.trailing).frame(width: 80)
                Text("Mbps").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - Firmware

struct RouterFirmwareSegment: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @State private var showingNotes = false
    @State private var confirmingBaseline = false

    var body: some View {
        let controller = environment.router
        let firmware = RouterFirmwareModel(router: model.snapshot?.router ?? RouterStatus(), state: controller.firmware)
        let lifecycle = RouterFirmwareModel.lifecycle(baseline: controller.baseline, check: controller.postUpgradeCheck)
        TwoColumns {
            HeaderInset(title: "Connected router", footnote: RouterFirmwareModel.footnote) {
                RouterRows(rows: firmware.identity + [firmware.statusRow, RouterRowModel(label: "Latest available", value: firmware.latest, monospaced: true)])
                Divider().padding(.leading, 12)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update check")
                        Text(RouterFirmwareModel.checkDetail).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Release Notes…") { showingNotes = true }.disabled(!firmware.releaseNotesAvailable)
                    Button("Check for Updates") { Task { await controller.checkForUpdates() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(firmware.checking || model.session.lease == nil)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider().padding(.leading, 12)
                HStack {
                    Text("Upgrades happen in the router's own interface.").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in Router UI", systemImage: "arrow.up.right.square") { controller.openRouterUI() }
                        .disabled(controller.routerURL() == nil)
                        .help(controller.routerURL() == nil ? "The mock router has no web interface" : "Open the router's administration page")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        } right: {
            HeaderInset(title: "Firmware lifecycle", footnote: controller.snapshotIssue?.message ?? lifecycle.footnote) {
                lifecycleRow("Pre-upgrade baseline", detail: "Snapshot of the observed router state before upgrading.",
                             value: lifecycle.baselineValue, button: "Save Baseline…", enabled: model.snapshot != nil) {
                    confirmingBaseline = true
                }
                Divider().padding(.leading, 12)
                lifecycleRow("Post-upgrade check", detail: "Compares the current state against the saved baseline after the router reconnects.",
                             value: lifecycle.checkValue, button: "Run Check", enabled: lifecycle.runCheckEnabled) {
                    Task { await controller.runPostUpgradeCheck() }
                }
            }
            if !lifecycle.differences.isEmpty {
                HeaderInset(title: "Changes since the baseline") { RouterRows(rows: lifecycle.differences) }
            }
        }
        .sheet(isPresented: $showingNotes) {
            FirmwareReleaseNotesSheet(check: controller.firmware?.check, currentFirmware: model.snapshot?.router.firmware) {
                controller.openRouterUI()
            }
        }
        .alert(controller.baseline == nil ? "Save a pre-upgrade baseline?" : "Replace the saved baseline?", isPresented: $confirmingBaseline) {
            Button(controller.baseline == nil ? "Save Baseline" : "Replace Baseline") { Task { await controller.saveBaseline() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Routewell saves the router state it observes now on this Mac. Nothing is sent to the router.")
        }
    }

    private func lifecycleRow(_ title: String, detail: String, value: String, button: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary)
            Button(button, action: action).disabled(!enabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct FirmwareReleaseNotesSheet: View {
    let check: FirmwareCheck?
    let currentFirmware: String?
    let openRouterUI: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Release Notes").font(.title3).fontWeight(.semibold)
            if case .value(let latest)? = check?.latest {
                Text("Firmware \(latest) · installed \(currentFirmware ?? RouterFormat.unknown)").foregroundStyle(.secondary)
            }
            ScrollView {
                Text(check?.releaseNotes ?? "The router did not return release notes.")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160)
            Text("Routewell does not download or install firmware. Upgrade in the router's own interface.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("Open in Router UI") { openRouterUI() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 360)
    }
}
