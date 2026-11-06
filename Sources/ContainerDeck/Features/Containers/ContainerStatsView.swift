import SwiftUI
import Charts
import DeckCore

/// Live charts for one container: CPU, memory, network and disk.
/// Reads the shared sampler, so charts show history at once when the list or the
/// Dashboard was already sampling, and no second stats process runs.
struct ContainerStatsView: View {
    @Environment(AppState.self) private var state

    let containerID: String
    let isRunning: Bool

    init(containerID: String, isRunning: Bool) {
        self.containerID = containerID
        self.isRunning = isRunning
    }

    private var samples: [ContainerStatsSample] {
        let sampler = StatsSampler.shared
        if let list = sampler.history[containerID] { return list }
        if let id = BackgroundServices.shared.container(containerID)?.id, let list = sampler.history[id] { return list }
        return []
    }

    var body: some View {
        Group {
            if !isRunning {
                EmptyState(icon: .stats, title: "Container is stopped", message: "Start the container to see live stats.")
            } else {
                DeckPage {
                    tiles
                    EqualHeightRow {
                        Card("CPU", icon: .cpu) {
                            ContainerCPUChart(samples: samples)
                        }
                        Card("Memory", icon: .memory) {
                            ContainerBytesChart(samples: samples, series: [
                                ContainerChartSeries(name: "Used", color: DS.accent, value: \.memoryBytes)
                            ], perSecond: false)
                        }
                    }
                    EqualHeightRow {
                        Card("Network", icon: .network) {
                            ContainerBytesChart(samples: Array(samples.dropFirst()), series: [
                                ContainerChartSeries(name: "In", color: DS.accent, value: \.netRxPerSec),
                                ContainerChartSeries(name: "Out", color: DS.textSecondary, value: \.netTxPerSec, dashed: true)
                            ], perSecond: true)
                        }
                        Card("Disk", icon: .disk) {
                            ContainerBytesChart(samples: Array(samples.dropFirst()), series: [
                                ContainerChartSeries(name: "Read", color: DS.accent, value: \.diskReadPerSec),
                                ContainerChartSeries(name: "Write", color: DS.textSecondary, value: \.diskWritePerSec, dashed: true)
                            ], perSecond: true)
                        }
                    }
                }
            }
        }
        .usesLiveStats("stats-tab", active: isRunning)
    }

    private var latest: ContainerStatsSample? { samples.last }

    /// One full row of four tiles. Process count rides along under CPU.
    private var tiles: some View {
        EqualHeightRow(spacing: 12) {
            MetricTile(
                title: "CPU",
                value: latest.map { $0.cpuMeasured ? Format.percent($0.cpuPercent) : "Measuring" } ?? "Measuring",
                subtitle: latest.map { $0.pids == 1 ? "1 process" : "\($0.pids) processes" },
                icon: .cpu
            )
            MetricTile(
                title: "Memory",
                value: latest.map { ContainerFormat.bytes($0.memoryBytes) } ?? "-",
                subtitle: memorySubtitle,
                icon: .memory
            )
            MetricTile(
                title: "Network",
                value: latest.map { ContainerFormat.rate($0.netRxPerSec + $0.netTxPerSec) } ?? "-",
                subtitle: latest.map { "In \(ContainerFormat.rate($0.netRxPerSec)), out \(ContainerFormat.rate($0.netTxPerSec))" },
                icon: .network
            )
            MetricTile(
                title: "Disk",
                value: latest.map { ContainerFormat.rate($0.diskReadPerSec + $0.diskWritePerSec) } ?? "-",
                subtitle: latest.map { "Read \(ContainerFormat.rate($0.diskReadPerSec)), write \(ContainerFormat.rate($0.diskWritePerSec))" },
                icon: .disk
            )
        }
    }

    private var memorySubtitle: String? {
        guard let latest, latest.memoryLimitBytes > 0 else { return nil }
        let percent = latest.memoryBytes / latest.memoryLimitBytes * 100
        return "\(Format.percent(percent)) of \(ContainerFormat.bytes(latest.memoryLimitBytes))"
    }
}

