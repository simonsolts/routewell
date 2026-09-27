import SwiftUI
import RoutewellKit

/// Ports, Storage, and Logs: `SSHRequiredView` until SSH is set up, the
/// probe state while it runs or after it fails, then the segment.
struct RouterSSHSegment: View {
    let segment: RouterSegment
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        switch RouterSSHState(configured: model.sshConfigured, probe: model.sshProbe) {
        case .notSetUp:
            SSHRequiredView(title: segment.rawValue)
        case .checking:
            ProgressView("Checking the SSH connection…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let title, let message):
            ContentUnavailableView {
                Label(title, systemImage: "terminal")
            } description: {
                Text(message)
            } actions: {
                Button("Check Again") { environment.refresh.reprobeSSH() }
                Button("Open Router Settings") { SSHRequiredView.openRouterSettings(model, open: { openSettings() }) }
            }
        case .ready:
            switch segment {
            case .logs:
                RouterLogsSegment()
            case .storage:
                ScrollView { RouterStorageSegment().padding(20).frame(maxWidth: .infinity, alignment: .topLeading) }
            default:
                ScrollView { RouterPortsSegment().padding(20).frame(maxWidth: .infinity, alignment: .topLeading) }
            }
        }
    }
}

/// Before the first read of a segment: loading, or why it failed.
private struct RouterSSHPlaceholder: View {
    let title: String
    let freshness: Freshness

    var body: some View {
        if let failure = freshness.failure {
            ContentUnavailableView(title, systemImage: "exclamationmark.triangle", description: Text(failure.failureCategory.message))
        } else {
            ProgressView("Reading over SSH…").frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}

// MARK: - Ports

struct RouterPortsSegment: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if let ports = model.ports {
            let portsModel = RouterPortsModel(ports: ports, changes: model.linkChanges)
            VStack(alignment: .leading, spacing: 22) {
                MetricStrip(metrics: portsModel.strip)
                RouterFreshnessNote(freshness: model.portsFreshness)
                HeaderInset(title: "Ethernet interfaces", footnote: RouterPortsModel.footnote) {
                    Button("Copy Summary") { environment.router.copy(portsModel.summary(hostname: model.snapshot?.router.hostname)) }
                } content: {
                    InsetTable(columns: RouterPortsModel.columns, rows: portsModel.rows, emptyText: "The router reported no Ethernet interfaces")
                }
                HeaderInset(title: "Session history") {
                    RouterRow(row: portsModel.history)
                    ForEach(Array(portsModel.changes.enumerated()), id: \.offset) { _, change in
                        Divider().padding(.leading, 12)
                        Text(change).font(.body.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }
            }
        } else {
            RouterSSHPlaceholder(title: "Ports unavailable", freshness: model.portsFreshness)
        }
    }
}

// MARK: - Storage

struct RouterStorageSegment: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let storage = model.storage {
            let storageModel = RouterStorageModel(storage: storage)
            VStack(alignment: .leading, spacing: 14) {
                RouterFreshnessNote(freshness: model.storageFreshness)
                TwoColumns {
                    HeaderInset(title: "Root filesystem") {
                        RouterRow(row: storageModel.rootStatus)
                        Divider().padding(.leading, 12)
                        meterRow("Usage", fraction: storageModel.rootFraction, text: storageModel.rootUsage)
                        ForEach(Array(storageModel.rootRows.enumerated()), id: \.offset) { _, row in
                            Divider().padding(.leading, 12)
                            RouterRow(row: row)
                        }
                    }
                    HeaderInset(title: "External storage") {
                        RouterRow(row: storageModel.mounted)
                        ForEach(Array(storageModel.volumes.enumerated()), id: \.offset) { _, volume in
                            Divider().padding(.leading, 12)
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(volume.mountPoint).font(.body.monospaced())
                                    Text(volume.type).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let fraction = volume.fraction {
                                    ProgressView(value: fraction).frame(width: 110).accessibilityLabel("\(volume.mountPoint) used")
                                }
                                Text(volume.usage).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        if let available = storageModel.externalAvailable {
                            Divider().padding(.leading, 12)
                            RouterRow(row: available)
                        }
                    }
                } right: {
                    HeaderInset(title: "File sharing", footnote: RouterStorageModel.footnote) {
                        RouterRows(rows: storageModel.sharing)
                        if !storageModel.shares.isEmpty {
                            Divider()
                            InsetTable(columns: RouterStorageModel.shareColumns, rows: storageModel.shares)
                        }
                    }
                }
            }
        } else {
            RouterSSHPlaceholder(title: "Storage unavailable", freshness: model.storageFreshness)
        }
    }

    private func meterRow(_ title: String, fraction: Double?, text: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            if let fraction {
                ProgressView(value: fraction).frame(width: 110).accessibilityLabel("Root filesystem used")
            }
            Text(text).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).frame(minHeight: 38)
    }
}

