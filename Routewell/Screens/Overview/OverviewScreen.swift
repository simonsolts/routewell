import SwiftUI
import RoutewellKit

struct OverviewScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let snapshot = model.snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    statStrip(snapshot)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 22) {
                            leftColumn(snapshot).frame(minWidth: 330)
                            rightColumn(snapshot).frame(minWidth: 330)
                        }
                        VStack(spacing: 22) { leftColumn(snapshot); rightColumn(snapshot) }
                    }
                    HStack {
                        if model.refreshFailed {
                            Label("Refresh failed. Showing the last sample.", systemImage: "exclamationmark.triangle")
                        } else if model.isRefreshing {
                            Text("Refreshing sample data…")
                        } else {
                            Text("Sample updated \(snapshot.observedAt, style: .relative) ago")
                        }
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
            StatCell(title: "VPN", status: "Unknown", tone: .unknown, detail: "No tunnel data loaded")
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }

    private func leftColumn(_ snapshot: OverviewSnapshot) -> some View {
        VStack(spacing: 22) {
            InsetGroup(title: "Health", footnote: "Sample observations only. Live health checks and freshness warnings are not available yet.") {
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
