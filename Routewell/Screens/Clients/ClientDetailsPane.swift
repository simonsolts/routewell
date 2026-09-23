import SwiftUI
import RoutewellKit

/// The collapsible pane under the client table: a header strip and a
/// master-detail body with a source list. Only Overview is built in chunk 12.
struct ClientDetailsPane: View {
    let content: ClientsPaneContent
    let now: Date
    @Environment(AppModel.self) private var model

    var body: some View {
        switch content {
        case .single(let entry):
            VStack(spacing: 0) {
                header(entry)
                Divider()
                HStack(spacing: 0) {
                    sourceList(entry)
                    Divider()
                    section(entry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        case .multiple(let count):
            emptyPane("\(count) clients selected. Select one client to see its details.")
        case .none:
            emptyPane("Select a client to see its details.")
        }
    }

    private func emptyPane(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Details pane: \(text)")
    }

    private func header(_ entry: ClientListEntry) -> some View {
        let status = ClientsFormat.status(entry, now: now)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: ClientsFormat.symbol(entry.record?.category))
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(ClientsFormat.name(entry, mode: .automatic)).font(.headline)
                    HStack(spacing: 5) {
                        StatusDot(tone: status.tone)
                        Text(status.text).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    if entry.isFavourite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favourite")
                    }
                }
                Text(ClientsFormat.subtitle(entry))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            // Client actions arrive in chunk 13.
            HStack(spacing: 8) {
                Button("Ping") {}
                Button("Wake") {}
                Button("Copy Details") {}
                Button("Pause") {}
            }
            .disabled(true)
            .help("Client actions are not available yet")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func sourceList(_ entry: ClientListEntry) -> some View {
        @Bindable var model = model
        let selected = Binding<ClientDetailsSection?>(
            get: { ClientDetailsSection(rawValue: model.clientsDetailsSection) ?? .overview },
            set: { if let value = $0 { model.clientsDetailsSection = value.rawValue } }
        )
        return List(selection: selected) {
            ForEach(ClientDetailsSection.allCases) { section in
                Text(section.title)
                    .badge(section == .dnsActivity ? blockedBadge(entry) : 0)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(width: 190)
    }

    private func blockedBadge(_ entry: ClientListEntry) -> Int {
        if case .value(let count) = entry.blocked { return count }
        return 0
    }

    @ViewBuilder
    private func section(_ entry: ClientListEntry) -> some View {
        let selected = ClientDetailsSection(rawValue: model.clientsDetailsSection) ?? .overview
        if selected.isAvailable {
            ClientOverviewSection(entry: entry, now: now)
        } else {
            ContentUnavailableView(selected.title, systemImage: selected.symbol,
                                   description: Text("This section is not available yet."))
        }
    }
}

struct ClientOverviewSection: View {
    let entry: ClientListEntry
    let now: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let groups = ClientsFormat.overviewGroups(entry)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 22) {
                        ForEach(groups, id: \.title) { DetailGroup(model: $0).frame(minWidth: 220) }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(groups, id: \.title) { DetailGroup(model: $0) }
                    }
                }
                MetricStrip(metrics: ClientsFormat.overviewMetrics(entry, now: now))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}

/// A titled key/value list with hairline separators, 30 pt dense rows.
struct DetailGroup: View {
    let model: DetailGroupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title).font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if let tone = row.tone { StatusDot(tone: tone) }
                        Text(row.value)
                            .font(row.monospaced ? .body.monospaced() : .body)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 30)
                    .accessibilityElement(children: .combine)
                    if index < model.rows.count - 1 { Divider() }
                }
            }
        }
    }
}

/// One inset with up to four metric cells: caption, value, footnote.
struct MetricStrip: View {
    let metrics: [MetricModel]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(metrics, id: \.title) { metric in
                MetricCell(metric: metric)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }
}

struct MetricCell: View {
    let metric: MetricModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.title).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let tone = metric.tone { StatusDot(tone: tone) }
                Text(metric.value)
                    .font(.title2).fontWeight(.medium).monospacedDigit()
                    .foregroundStyle(metric.emphasised ? Color.orange : Color.primary)
            }
            Text(metric.detail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}
