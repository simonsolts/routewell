import SwiftUI
import RoutewellKit

enum StatusTone {
    case healthy, attention, degraded, error, unknown
    var color: Color {
        switch self {
        case .healthy: .green
        case .attention: .yellow
        case .degraded: .orange
        case .error: .red
        case .unknown: .secondary
        }
    }
}

extension Reachability {
    var tone: StatusTone {
        switch self { case .connected: .healthy; case .unreachable: .error; case .unknown: .unknown }
    }
    var label: String {
        switch self { case .connected: "Connected"; case .unreachable: "Unreachable"; case .unknown: "Unknown" }
    }
}

struct StatusDot: View {
    let tone: StatusTone
    var body: some View {
        Circle().fill(tone.color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

struct StatusPillView: View {
    let snapshot: OverviewSnapshot?
    var body: some View {
        HStack(spacing: 12) {
            item("Router", state: snapshot?.router.reachability ?? .unknown)
            item("Internet", state: snapshot?.internet.reachability ?? .unknown)
            item("AdGuard", state: snapshot?.adGuard.reachability ?? .unknown)
            item("VPN", state: .unknown)
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }
    private func item(_ title: String, state: Reachability) -> some View {
        HStack(spacing: 5) { StatusDot(tone: state.tone); Text(title) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title): \(state.label)")
    }
}

struct StatCell: View {
    let title: String
    let status: String
    let tone: StatusTone
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 7) {
                StatusDot(tone: tone)
                Text(status).font(.title3).fontWeight(.medium)
            }
            Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .padding(14)
    }
}