/// One line on a byte chart.
struct ContainerChartSeries {
    let name: String
    let color: Color
    let value: KeyPath<ContainerStatsSample, Double>
    var dashed: Bool = false
}

/// CPU percent over time.
struct ContainerCPUChart: View {
    let samples: [ContainerStatsSample]
    let height: CGFloat

    init(samples: [ContainerStatsSample], height: CGFloat = 170) {
        self.samples = samples
        self.height = height
    }

    /// Only samples with a real CPU value (two readings).
    private var measured: [ContainerStatsSample] {
        samples.filter(\.cpuMeasured)
    }

    var body: some View {
        Chart(measured) { sample in
            if measured.count == 1 {
                PointMark(x: .value("Time", sample.date), y: .value("CPU", sample.cpuPercent))
                    .foregroundStyle(DS.accent)
            }
            AreaMark(
                x: .value("Time", sample.date),
                y: .value("CPU", sample.cpuPercent)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(
                LinearGradient(
                    colors: [DS.accent.opacity(0.35), DS.accent.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            LineMark(
                x: .value("Time", sample.date),
                y: .value("CPU", sample.cpuPercent)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(DS.accent)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartYScale(domain: 0...max(100, (measured.map(\.cpuPercent).max() ?? 0) * 1.1))
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text("\(Int(number))%")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute().second())
            }
        }
        .frame(height: height)
        .overlay {
            // CPU needs two readings, about 4 seconds after the first stats call.
            if measured.isEmpty { LoadingView("Measuring", style: .chart) }
        }
    }
}

/// Bytes or bytes per second over time, one or more lines.
struct ContainerBytesChart: View {
    let samples: [ContainerStatsSample]
    let series: [ContainerChartSeries]
    let perSecond: Bool
    let height: CGFloat

    init(samples: [ContainerStatsSample], series: [ContainerChartSeries], perSecond: Bool, height: CGFloat = 170) {
        self.samples = samples
        self.series = series
        self.perSecond = perSecond
        self.height = height
    }

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let series: String
        let color: Color
        let dashed: Bool
    }

    private var points: [Point] {
        var result: [Point] = []
        result.reserveCapacity(samples.count * series.count)
        for item in series {
            for sample in samples {
                result.append(Point(
                    id: "\(item.name)-\(sample.date.timeIntervalSinceReferenceDate)",
                    date: sample.date,
                    value: sample[keyPath: item.value],
                    series: item.name,
                    color: item.color,
                    dashed: item.dashed
                ))
            }
        }
        return result
    }

    private var maxValue: Double {
        let top = points.map(\.value).max() ?? 0
        return max(top * 1.15, perSecond ? 1024 : 1024 * 1024)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chart
            if series.count > 1 {
                HStack(spacing: 14) {
                    ForEach(series, id: \.name) { item in
                        HStack(spacing: 5) {
                            Capsule()
                                .fill(item.color)
                                .frame(width: 12, height: 3)
                            Text(item.name).font(.caption).foregroundStyle(DS.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var chart: some View {
        Chart(points) { point in
            if samples.count == 1 {
                PointMark(x: .value("Time", point.date), y: .value("Value", point.value))
                    .foregroundStyle(point.color)
            }
            LineMark(
                x: .value("Time", point.date),
                y: .value("Value", point.value),
                series: .value("Series", point.series)
            )
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 2, dash: point.dashed ? [5, 3] : []))
            .foregroundStyle(point.color)
        }
        .chartYScale(domain: 0...maxValue)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(perSecond ? ContainerFormat.rate(number) : ContainerFormat.bytes(number))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute().second())
            }
        }
        .frame(height: height)
        .overlay {
            // Draws from the first sample. Rates need two, so their charts get the samples after the first.
            if samples.isEmpty { LoadingView("Measuring", style: .chart) }
        }
    }
}
