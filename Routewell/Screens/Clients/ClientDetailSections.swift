import SwiftUI
import RoutewellKit

// MARK: - Shared pieces

/// A rounded box with a title, used for the right-hand column of several
/// sections (Monitor availability, Presence history, Forget this device).
struct PaneBox<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }
}

/// A switch with a title and one line of detail, inside a `PaneBox`.
struct PaneSwitch: View {
    let title: String
    let detail: String
    let isOn: Bool
    let disabled: Bool
    let onChange: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        PaneBox {
            Toggle(isOn: Binding(get: { isOn }, set: onChange)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .disabled(disabled)
        }
    }
}

/// The one-line result of the last write or action for this device.
struct ClientNoticeLine: View {
    let mac: MACAddress
    @Environment(AppModel.self) private var model

    var body: some View {
        if let notice = model.clientNotice, notice.mac == mac {
            HStack(spacing: 6) {
                StatusDot(tone: notice.tone)
                Text(notice.text).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Availability

struct ClientAvailabilitySection: View {
    let entry: ClientListEntry
    let now: Date
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @State private var range: PresenceRange = .day
    @State private var confirmingClear = false

    var body: some View {
        let history = model.presence.devices[entry.mac]
        let availability = ClientDetailsFormat.availability(entry, history: history, range: range, now: now)
        ScrollView {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Presence").font(.headline)
                        Spacer()
                        Picker("Range", selection: $range) {
                            ForEach(PresenceRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    PresenceBar(segments: availability.segments, window: availability.window)
                    HStack(spacing: 12) {
                        Text(range.startLabel)
                        Spacer()
                        PresenceLegend()
                        Spacer()
                        Text("Now")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    DetailGroup(model: DetailGroupModel(title: "", rows: availability.rows))
                    Text(ClientDetailsFormat.footnote).font(.subheadline).foregroundStyle(.secondary)
                    if let issue = model.presenceIssue {
                        Label(issue.message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    PaneSwitch(title: "Monitor availability",
                               detail: "Notify when offline for more than 5 minutes. Notifications are not sent yet.",
                               isOn: entry.record?.monitored == true, disabled: entry.record == nil) { value in
                        Task { await environment.clients.edit(entry.mac, .setMonitored(value)) }
                    }
                    PaneBox {
                        Text("Presence history").font(.headline)
                        Text(availability.historySummary).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("Clear History…") { confirmingClear = true }
                                .disabled(!availability.hasHistory)
                        }
                    }
                    ClientNoticeLine(mac: entry.mac)
                }
                .frame(width: 300)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .alert("Clear this device’s presence history?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History") { Task { await environment.clients.clearHistory(entry.mac) } }
        } message: {
            Text("Routewell removes the presence history it stored for this device on this Mac. The router is not changed.")
        }
    }
}

/// A horizontal bar with one stretch per presence segment.
struct PresenceBar: View {
    let segments: [PresenceSegment]
    let window: DateInterval

    static func color(_ state: PresenceState) -> Color {
        switch state {
        case .online: .green
        case .offline: Color(nsColor: .systemGray)
        case .unknown: Color(nsColor: .quaternaryLabelColor)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(Self.color(segment.state))
                        .frame(width: max(0, geometry.size.width * segment.duration / max(window.duration, 1)))
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel("Presence")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let total = max(window.duration, 1)
        return [PresenceState.online, .offline, .unknown].map { state in
            let share = segments.filter { $0.state == state }.reduce(0) { $0 + $1.duration } / total
            return "\(state.rawValue.capitalized) \(share.formatted(.percent.precision(.fractionLength(0))))"
        }.joined(separator: ", ")
    }
}

struct PresenceLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach([PresenceState.unknown, .offline, .online], id: \.self) { state in
                HStack(spacing: 4) {
                    Circle().fill(PresenceBar.color(state)).frame(width: 7, height: 7)
                    Text(state.rawValue.capitalized)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - DNS activity

struct ClientDNSActivitySection: View {
    let entry: ClientListEntry
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let feed = environment.clientDNS.feed(for: entry.mac)
        let paused = environment.clientDNS.paused
        Group {
            if let unavailable = feed?.unavailable {
                ContentUnavailableView("DNS activity", systemImage: "list.bullet", description: Text(unavailable == .noAddress
                    ? "This client has no IP address, so its DNS requests cannot be matched."
                    : "AdGuard Home is not set up for this router, so DNS requests are not available."))
            } else if let activity = feed?.activity {
                content(activity, failure: feed?.failure, paused: paused)
            } else if let failure = feed?.failure {
                ContentUnavailableView("DNS activity unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(failure.failureCategory.message))
            } else if paused {
                ContentUnavailableView("DNS activity is paused", systemImage: "pause.circle",
                                       description: Text("Resume to load this client's requests."))
            } else {
                ProgressView("Loading DNS activity…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func content(_ activity: ClientQueryActivity, failure: RefreshFailureCategory?, paused: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 24) {
                    recentRequests(activity, paused: paused).frame(minWidth: 300, maxWidth: .infinity)
                    TopDomainList(title: "Top requested", items: activity.topRequested, tint: .accentColor)
                        .frame(minWidth: 180, maxWidth: 280)
                    TopDomainList(title: "Top blocked", items: activity.topBlocked, tint: .red)
                        .frame(minWidth: 180, maxWidth: 280)
                }
                Text(ClientDetailsFormat.dnsWindow(activity)).font(.subheadline).foregroundStyle(.secondary)
                if let failure {
                    Label("The last update failed. \(failure.failureCategory.message)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func recentRequests(_ activity: ClientQueryActivity, paused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent requests").font(.headline)
                Spacer()
                Text(ClientDetailsFormat.dnsHeader(activity, paused: paused)).font(.subheadline).foregroundStyle(.secondary)
            }
            if activity.entries.isEmpty {
                Text("No requests from this client in the query log.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Time"); Text("Domain"); Text("Result")
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    ForEach(Array(activity.entries.prefix(ClientDetailsFormat.recentLimit).enumerated()), id: \.offset) { _, item in
                        let result = ClientDetailsFormat.resultText(item.result)
                        GridRow {
                            Text(ClientDetailsFormat.time(item.time)).font(.body.monospaced()).monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(item.domain ?? ClientsFormat.unknown).font(.body.monospaced())
                                .lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 5) {
                                StatusDot(tone: result.tone)
                                Text(result.text)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

struct TopDomainList: View {
    let title: String
    let items: [DomainCount]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("Top \(ClientQueryActivity.topCount)").font(.subheadline).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text("None in this window.").font(.subheadline).foregroundStyle(.secondary)
            }
            let largest = max(items.first?.count ?? 1, 1)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("\(index + 1)").foregroundStyle(.secondary).monospacedDigit()
                        Text(item.domain).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(item.count.formatted()).foregroundStyle(tint).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(tint).frame(width: geometry.size.width * Double(item.count) / Double(largest))
                        }
                    }
                    .frame(height: 3)
                    .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - VPN routing

struct ClientVPNRoutingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 10) {
                    DetailGroup(model: DetailGroupModel(title: "Client-specific route", rows: ClientDetailsFormat.vpnClientRows))
                    Text(ClientDetailsFormat.vpnFootnote).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: 260, maxWidth: .infinity)
                VStack(alignment: .trailing, spacing: 14) {
                    DetailGroup(model: DetailGroupModel(title: "Global policy (read-only)", rows: ClientDetailsFormat.vpnGlobalRows))
                    Button("Open VPN Settings…") { model.selection = .vpn }
                }
                .frame(minWidth: 260, maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - Personalise

struct ClientPersonaliseSection: View {
    let entry: ClientListEntry
    @Environment(AppEnvironment.self) private var environment
    @State private var name = ""
    @State private var category: DeviceCategory?
    @State private var notes = ""
    @State private var saving = false
    @State private var confirmingClear = false

    private var record: DeviceRecord? { entry.record }
    private var changed: Bool {
        let saved = record?.profile ?? DeviceProfile()
        return name.trimmingCharacters(in: .whitespacesAndNewlines) != (saved.userName ?? "")
            || category != saved.category
            || notes.trimmingCharacters(in: .whitespacesAndNewlines) != saved.notes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 22) {
                    form.frame(minWidth: 320, maxWidth: .infinity)
                    VStack(spacing: 12) {
                        PaneSwitch(title: "Favourite", detail: "Pin to the top of the client list.",
                                   isOn: record?.favourite == true, disabled: record == nil) { value in
                            Task { await environment.clients.edit(entry.mac, .setFavourite(value)) }
                        }
                        PaneSwitch(title: "Monitor availability",
                                   detail: "Notify when offline for more than 5 minutes. Notifications are not sent yet.",
                                   isOn: record?.monitored == true, disabled: record == nil) { value in
                            Task { await environment.clients.edit(entry.mac, .setMonitored(value)) }
                        }
                    }
                    .frame(width: 300)
                }
                HStack(spacing: 10) {
                    ClientNoticeLine(mac: entry.mac)
                    Spacer()
                    Text(ClientDetailsFormat.personalised(record)).font(.subheadline).foregroundStyle(.secondary)
                    Button("Clear Profile") { confirmingClear = true }
                        .disabled(record == nil || saving || record?.profile == DeviceProfile())
                    Button("Save Profile") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(record == nil || saving || !changed)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .task(id: entry.mac) { load() }
        .onChange(of: record?.profile) { _, _ in if !changed { load() } }
        .alert("Clear this device’s profile?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Profile") { clear() }
        } message: {
            Text("Routewell removes the display name, category, notes, favourite, and monitoring settings stored on this Mac. The router is not changed.")
        }
    }

    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Display name").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                TextField("Display name", text: $name, prompt: Text(ClientsFormat.name(entry, mode: .automatic)))
                    .labelsHidden()
                    .frame(maxWidth: 260)
            }
            GridRow {
                Text("Category").foregroundStyle(.secondary)
                Picker("Category", selection: $category) {
                    Text("Not set").tag(DeviceCategory?.none)
                    ForEach(DeviceCategory.allCases, id: \.self) { value in
                        Text(ClientsFormat.category(value) ?? "").tag(Optional(value))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow(alignment: .top) {
                Text("Private notes").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $notes)
                        .font(.body)
                        .frame(minHeight: 70, maxHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator, lineWidth: 1))
                        .accessibilityLabel("Private notes")
                    Text("Stored on this Mac and matched by MAC address. Router configuration is not changed.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(record == nil)
    }

    private func load() {
        let profile = record?.profile ?? DeviceProfile()
        name = profile.userName ?? ""
        category = profile.category
        notes = profile.notes
    }

    private func save() {
        saving = true
        let edit = DeviceProfileEdit.save(userName: name, category: category, notes: notes)
        Task {
            await environment.clients.edit(entry.mac, edit)
            saving = false
            load()
        }
    }

    private func clear() {
        saving = true
        Task {
            await environment.clients.edit(entry.mac, .clear)
            saving = false
            load()
        }
    }
}

// MARK: - Forget device

struct ClientForgetSection: View {
    let entry: ClientListEntry
    let now: Date
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        let history = model.presence.devices[entry.mac]
        let state = ClientDetailsFormat.forgetState(entry, inventoryLoaded: model.clientInventory != nil)
        ScrollView {
            HStack(alignment: .top, spacing: 30) {
                DetailGroup(model: DetailGroupModel(title: "Saved on this Mac",
                                                    rows: ClientDetailsFormat.savedOnThisMac(entry, history: history, now: now)))
                    .frame(minWidth: 280, maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    PaneBox {
                        Text("Forget this device").font(.headline)
                        Text("Removes saved presence history, notes and preferences from this Mac. Router configuration is not changed.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .center, spacing: 10) {
                            if let status = state.status {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    StatusDot(tone: state.tone)
                                    Text(status).font(.subheadline).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            Spacer(minLength: 8)
                            Button("Forget Device…") { confirming = true }
                                .disabled(!state.enabled)
                        }
                        .padding(.top, 4)
                    }
                    ClientNoticeLine(mac: entry.mac)
                }
                .frame(minWidth: 280, maxWidth: 420)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .forgetDeviceAlert(isPresented: $confirming, entry: entry)
    }
}

extension View {
    /// The one Forget Device… confirmation.
    func forgetDeviceAlert(isPresented: Binding<Bool>, entry: ClientListEntry?) -> some View {
        modifier(ForgetDeviceAlert(isPresented: isPresented, entry: entry))
    }
}

private struct ForgetDeviceAlert: ViewModifier {
    @Binding var isPresented: Bool
    let entry: ClientListEntry?
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        content.alert("Forget \(entry.map { ClientsFormat.name($0, mode: .automatic) } ?? "this device")?", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Forget Device") {
                guard let entry else { return }
                let online = ClientDetailsFormat.onlineForForget(entry, inventoryLoaded: model.clientInventory != nil)
                Task { await environment.clients.forget(entry.mac, online: online) }
            }
        } message: {
            Text("Routewell removes its saved presence history, notes, and preferences for this device from this Mac. The router is not changed.")
        }
    }
}
