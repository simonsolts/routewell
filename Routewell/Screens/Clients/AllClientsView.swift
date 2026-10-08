import SwiftUI
import AppKit
import RoutewellKit

/// One table row with its display strings and sort keys. Sorting itself
/// runs through `ClientListing`, so unknown values stay last both ways.
struct ClientRow: Identifiable {
    let entry: ClientListEntry
    let name: String
    let ip: String
    let connection: String
    let signal: (text: String, tone: StatusTone)?
    let queries: String
    let blocked: String
    let blockedEmphasised: Bool
    let rate: String
    let status: (text: String, tone: StatusTone)
    var id: MACAddress { entry.mac }

    init(entry: ClientListEntry, nameMode: ClientNameMode, now: Date) {
        self.entry = entry
        name = ClientsFormat.name(entry, mode: nameMode)
        ip = entry.client?.ip ?? ClientsFormat.dash
        connection = ClientsFormat.connection(entry.client) ?? ClientsFormat.dash
        signal = ClientsFormat.signal(entry.client)
        queries = ClientsFormat.count(entry.queries)
        blocked = ClientsFormat.count(entry.blocked)
        if case .value(let count) = entry.blocked { blockedEmphasised = count > 0 } else { blockedEmphasised = false }
        rate = ClientsFormat.rate(entry.blockRate)
        status = ClientsFormat.status(entry, now: now)
    }

    // Sort keys for the table header only.
    var nameKey: String { name }
    var ipKey: String { ip }
    var connectionKey: String { connection }
    var signalKey: Int { 0 }
    var queriesKey: Int { 0 }
    var blockedKey: Int { 0 }
    var rateKey: Int { 0 }
    var statusKey: Int { 0 }
    var favouriteKey: Int { 0 }

    static var columns: [PartialKeyPath<ClientRow>: ClientSortColumn] { [
        \ClientRow.nameKey: .name, \ClientRow.ipKey: .ip, \ClientRow.connectionKey: .connection,
        \ClientRow.signalKey: .signal, \ClientRow.queriesKey: .queries, \ClientRow.blockedKey: .blocked,
        \ClientRow.rateKey: .rate, \ClientRow.statusKey: .status, \ClientRow.favouriteKey: .favourite,
    ] }

    static func sort(for order: [KeyPathComparator<ClientRow>]) -> ClientSort {
        guard let first = order.first, let column = columns[first.keyPath] else { return .standard }
        return ClientSort(column: column, ascending: first.order == .forward)
    }
}

struct AllClientsView: View {
    let search: String
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @State private var nameMode: ClientNameMode = .automatic
    @State private var onlineOnly = false
    @State private var favouritesOnly = false
    @State private var hideUnknown = false
    @State private var sortOrder = [KeyPathComparator(\ClientRow.blockedKey, order: .reverse)]
    @State private var showingReview = false
    @State private var paneHeight: Double = 300

    var body: some View {
        if let inventory = model.clientInventory {
            content(inventory)
        } else {
            ClientsUnavailableView()
        }
    }

