import Charts
import SwiftUI

/// Formatting helpers shared by the stats cards.
enum StatsFormat {
    /// Whole/one-decimal hours with grouped thousands, e.g. "1,240 h", "8.5 h".
    static func hours(_ seconds: Int) -> String {
        let h = Double(seconds) / 3600
        if seconds == 0 { return "0 h" }
        if h < 10 { return String(format: "%.1f h", h) }
        return "\(Int(h.rounded()).formatted()) h"
    }

    /// A count with grouped thousands.
    static func count(_ n: Int) -> String { n.formatted() }

    /// A 0…1 ratio as a whole-number percentage, e.g. "72 %".
    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded())) %"
    }

    /// A derived score to one decimal (1.0…10.0).
    static func score(_ value: Double) -> String { String(format: "%.1f", value) }

    /// The decade label ("1990s") or "Unknown".
    static func decade(_ decade: Int?) -> String {
        decade.map { "\($0)s" } ?? "Unknown"
    }
}

/// One bar in a horizontal category chart.
struct StatsBar: Identifiable, Equatable {
    var id: String
    var label: String
    var value: Double
    var valueText: String
    var colorHex: String?

    var color: Color { Color(hex: colorHex) ?? .accentColor }
}

/// A horizontal bar chart of labelled categories, drawn in the given order
/// (first = top). Value text is annotated at the bar's trailing edge.
struct StatsHBarChart: View {
    let bars: [StatsBar]
    var rowHeight: CGFloat = 26

    private var maxValue: Double { max(bars.map(\.value).max() ?? 1, 1) }

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("Value", bar.value),
                y: .value("Category", bar.label)
            )
            .foregroundStyle(bar.color)
            .cornerRadius(3)
            .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                Text(bar.valueText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .chartYScale(domain: bars.map(\.label).reversed())   // preserve caller order, top-first
        .chartXScale(domain: 0...(maxValue * 1.18))          // headroom for the annotation
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { _ in
                AxisValueLabel(horizontalSpacing: 6)
            }
        }
        .frame(height: CGFloat(bars.count) * rowHeight + 8)
    }
}

/// One column in a vertical histogram.
struct StatsColumn: Identifiable, Equatable {
    var id: String
    var label: String
    var value: Double
    var colorHex: String?

    var color: Color { Color(hex: colorHex) ?? .accentColor }
}

/// A vertical histogram (release years, activity months …). X labels are thinned
/// automatically by Swift Charts when there are many columns.
struct StatsColumnChart: View {
    let columns: [StatsColumn]
    var height: CGFloat = 150

    var body: some View {
        Chart(columns) { col in
            BarMark(
                x: .value("Category", col.label),
                y: .value("Value", col.value)
            )
            .foregroundStyle(col.color)
            .cornerRadius(2)
        }
        .chartXScale(domain: columns.map(\.label))
        .chartYAxis {
            AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() }
        }
        .frame(height: height)
    }
}

/// A compact key/number row used inside cards.
struct StatsMetricRow: View {
    let label: String
    let value: String
    var emphasised = false

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .fontWeight(emphasised ? .semibold : .regular)
        }
        .font(.callout)
    }
}

/// The titled container every stats section sits in.
struct StatsCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// Shown inside a card when its section has no data yet.
struct StatsCardEmpty: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}
