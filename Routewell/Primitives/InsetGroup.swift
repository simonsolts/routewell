import SwiftUI
import RoutewellKit
import Charts

struct InsetGroup<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal, 2)
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

struct LabelValueRow: View {
    let label: String
    let value: String
    var tone: StatusTone? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(tone?.color ?? .secondary)
                .multilineTextAlignment(.trailing).textSelection(.enabled).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(minHeight: 38)
    }
}

struct MeterRow: View {
    let fraction: Double
    let detail: String
    let history: [Double]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Memory")
                Spacer()
                Text(fraction, format: .percent.precision(.fractionLength(1))).monospacedDigit()
            }
            HStack(spacing: 16) {
                ProgressView(value: fraction).accessibilityLabel("Memory used")
                Chart(Array(history.enumerated()), id: \.offset) { sample in
                    LineMark(x: .value("Sample", sample.offset), y: .value("Usage", sample.element))
                        .foregroundStyle(.secondary)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...1)
                .frame(width: 100, height: 20)
                .accessibilityLabel("Synthetic memory history")
            }
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }.padding(12)
    }
}
