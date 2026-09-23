import SwiftUI
import RoutewellKit

/// One Known Clients row: a remembered device joined with the current
/// router list by MAC.
struct KnownClientRow: Identifiable {
    let record: DeviceRecord
    let client: Client?
    let hostname: String
    let displayName: String
    let category: String
    let lastIP: String
    let lastSeen: String
    let isOnline: Bool
    var id: MACAddress { record.mac }

    init(record: DeviceRecord, client: Client?, now: Date) {
        self.record = record
        self.client = client
        hostname = client?.hostname ?? record.lastHostname ?? ClientsFormat.dash
        displayName = record.userName.flatMap { $0.isEmpty ? nil : $0 } ?? ClientsFormat.dash
        category = ClientsFormat.category(record.category) ?? ClientsFormat.dash
        lastIP = client?.ip ?? record.lastIP ?? ClientsFormat.dash
        isOnline = client?.online == .value(true)
        lastSeen = isOnline ? "Just now" : record.lastSeen.map { ClientsFormat.relative($0, now: now) } ?? "Never"
    }

    var hostnameKey: String { hostname }
    var displayNameKey: String { displayName }
    var categoryKey: String { category }
    var macKey: String { record.mac.normalized }
    var lastIPKey: String { lastIP }
    var lastSeenKey: Date { isOnline ? .distantFuture : record.lastSeen ?? .distantPast }
    var favouriteKey: Int { record.favourite ? 1 : 0 }
    var monitorKey: Int { record.monitored ? 1 : 0 }
}

struct KnownClientsFilter: Equatable {
    var category: DeviceCategory?
    var favouritesOnly = false
    var monitoredOnly = false
    var notSeenIn30Days = false
    var search = ""

