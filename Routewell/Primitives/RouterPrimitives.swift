import SwiftUI
import RoutewellKit
import Charts

/// A 120×20 line in tertiary colour; values are 0…1.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { sample in
            LineMark(x: .value("Sample", sample.offset), y: .value("Value", sample.element))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...1)
        .accessibilityHidden(true)
    }
}

/// A grouped inset with an optional button at the right of its title.
struct HeaderInset<Content: View, Accessory: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                accessory()
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0, content: content)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
            if let footnote {
                Text(footnote).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }
}

extension HeaderInset where Accessory == EmptyView {
    init(title: String, footnote: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footnote = footnote
        self.accessory = { EmptyView() }
        self.content = content
    }
}

/// Label with an optional second line on the left; value with an optional
/// status dot on the right.
struct RouterRow: View {
    let row: RouterRowModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                if let detail = row.detail, !detail.isEmpty {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if let tone = row.tone { StatusDot(tone: tone) }
            Text(row.value)
                .font(row.monospaced ? .body.monospaced() : .body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 38)
        .accessibilityElement(children: .combine)
    }
}

/// Rows with hairline separators inside a `HeaderInset`.
struct RouterRows: View {
    let rows: [RouterRowModel]

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            if index > 0 { Divider().padding(.leading, 12) }
            RouterRow(row: row)
        }
    }
}

/// A small read-only table with a header row, for insets that hold a few
/// rows (Wi-Fi bands, WAN interfaces). Not sortable, no selection.
struct InsetTable: View {
    let columns: [String]
    let rows: [[RouterCell]]
    var emptyText = "Nothing reported"

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                    Text(column).font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: index == 0 ? nil : .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 6)
            Divider().gridCellUnsizedAxes(.horizontal)
            if rows.isEmpty {
                Text(emptyText).foregroundStyle(.secondary).padding(.vertical, 8)
                    .gridCellColumns(columns.count)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                        HStack(spacing: 5) {
                            if let tone = cell.tone { StatusDot(tone: tone) }
                            Text(cell.text)
                                .font(cell.monospaced ? .body.monospaced() : .body)
                                .monospacedDigit()
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        // The first column (SSID, interface) keeps its full text.
                        .fixedSize(horizontal: index == 0, vertical: false)
                        .frame(maxWidth: index == 0 ? nil : .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 5)
                .accessibilityElement(children: .combine)
                if index < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
