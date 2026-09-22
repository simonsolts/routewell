import SwiftUI
import RoutewellKit

/// "N new devices awaiting review": one row per device with its
/// first-observed text and a Review… button that opens it in the table.
/// Row shape follows the v1 banner until a v2 mock exists `[assumed]`.
struct NewDevicesSheet: View {
    let rows: [ReviewRowModel]
    let onReview: (MACAddress) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New devices").font(.headline)
            Text("These devices joined after Routewell first recorded your network. Review one to open its details.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                Text("No devices are awaiting review.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 12) {
                            Image(systemName: row.symbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                Text(row.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Text(row.firstObserved).font(.subheadline).foregroundStyle(.secondary)
                            Button("Review…") { onReview(row.mac) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .accessibilityElement(children: .contain)
                        if index < rows.count - 1 { Divider() }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
            }
            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