    private func content(_ inventory: ClientInventory) -> some View {
        let now = Date()
        let all = ClientListing.entries(clients: inventory.clients, records: model.deviceRegistry.records)
        let filter = ClientFilter(onlineOnly: onlineOnly, favouritesOnly: favouritesOnly, hideUnknown: hideUnknown, search: search)
        let visible = ClientListing.apply(filter: filter, sort: ClientRow.sort(for: sortOrder), nameMode: nameMode, to: all)
        let rows = visible.map { ClientRow(entry: $0, nameMode: nameMode, now: now) }
        return VStack(alignment: .leading, spacing: 0) {
            filterRow.padding(.horizontal, 20).padding(.top, 14)
            statusLine(visible: visible.count, total: all.count, inventory: inventory)
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    table(rows)
                        .overlay {
                            if rows.isEmpty {
                                Text(all.isEmpty ? "The router reports no clients." : "No clients match the filters.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 20)
                    if model.clientsDetailsVisible {
                        let range = paneRange(total: geometry.size.height)
                        PaneDivider(height: $paneHeight, range: range) { model.clientsDetailsHeight = $0 }
                        ClientDetailsPane(content: ClientsPaneContent.resolve(selection: model.clientsSelection, entries: all), now: now)
                            .frame(height: min(max(paneHeight, range.lowerBound), range.upperBound))
                    } else {
                        Spacer().frame(height: 16)
                    }
                }
            }
        }
        .onAppear { paneHeight = model.clientsDetailsHeight }
        .onChange(of: model.clientsDetailsHeight) { _, value in paneHeight = value }
        .sheet(isPresented: Binding(
            get: { environment.clientActions.sshRequiredAction != nil },
            set: { if !$0 { environment.clientActions.sshRequiredAction = nil } }
        )) {
            VStack(spacing: 0) {
                SSHRequiredView(title: environment.clientActions.sshRequiredAction == .wake ? "Wake needs SSH" : "Ping needs SSH")
                    .frame(width: 420, height: 240)
                HStack {
                    Text("The router runs Ping and Wake over SSH; it offers no other way.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { environment.clientActions.sshRequiredAction = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
        }
        .sheet(isPresented: $showingReview) {
            NewDevicesSheet(
                rows: ClientsFormat.reviewRows(registry: model.deviceRegistry, clients: inventory.clients, now: now),
                onReview: review,
                onDone: { showingReview = false }
            )
        }
    }

    /// Keeps at least 140 pt of table above the pane.
    private func paneRange(total: Double) -> ClosedRange<Double> {
        let lower = AppModel.clientsDetailsHeightRange.lowerBound
        return lower...max(lower, min(AppModel.clientsDetailsHeightRange.upperBound, total - 140))
    }

    private var filterRow: some View {
        HStack(spacing: 18) {
            Picker("Names", selection: $nameMode) {
                Text("Automatic").tag(ClientNameMode.automatic)
                Text("Hostname").tag(ClientNameMode.hostname)
                Text("Display name").tag(ClientNameMode.displayName)
            }
            .fixedSize()
            Spacer(minLength: 12)
            Toggle("Online only", isOn: $onlineOnly)
            Toggle("Favourites only", isOn: $favouritesOnly)
            Toggle("Hide unknown devices", isOn: $hideUnknown)
        }
        .toggleStyle(.checkbox)
    }

    private func statusLine(visible: Int, total: Int, inventory: ClientInventory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(ClientsFormat.showingText(visible: visible, total: total))
                Spacer()
                if model.newDeviceCount > 0 {
                    Button { showingReview = true } label: {
                        HStack(spacing: 6) {
                            StatusDot(tone: .degraded)
                            Text(ClientsFormat.newDevicesText(model.newDeviceCount))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Review new devices")
                }
            }
            ForEach(notices(inventory), id: \.self) { notice in
                Label(notice, systemImage: "exclamationmark.triangle").font(.caption)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func notices(_ inventory: ClientInventory) -> [String] {
        var result: [String] = []
        if let failure = model.clientsFreshness.failure {
            let since = model.clientsFreshness.lastSuccess.map { " Showing the list from \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
            result.append("The last refresh failed. \(failure.failureCategory.message)\(since)")
        }
        if let notice = ClientsFormat.enrichmentNotice(inventory.enrichment) { result.append(notice) }
        if let issue = model.deviceRegistryIssue { result.append(issue.message) }
        return result
    }

    private func table(_ rows: [ClientRow]) -> some View {
        @Bindable var model = model
        return Table(rows, selection: $model.clientsSelection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.nameKey) { row in Text(row.name) }
                .width(min: 120, ideal: 170)
            TableColumn("IP address", value: \.ipKey) { row in
                Text(row.ip).font(.body.monospaced()).monospacedDigit()
            }
            .width(min: 90, ideal: 120)
            TableColumn("Connection", value: \.connectionKey) { row in Text(row.connection) }
                .width(min: 100, ideal: 190)
            TableColumn("Signal", value: \.signalKey) { row in
                HStack(spacing: 6) {
                    StatusDot(tone: row.signal?.tone ?? .unknown)
                    Text(row.signal?.text ?? ClientsFormat.dash).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            .width(min: 70, ideal: 110)
            TableColumn("Queries", value: \.queriesKey) { row in
                Text(row.queries).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 72)
            TableColumn("Blocked", value: \.blockedKey) { row in
                Text(row.blocked).monospacedDigit()
                    .foregroundStyle(row.blockedEmphasised ? Color.orange : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 72)
            TableColumn("Rate", value: \.rateKey) { row in
                Text(row.rate).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Status", value: \.statusKey) { row in
                HStack(spacing: 6) {
                    StatusDot(tone: row.status.tone)
                    Text(row.status.text)
                }
                .accessibilityElement(children: .combine)
            }
            .width(min: 80, ideal: 130)
            TableColumn("★", value: \.favouriteKey) { row in
                if row.entry.isFavourite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favourite")
                }
            }
            .width(22)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: MACAddress.self) { macs in
            if macs.count == 1, let mac = macs.first, let row = rows.first(where: { $0.id == mac }) {
                rowMenu(row.entry)
            }
        } primaryAction: { macs in
            guard macs.count == 1, let mac = macs.first else { return }
            model.revealClient(mac, section: .overview)
        }
    }

    /// Open Details, Ping, Wake, Favourite, Copy IP, Copy MAC, Show DNS Log.
    @ViewBuilder
    private func rowMenu(_ entry: ClientListEntry) -> some View {
        let actions = environment.clientActions
        Button("Open Details") { model.revealClient(entry.mac, section: .overview) }
        if actions.mechanism != nil {
            Divider()
            Button("Ping") {
                model.clientsSelection = [entry.mac]
                actions.ping(entry)
            }
            .disabled(actions.mechanism != .sshRequired && entry.client?.ip.flatMap(IPv4Literal.init) == nil)
            Button("Wake") {
                model.clientsSelection = [entry.mac]
                actions.wake(entry)
            }
        }
        Divider()
        Button(entry.isFavourite ? "Remove from Favourites" : "Add to Favourites") {
            Task { await environment.clients.edit(entry.mac, .setFavourite(!entry.isFavourite)) }
        }
        .disabled(entry.record == nil)
        Divider()
        Button("Copy IP Address") { ClientsPasteboard.copy(entry.client?.ip ?? "") }
            .disabled(entry.client?.ip == nil)
        Button("Copy MAC Address") { ClientsPasteboard.copy(entry.mac.colonSeparated) }
        Divider()
        Button("Show DNS Log") {
            if let ip = entry.client?.ip { model.showDNSLog(client: ip) }
        }
        .disabled(entry.client?.ip == nil)
    }

    private func review(_ mac: MACAddress) {
        showingReview = false
        onlineOnly = false
        favouritesOnly = false
        hideUnknown = false
        model.revealClient(mac, section: .personalise)
        Task { await environment.clients.markReviewed(mac) }
    }
}

/// The draggable divider above the details pane. Dragging up grows the pane;
/// the height is saved when the drag ends.
struct PaneDivider: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    let onEnd: (Double) -> Void
    @State private var dragStart: Double?

    var body: some View {
        ZStack {
            Rectangle().fill(.separator).frame(height: 1)
            Capsule().fill(.tertiary).frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? height
                    dragStart = start
                    height = min(max(start - value.translation.height, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in
                    dragStart = nil
                    onEnd(height)
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Details pane divider")
        .accessibilityValue("\(Int(height)) points")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 40.0 : -40.0
            height = min(max(height + step, range.lowerBound), range.upperBound)
            onEnd(height)
        }
    }
}
