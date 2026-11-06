import SwiftUI
import Charts
import DeckCore

extension PrefKey {
    /// `StatsHistoryRange` raw value for the Dashboard charts.
    static let dashboardRange = "dashboard.statsRange"
}

/// One line on a history chart.
struct HistoryLine: Identifiable {
    let id: String
    let title: String
    let color: Color
    let value: (StatsPoint) -> Double?
}

/// Time chart over saved stats history. The x axis is the whole window ending now, so a
/// short history sits on the right. Gaps (app closed, no stats screen open) break the line.
struct HistoryChart: View {
    let points: [StatsPoint]
    let lines: [HistoryLine]
    let range: StatsHistoryRange
    let now: Date
    var minimumTop: Double
    var label: (Double) -> String
    var height: CGFloat = 92
    var showsArea = true
    var showsTimeAxis = true
    /// Same width for every y label, so stacked charts line up their plots and grid lines.
    var axisLabelWidth: CGFloat = 46

    private struct Mark: Identifiable {
        let id: String
        let line: String
        let segment: String
        let time: Date
        let value: Double
        /// Only point in its segment: drawn as a dot, a line needs two.
        var alone = false
    }

    private var marks: [Mark] {
        let segments = StatsHistoryStore.segments(points, step: range.step)
        var result: [Mark] = []
        result.reserveCapacity(points.count * lines.count)
        for line in lines {
            for (index, point) in points.enumerated() {
                guard let value = line.value(point), value.isFinite else { continue }
                result.append(Mark(
                    id: "\(line.id)-\(index)",
                    line: line.id,
                    segment: "\(line.id)-\(segments[index])",
                    time: point.time,
                    value: max(0, value)
                ))
            }
        }
        var counts: [String: Int] = [:]
        for mark in result { counts[mark.segment, default: 0] += 1 }
        for index in result.indices where counts[result[index].segment] == 1 { result[index].alone = true }
        return result
    }

    private var top: Double {
        let peak = marks.map(\.value).max() ?? 0
        return HistoryScale.niceTop(max(minimumTop, peak * 1.15))
    }

    private var domain: ClosedRange<Date> {
        now.addingTimeInterval(-range.seconds)...now
    }

    var body: some View {
        let marks = self.marks
        let top = self.top
        Chart(marks) { mark in
            if mark.alone {
                PointMark(x: .value("Time", mark.time), y: .value("Value", mark.value))
                    .foregroundStyle(color(mark.line))
                    .symbolSize(12)
            }
            if showsArea && lines.count == 1 && !mark.alone {
                AreaMark(x: .value("Time", mark.time), y: .value("Value", mark.value), series: .value("Segment", mark.segment))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(colors: [color(mark.line).opacity(0.26), color(mark.line).opacity(0.02)], startPoint: .top, endPoint: .bottom)
                    )
            }
            LineMark(x: .value("Time", mark.time), y: .value("Value", mark.value), series: .value("Segment", mark.segment))
                .interpolationMethod(.monotone)
                .foregroundStyle(color(mark.line))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: HistoryScale.ticks(range: range, now: now)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(DS.border)
                if showsTimeAxis {
                    // Centered under its grid line.
                    AxisValueLabel(anchor: .top) {
                        if let date = value.as(Date.self) {
                            Text(HistoryScale.ago(now.timeIntervalSince(date)))
                                .font(.caption2)
                                .foregroundStyle(DS.textTertiary)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, top / 2, top]) { mark in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(DS.borderStrong)
                AxisValueLabel {
                    if let number = mark.as(Double.self) {
                        // A bare 0 at the base, so it never shows a unit that differs from the ticks above.
                        Text(number == 0 ? "0" : label(number))
                            .font(.caption2)
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                            .frame(width: axisLabelWidth, alignment: .leading)
                    }
                }
            }
        }
        .frame(height: height)
        .overlay {
            if marks.isEmpty {
                Text("No samples in this window yet")
                    .font(.caption)
                    .foregroundStyle(DS.textTertiary)
            }
        }
    }

    private func color(_ id: String) -> Color {
        lines.first { $0.id == id }?.color ?? DS.accent
    }
}

/// Legend dot and label for a chart line.
struct HistoryLegend: View {
    let lines: [HistoryLine]
    var values: [String: String] = [:]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(lines) { line in
                HStack(spacing: 5) {
                    Circle().fill(line.color).frame(width: 7, height: 7)
                    Text(line.title).font(.caption).foregroundStyle(DS.textSecondary)
                    if let value = values[line.id] {
                        Text(value).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(DS.textPrimary)
                    }
                }
            }
        }
    }
}

/// Tiny line with no axes, for rows.
struct HistorySparkline: View {
    let points: [StatsPoint]
    let value: (StatsPoint) -> Double?
    let range: StatsHistoryRange
    let now: Date
    var color: Color = DS.accent
    var minimumTop: Double = 10

    private struct Mark: Identifiable {
        let id: Int
        let segment: Int
        let time: Date
        let value: Double
    }

    var body: some View {
        let segments = StatsHistoryStore.segments(points, step: range.step)
        let marks = points.enumerated().compactMap { index, point -> Mark? in
            guard let v = value(point), v.isFinite else { return nil }
            return Mark(id: index, segment: segments[index], time: point.time, value: max(0, v))
        }
        let top = max(minimumTop, (marks.map(\.value).max() ?? 0) * 1.15)
        Chart(marks) { mark in
            AreaMark(x: .value("Time", mark.time), y: .value("Value", mark.value), series: .value("Segment", mark.segment))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", mark.time), y: .value("Value", mark.value), series: .value("Segment", mark.segment))
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
        }
        .chartXScale(domain: now.addingTimeInterval(-range.seconds)...now)
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}

enum HistoryScale {
    /// Rounds a chart top up to 1, 2 or 5 times a power of ten (or of 1024 for bytes, close enough).
    static func niceTop(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        let power = pow(10, floor(log10(value)))
        for factor in [1.0, 2.0, 2.5, 5.0, 10.0] where factor * power >= value {
            return factor * power
        }
        return 10 * power
    }

    /// Grid lines inside the window, so no label sits on an edge.
    static func ticks(range: StatsHistoryRange, now: Date) -> [Date] {
        let minutes: [Double]
        switch range {
        case .fiveMinutes: minutes = [4, 3, 2, 1]
        case .fifteenMinutes: minutes = [12, 9, 6, 3]
        case .hour: minutes = [45, 30, 15]
        case .day: minutes = [18 * 60, 12 * 60, 6 * 60]
        }
        return minutes.map { now.addingTimeInterval(-$0 * 60) }
    }

    /// "6m ago", "12h ago"
    static func ago(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 120 { return "\(minutes / 60)h ago" }
        return "\(max(minutes, 1))m ago"
    }

    /// "1.2 MB/s"
    static func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 1 else { return "0 B/s" }
        if value < 1024 { return "\(Int(value)) B/s" }
        return Format.bytes(UInt64(min(value, 1e18))) + "/s"
    }
}