// MARK: - Logs

struct RouterLogsSegment: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @State private var severity = RouterLogSeverityFilter.all
    @State private var category: RouterLogCategory?
    @State private var search = ""
    @State private var selection: RouterLogEntry.ID?

    var body: some View {
        Group {
            if let tail = model.routerLogs {
                let logs = RouterLogsModel(tail: tail, severity: severity, category: category, search: search)
                let selected = logs.entries.first { $0.id == selection }
                VStack(alignment: .leading, spacing: 14) {
                    filterRow(logs)
                    RouterFreshnessNote(freshness: model.routerLogsFreshness)
                    Table(logs.entries, selection: $selection) {
                        TableColumn("Time") { Text(RouterLogsModel.time($0)).font(.body.monospacedDigit()) }.width(min: 64, ideal: 72, max: 90)
                        TableColumn("Severity") { entry in
                            HStack(spacing: 5) {
                                StatusDot(tone: RouterLogsModel.tone(entry.severity))
                                Text(entry.severity?.label ?? RouterFormat.dash)
                            }
                        }.width(min: 64, ideal: 76, max: 100)
                        TableColumn("Category") { Text($0.category.rawValue) }.width(min: 70, ideal: 100, max: 140)
                        TableColumn("Source") { Text($0.source).font(.body.monospaced()) }.width(min: 64, ideal: 90, max: 160)
                        TableColumn("Message") { Text($0.line).font(.body.monospaced()).lineLimit(1).truncationMode(.tail) }
                    }
                    .frame(minHeight: 220)
                    HeaderInset(title: "Selected event") {
                        if let selected {
                            RouterRows(rows: RouterLogsModel.detail(selected))
                        } else {
                            Text("Select an entry to see it in full.").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                    }
                }
                .padding(20)
            } else {
                RouterSSHPlaceholder(title: "Router log unavailable", freshness: model.routerLogsFreshness)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search log entries")
    }

    private func filterRow(_ logs: RouterLogsModel) -> some View {
        HStack(spacing: 12) {
            Picker("Severity", selection: $severity) {
                ForEach(RouterLogSeverityFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            Picker("Category", selection: $category) {
                Text("All").tag(RouterLogCategory?.none)
                Divider()
                ForEach(RouterLogCategory.allCases, id: \.self) { Text($0.rawValue).tag(RouterLogCategory?.some($0)) }
            }
            .fixedSize()
            Spacer()
            Text(logs.status).font(.subheadline).foregroundStyle(.secondary)
            Menu("Copy…") {
                Button("Copy Selected Entry") {
                    if let entry = logs.entries.first(where: { $0.id == selection }) { environment.router.copy(RouterLogsModel.copyText([entry])) }
                }
                .disabled(selection == nil)
                Button("Copy Shown Entries") { environment.router.copy(RouterLogsModel.copyText(logs.entries)) }
                    .disabled(logs.entries.isEmpty)
            }
            .fixedSize()
        }
    }
}
