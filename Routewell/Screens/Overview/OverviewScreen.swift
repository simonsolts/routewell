import SwiftUI
import RoutewellKit

struct OverviewScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let snapshot = displayedSnapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    statStrip(snapshot)
                    freshnessGroup
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 22) {
                            leftColumn(snapshot).frame(minWidth: 330)
                            rightColumn(snapshot).frame(minWidth: 330)
                        }
                        VStack(spacing: 22) { leftColumn(snapshot); rightColumn(snapshot) }
                    }
                    HStack {
                        Text(model.refreshFailed ? "One or more areas could not refresh." : "Each area keeps its last successful observation.")
                        Spacer()
                    }.font(.subheadline).foregroundStyle(.secondary)
                }.padding(20)
            }
        } else if model.mode == .mock {
            if model.session.setupFailed || model.refreshFailed {
                ContentUnavailableView("Sample unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Choose a mock profile in Settings to try again."))
            } else {
                ProgressView(model.session.switching ? "Switching mock router…" : "Loading sample data…")
            }
        } else {
            ContentUnavailableView {
                Label(model.mode == .invalid ? "Backend unavailable" : "Welcome to Routewell", systemImage: "wifi.router")
            } description: {
                Text(model.mode == .invalid
                     ? "This build does not support the requested backend. Choose the Routewell (Mock) scheme in Xcode."
                     : "Router connections are coming in a later build. Explore the interface with the Routewell (Mock) scheme in Xcode.")
            }
        }
    }

    private var displayedSnapshot: OverviewSnapshot? {
        if let snapshot = model.snapshot { return snapshot }
        guard !model.freshness.isEmpty else { return nil }
        return OverviewSnapshot(observedAt: model.evaluatedAt)
    }

    private func statStrip(_ snapshot: OverviewSnapshot) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4), spacing: 0) {
            StatCell(title: "Router", status: snapshot.router.reachability.label,
                     tone: snapshot.router.reachability.tone,
                     detail: "\(snapshot.router.model ?? "Unknown model") · firmware \(snapshot.router.firmware ?? "Unknown")")
            StatCell(title: "Internet", status: snapshot.internet.reachability.label,
                     tone: snapshot.internet.reachability.tone,
                     detail: snapshot.internet.publicAddress ?? "No address observed")
            StatCell(title: "AdGuard Home", status: snapshot.adGuard.reachability == .connected ? "Active" : snapshot.adGuard.reachability.label,
                     tone: snapshot.adGuard.reachability.tone,
                     detail: "\(number(snapshot.adGuard.queriesToday)) queries today")
            StatCell(title: "Clients", status: clientCount(snapshot.clients),
                     tone: clientTone(snapshot.clients), detail: "Active devices observed")
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }

    private func leftColumn(_ snapshot: OverviewSnapshot) -> some View {
        VStack(spacing: 22) {
            InsetGroup(title: "Health", footnote: "Unknown observations remain unknown. Load averages are not CPU utilization.") {
                healthRow("Internet", value: snapshot.internet.reachability.label,
                          tone: snapshot.internet.reachability.tone, destination: .network)
                Divider()
                healthRow("Router", value: snapshot.router.reachability.label,
                          tone: snapshot.router.reachability.tone, destination: .router)
                Divider()
                healthRow("Wi-Fi", value: "Not observed", tone: .unknown, destination: .network)
                Divider()
                healthRow("LAN", value: "Not observed", tone: .unknown, destination: .clients)
                Divider()
                healthRow("DNS", value: snapshot.adGuard.reachability.label,
                          tone: snapshot.adGuard.reachability.tone, destination: .protection)
                Divider()
                healthRow("Storage", value: "Not observed", tone: .unknown, destination: .maintenance)
                Divider()
                healthRow("VPN", value: "Not observed", tone: .unknown, destination: .vpn)
            }
            InsetGroup(title: "AdGuard Home") {
                LabelValueRow(label: "Protection", value: protection(snapshot.adGuard.protection), tone: .degraded)
                Divider()
                LabelValueRow(label: "Version", value: snapshot.adGuard.version ?? "Unknown")
                Divider()
                LabelValueRow(label: "Queries today", value: number(snapshot.adGuard.queriesToday))
                Divider()
                LabelValueRow(label: "Blocked today", value: number(snapshot.adGuard.blockedToday))
                Divider()
                Button("Open Protection") { model.selection = .protection }
                    .buttonStyle(.link).padding(12).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.frame(maxWidth: .infinity)
    }

    private var freshnessGroup: some View {
        InsetGroup(title: "Data freshness") {
            ForEach(DataArea.allCases, id: \.self) { area in
                if area != .router { Divider() }
                let freshness = model.freshness[area] ?? Freshness()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(areaLabel(area))
                        Text(sourceLabel(freshness.source)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(freshnessSubtitle(freshness))
                        .foregroundStyle(freshness.failure == nil ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
        }
    }

    private func rightColumn(_ snapshot: OverviewSnapshot) -> some View {
        VStack(spacing: 22) {
            InsetGroup(title: "Router") {
                LabelValueRow(label: "Load averages", value: snapshot.router.loadAverages.isEmpty ? "Unknown" : snapshot.router.loadAverages.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " / "))
                Divider()
                if let used = snapshot.router.memoryUsedBytes, let total = snapshot.router.memoryTotalBytes, total > 0 {
                    MeterRow(fraction: Double(used) / Double(total),
                             detail: "\(ByteCountFormatter.string(fromByteCount: used, countStyle: .binary)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)) used",
                             history: snapshot.router.memoryHistory)
                } else {
                    LabelValueRow(label: "Memory", value: "Unknown")
                }
                Divider()
                LabelValueRow(label: "Temperature", value: temperature(snapshot.router.temperatureCelsius))
                Divider()
                LabelValueRow(label: "Uptime", value: uptime(snapshot.router.uptimeSeconds))
                Divider()
                LabelValueRow(label: "OpenWrt", value: snapshot.router.openWrtVersion ?? "Unknown")
            }
            InsetGroup(title: "Internet") {
                LabelValueRow(label: "Public address", value: snapshot.internet.publicAddress ?? "Unknown")
                Divider()
                LabelValueRow(label: "Gateway", value: snapshot.internet.gateway ?? "Unknown")
                Divider()
                LabelValueRow(label: "Gateway latency", value: snapshot.internet.gatewayLatencyMilliseconds.map { "\($0.formatted()) ms" } ?? "Unknown")
                Divider()
                LabelValueRow(label: "External DNS", value: snapshot.internet.dnsServers.isEmpty ? "Unknown" : snapshot.internet.dnsServers.joined(separator: ", "))
                Divider()
                LabelValueRow(label: "LAN", value: snapshot.router.lanAddress ?? "Unknown")
            }
        }.frame(maxWidth: .infinity)
    }

    private func healthRow(_ title: String, value: String, tone: StatusTone, destination: SidebarDestination) -> some View {
        Button { model.selection = destination } label: {
            HStack(spacing: 9) {
                StatusDot(tone: tone)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(value).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(title): \(value). Open \(destination.title)")
    }

    private func number(_ value: Int?) -> String { value?.formatted() ?? "Unknown" }
    private func clientCount(_ status: ClientStatus) -> String {
        switch status.activeCount {
        case .value(let count): count.formatted()
        case .unavailable: "Unavailable"
        case .unknown: "Unknown"
        }
    }
    private func clientTone(_ status: ClientStatus) -> StatusTone {
        if case .value = status.activeCount { return .healthy }
        return .unknown
    }
    private func areaLabel(_ area: DataArea) -> String {
        switch area { case .router: "Router"; case .internet: "Internet"; case .adGuard: "AdGuard Home"; case .clients: "Clients" }
    }
    private func sourceLabel(_ source: ObservationSource?) -> String {
        switch source { case .mock: "Mock source"; case .routerRPC: "Router RPC"; case .adGuardAPI: "AdGuard API"; case nil: "No source" }
    }
    private func freshnessSubtitle(_ freshness: Freshness) -> String {
        if freshness.isRefreshing { return String(localized: "Refreshing…") }
        if freshness.failure != nil {
            guard let lastSuccess = freshness.lastSuccess else { return String(localized: "Refresh failed · no data loaded") }
            return String(localized: "Refresh failed · last data \(relative(lastSuccess))")
        }
        guard let lastSuccess = freshness.lastSuccess else { return String(localized: "Never loaded") }
        return relative(lastSuccess)
    }
    private func relative(_ date: Date) -> String {
        if abs(model.evaluatedAt.timeIntervalSince(date)) < 1 { return String(localized: "Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: model.evaluatedAt)
    }
    private func protection(_ value: ProtectionState) -> String {
        switch value {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .paused(let until): "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        case .unknown: "Unknown"
        }
    }
    private func temperature(_ value: Observed<Double>) -> String {
        switch value { case .value(let degrees): "\(degrees.formatted()) °C"; case .unavailable: "Unavailable"; case .unknown: "Unknown" }
    }
    private func uptime(_ seconds: Int?) -> String {
        guard let seconds else { return "Unknown" }
        return "\(seconds / 86400)d \((seconds % 86400) / 3600)h"
    }
}