    func matches(_ row: KnownClientRow, now: Date) -> Bool {
        if let category, row.record.category != category { return false }
        if favouritesOnly, !row.record.favourite { return false }
        if monitoredOnly, !row.record.monitored { return false }
        if notSeenIn30Days {
            if row.isOnline { return false }
            if let lastSeen = row.record.lastSeen, now.timeIntervalSince(lastSeen) < 30 * 86_400 { return false }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [row.hostname, row.displayName, row.lastIP, row.record.mac.colonSeparated]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// Known Clients (from the v1 mockup): stat strip, category filter, table of
/// remembered devices, and the selected client. Edit… opens Personalise in
/// the All Clients pane; − and Forget Device… use the pane's forget path.
struct KnownClientsView: View {
    let search: String
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @State private var filter = KnownClientsFilter()
    @State private var selection: MACAddress?
    @State private var confirmingForget = false
    @State private var sortOrder = [KeyPathComparator(\KnownClientRow.lastSeenKey, order: .reverse)]

    var body: some View {
        let now = Date()
        let clients = model.clientInventory?.clients ?? []
        let byMAC = Dictionary(clients.map { ($0.mac, $0) }, uniquingKeysWith: { first, _ in first })
        var activeFilter = filter
        activeFilter.search = search
        let rows = model.deviceRegistry.records.values
            .map { KnownClientRow(record: $0, client: byMAC[$0.mac], now: now) }
            .filter { activeFilter.matches($0, now: now) }
            .sorted(using: sortOrder)
        let summary = ClientsFormat.knownSummary(registry: model.deviceRegistry, clients: clients)

        return VStack(alignment: .leading, spacing: 14) {
            MetricStrip(metrics: [
                MetricModel(title: "Known clients", value: summary.known.formatted(), detail: "Stored on this Mac · matched by MAC address"),
                MetricModel(title: "Online now", value: model.clientInventory == nil ? ClientsFormat.unknown : summary.online.formatted(),
                            detail: model.clientInventory == nil ? "Router list not loaded" : "\(summary.offline) offline"),
                MetricModel(title: "Favourites", value: summary.favourites.formatted(), detail: "Pinned in All Clients"),
                MetricModel(title: "Monitored", value: summary.monitored.formatted(), detail: "Availability notifications on"),
            ])
            filterRow
            table(rows)
                .frame(minHeight: 160)
                .layoutPriority(1)
            actionBar(selected: rows.first { $0.id == selection })
            if let selection, let row = rows.first(where: { $0.id == selection }) {
                selectedClient(row)
            }
            Text("Known clients persist after a device leaves the network. Removing one deletes its saved history and preferences on this Mac only; router configuration is not changed.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .forgetDeviceAlert(isPresented: $confirmingForget, entry: rows.first { $0.id == selection }.map(entry(for:)))
    }

    private func entry(for row: KnownClientRow) -> ClientListEntry {
        ClientListEntry(mac: row.record.mac, client: row.client, record: row.record)
    }

    private var filterRow: some View {
        HStack(spacing: 18) {
            Picker("Category", selection: $filter.category) {
                Text("All").tag(DeviceCategory?.none)
                ForEach(DeviceCategory.allCases, id: \.self) { category in
                    Text(ClientsFormat.category(category) ?? "").tag(Optional(category))
                }
            }
            .fixedSize()
            Spacer(minLength: 12)
            Toggle("Favourites only", isOn: $filter.favouritesOnly)
            Toggle("Monitored only", isOn: $filter.monitoredOnly)
            Toggle("Not seen in 30 days", isOn: $filter.notSeenIn30Days)
        }
        .toggleStyle(.checkbox)
    }

    private func table(_ rows: [KnownClientRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Hostname", value: \.hostnameKey) { Text($0.hostname) }.width(min: 100, ideal: 140)
            TableColumn("Display name", value: \.displayNameKey) { Text($0.displayName) }.width(min: 90, ideal: 130)
            TableColumn("Category", value: \.categoryKey) { Text($0.category) }.width(min: 70, ideal: 90)
            TableColumn("MAC address", value: \.macKey) { row in
                Text(row.record.mac.colonSeparated).font(.body.monospaced())
            }
            .width(min: 130, ideal: 150)
            TableColumn("Last IP", value: \.lastIPKey) { row in
                Text(row.lastIP).font(.body.monospaced())
            }
            .width(min: 90, ideal: 110)
            TableColumn("Last seen", value: \.lastSeenKey) { Text($0.lastSeen) }.width(min: 70, ideal: 90)
            TableColumn("Favourite", value: \.favouriteKey) { row in
                Image(systemName: row.record.favourite ? "star.fill" : "star")
                    .foregroundStyle(row.record.favourite ? Color.yellow : Color.secondary)
                    .accessibilityLabel(row.record.favourite ? "Favourite" : "Not favourite")
            }
            .width(min: 60, ideal: 70)
            TableColumn("Monitor", value: \.monitorKey) { row in
                HStack(spacing: 5) {
                    StatusDot(tone: row.record.monitored ? .healthy : .unknown)
                    Text(row.record.monitored ? "On" : "Off")
                }
                .accessibilityElement(children: .combine)
            }
            .width(min: 50, ideal: 60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if rows.isEmpty {
                Text(model.deviceRegistry.records.isEmpty ? "No devices are stored on this Mac yet." : "No known clients match the filters.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Add, Import…, and Export… stay disabled: Routewell learns devices
    /// from the router, and backup arrives with chunk 33.
    private func actionBar(selected: KnownClientRow?) -> some View {
        let forget = selected.map { ClientDetailsFormat.forgetState(entry(for: $0), inventoryLoaded: model.clientInventory != nil) }
        return HStack(spacing: 8) {
            ControlGroup {
                Button("Add", systemImage: "plus") {}
                    .disabled(true)
                    .help("Devices are added when the router lists them")
                Button("Remove", systemImage: "minus") { confirmingForget = true }
                    .disabled(forget?.enabled != true)
                    .help(forget?.status ?? "Forget the selected device")
            }
            .fixedSize()
            Spacer()
            Group {
                Button("Import…") {}
                Button("Export…") {}
            }
            .disabled(true)
            .help("Import and export arrive with Routewell backups")
            Button("Forget Device…") { confirmingForget = true }
                .disabled(forget?.enabled != true)
                .help(forget?.status ?? "Forget the selected device")
            Button("Edit…") {
                guard let selected else { return }
                model.revealClient(selected.record.mac, section: .personalise)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selected == nil)
        }
    }

    private func selectedClient(_ row: KnownClientRow) -> some View {
        let entry = ClientListEntry(mac: row.record.mac, client: row.client, record: row.record)
        let subtitle = [row.hostname, row.category, row.record.mac.colonSeparated].joined(separator: " · ")
        return InsetGroup(title: "Selected client") {
            VStack(alignment: .leading, spacing: 3) {
                Text(ClientsFormat.name(entry, mode: .automatic))
                Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            Divider()
            LabelValueRow(label: "Notes", value: row.record.notes.isEmpty ? "No notes" : row.record.notes)
            Divider()
            Toggle(isOn: Binding(get: { row.record.monitored }, set: { value in
                Task { await environment.clients.edit(row.record.mac, .setMonitored(value)) }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monitor availability")
                    Text("Notify when offline for more than 5 minutes. Notifications are not sent yet.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(12)
        }
    }
}
