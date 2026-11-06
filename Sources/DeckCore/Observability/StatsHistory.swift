import Foundation

// Stats history: a small time series store kept between launches.
// Two tiers per container: 2 second points for the last hour and 1 minute points for
// the last 24 hours. Samples are averaged into buckets, so the store never grows past
// `ObservabilityConfig.maxSeries` containers times (1800 + 1440) points.

/// Time windows the charts offer.
public enum StatsHistoryRange: String, CaseIterable, Sendable, Identifiable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case hour = "1h"
    case day = "24h"

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .hour: return 60 * 60
        case .day: return 24 * 60 * 60
        }
    }

    /// Short label for pickers.
    public var title: String { rawValue }

    /// "the last 15 minutes"
    public var phrase: String {
        switch self {
        case .fiveMinutes: return "Last 5 minutes"
        case .fifteenMinutes: return "Last 15 minutes"
        case .hour: return "Last hour"
        case .day: return "Last 24 hours"
        }
    }

    /// Seconds between points shown for this window.
    public var step: Int {
        self == .day ? ObservabilityConfig.coarseStep : ObservabilityConfig.fineStep
    }
}

/// One point in time. `cpuPercent` is nil when no reading in the bucket had a CPU value yet.
public struct StatsPoint: Sendable, Hashable {
    public var time: Date
    public var cpuPercent: Double?
    public var memoryBytes: Double
    public var memoryLimitBytes: Double
    public var netRxPerSec: Double
    public var netTxPerSec: Double
    public var diskReadPerSec: Double
    public var diskWritePerSec: Double

    public init(time: Date, cpuPercent: Double?, memoryBytes: Double, memoryLimitBytes: Double = 0,
                netRxPerSec: Double = 0, netTxPerSec: Double = 0, diskReadPerSec: Double = 0, diskWritePerSec: Double = 0) {
        self.time = time
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.netRxPerSec = netRxPerSec
        self.netTxPerSec = netTxPerSec
        self.diskReadPerSec = diskReadPerSec
        self.diskWritePerSec = diskWritePerSec
    }

    /// From a live reading. Rates that need an earlier reading count as 0.
    public init(_ reading: StatsReading) {
        self.init(
            time: reading.date,
            cpuPercent: reading.cpuPercent,
            memoryBytes: Double(reading.memoryBytes),
            memoryLimitBytes: Double(reading.memoryLimitBytes),
            netRxPerSec: reading.netRxPerSec ?? 0,
            netTxPerSec: reading.netTxPerSec ?? 0,
            diskReadPerSec: reading.diskReadPerSec ?? 0,
            diskWritePerSec: reading.diskWritePerSec ?? 0
        )
    }

    /// Sum of several containers at one moment. CPU is nil until every one has a value.
    public static func total(_ points: [StatsPoint], at time: Date) -> StatsPoint {
        let cpus = points.map(\.cpuPercent)
        return StatsPoint(
            time: time,
            cpuPercent: cpus.contains(where: { $0 == nil }) ? nil : cpus.reduce(0) { $0 + ($1 ?? 0) },
            memoryBytes: points.reduce(0) { $0 + $1.memoryBytes },
            memoryLimitBytes: points.reduce(0) { $0 + $1.memoryLimitBytes },
            netRxPerSec: points.reduce(0) { $0 + $1.netRxPerSec },
            netTxPerSec: points.reduce(0) { $0 + $1.netTxPerSec },
            diskReadPerSec: points.reduce(0) { $0 + $1.diskReadPerSec },
            diskWritePerSec: points.reduce(0) { $0 + $1.diskWritePerSec }
        )
    }
}

/// Averages samples that fall into one time bucket.
struct StatsBucket: Sendable, Hashable {
    var start: Int
    var count = 0
    var cpuCount = 0
    var cpu = 0.0
    var memory = 0.0
    var limit = 0.0
    var rx = 0.0
    var tx = 0.0
    var read = 0.0
    var write = 0.0

    init(start: Int) { self.start = start }

    mutating func add(_ point: StatsPoint) {
        count += 1
        if let value = point.cpuPercent, value.isFinite {
            cpu += value
            cpuCount += 1
        }
        memory += point.memoryBytes.finiteOrZero
        limit += point.memoryLimitBytes.finiteOrZero
        rx += point.netRxPerSec.finiteOrZero
        tx += point.netTxPerSec.finiteOrZero
        read += point.diskReadPerSec.finiteOrZero
        write += point.diskWritePerSec.finiteOrZero
    }

    var point: StatsPoint {
        let n = Double(max(count, 1))
        return StatsPoint(
            time: Date(timeIntervalSince1970: TimeInterval(start)),
            cpuPercent: cpuCount > 0 ? cpu / Double(cpuCount) : nil,
            memoryBytes: memory / n,
            memoryLimitBytes: limit / n,
            netRxPerSec: rx / n,
            netTxPerSec: tx / n,
            diskReadPerSec: read / n,
            diskWritePerSec: write / n
        )
    }
}

extension Double {
    var finiteOrZero: Double { isFinite ? Swift.max(0, self) : 0 }
}

/// Points at one resolution, oldest first, bounded by time span.
public struct StatsTier: Sendable, Hashable {
    public let step: Int
    public let span: Int
    public private(set) var points: [StatsPoint] = []
    var open: StatsBucket?

    public init(step: Int, span: Int, points: [StatsPoint] = []) {
        self.step = max(1, step)
        self.span = max(step, span)
        self.points = points.sorted { $0.time < $1.time }
    }

    public var capacity: Int { span / step }

    /// Adds a sample. Closes the open bucket when the sample falls into a later one.
    mutating func add(_ point: StatsPoint) {
        let seconds = Int(point.time.timeIntervalSince1970.rounded(.down))
        let start = seconds - ((seconds % step) + step) % step
        if var bucket = open {
            if start == bucket.start {
                bucket.add(point)
                open = bucket
                return
            }
            if start < bucket.start { return } // Clock went back. Ignore late samples.
            points.append(bucket.point)
        } else if let last = points.last, start <= Int(last.time.timeIntervalSince1970) {
            return
        }
        var bucket = StatsBucket(start: start)
        bucket.add(point)
        open = bucket
        prune(now: seconds)
    }

    /// Drops points older than the span.
    mutating func prune(now: Int) {
        let oldest = Double(now - span)
        if let first = points.first, first.time.timeIntervalSince1970 < oldest {
            points.removeAll { $0.time.timeIntervalSince1970 < oldest }
        }
        if points.count > capacity { points.removeFirst(points.count - capacity) }
    }

    /// Closed points plus the open bucket, so the newest sample shows at once.
    public var allPoints: [StatsPoint] {
        guard let open else { return points }
        return points + [open.point]
    }

    /// Closes the open bucket (before saving).
    mutating func seal() {
        if let open {
            points.append(open.point)
            self.open = nil
        }
    }
}

/// History for one container (or the total).
public struct StatsSeries: Sendable, Hashable {
    public var key: String
    public var name: String
    public var lastSeen: Date
    public var fine: StatsTier
    public var coarse: StatsTier

    public init(key: String, name: String, lastSeen: Date,
                fine: StatsTier = StatsTier(step: ObservabilityConfig.fineStep, span: ObservabilityConfig.fineSpan),
                coarse: StatsTier = StatsTier(step: ObservabilityConfig.coarseStep, span: ObservabilityConfig.coarseSpan)) {
        self.key = key
        self.name = name
        self.lastSeen = lastSeen
        self.fine = fine
        self.coarse = coarse
    }

    mutating func add(_ point: StatsPoint) {
        fine.add(point)
        coarse.add(point)
        if point.time > lastSeen { lastSeen = point.time }
    }
}

/// The whole store. A plain value: the app owns one and saves it with `StatsHistoryCodec`.
public struct StatsHistoryStore: Sendable, Hashable {
    public private(set) var series: [String: StatsSeries] = [:]
    public let maxSeries: Int

    public init(maxSeries: Int = ObservabilityConfig.maxSeries, series: [StatsSeries] = []) {
        self.maxSeries = max(1, maxSeries)
        for item in series { self.series[item.key] = item }
    }

    public var isEmpty: Bool { series.isEmpty }
    public var totalKey: String { ObservabilityConfig.totalKey }

    /// Records one frame: every running container at about the same time. Also adds the total.
    /// `names` maps a key to the name to show.
    public mutating func record(_ frame: [String: StatsPoint], names: [String: String] = [:], at time: Date) {
        guard !frame.isEmpty else { return }
        for (key, point) in frame where key != ObservabilityConfig.totalKey {
            var item = series[key] ?? StatsSeries(key: key, name: names[key] ?? key, lastSeen: time)
            if let name = names[key], !name.isEmpty { item.name = name }
            item.add(point)
            series[key] = item
        }
        var total = series[ObservabilityConfig.totalKey]
            ?? StatsSeries(key: ObservabilityConfig.totalKey, name: "All containers", lastSeen: time)
        total.add(StatsPoint.total(Array(frame.values), at: time))
        series[ObservabilityConfig.totalKey] = total
        prune(now: time)
    }

    /// Drops containers not seen for a day and the least recently seen ones past the limit.
    public mutating func prune(now: Date) {
        let expiry = now.addingTimeInterval(-ObservabilityConfig.seriesExpiry)
        for (key, item) in series where key != ObservabilityConfig.totalKey && item.lastSeen < expiry {
            series.removeValue(forKey: key)
        }
        let containers = series.values.filter { $0.key != ObservabilityConfig.totalKey }
        if containers.count > maxSeries {
            let drop = containers.sorted { $0.lastSeen < $1.lastSeen }.prefix(containers.count - maxSeries)
            for item in drop { series.removeValue(forKey: item.key) }
        }
        let seconds = Int(now.timeIntervalSince1970)
        for key in Array(series.keys) {
            series[key]?.fine.prune(now: seconds)
            series[key]?.coarse.prune(now: seconds)
        }
    }

    /// Points for one series in a window ending at `now`, oldest first.
    public func points(_ key: String, range: StatsHistoryRange, now: Date = Date()) -> [StatsPoint] {
        guard let item = series[key] else { return [] }
        let tier = range == .day ? item.coarse : item.fine
        let from = now.addingTimeInterval(-range.seconds)
        return tier.allPoints.filter { $0.time >= from && $0.time <= now.addingTimeInterval(TimeInterval(tier.step)) }
    }

    /// Total across all containers.
    public func totals(range: StatsHistoryRange, now: Date = Date()) -> [StatsPoint] {
        points(ObservabilityConfig.totalKey, range: range, now: now)
    }

    /// Adds the points of a newer store (samples taken before the saved file was read).
    public mutating func absorb(_ newer: StatsHistoryStore) {
        for (key, item) in newer.series {
            var mine = series[key] ?? StatsSeries(key: key, name: item.name, lastSeen: item.lastSeen)
            mine.name = item.name
            for point in item.fine.allPoints { mine.add(point) }
            series[key] = mine
        }
        if let latest = series.values.map(\.lastSeen).max() { prune(now: latest) }
    }

    /// Closes open buckets (before saving).
    public mutating func seal() {
        for key in Array(series.keys) {
            series[key]?.fine.seal()
            series[key]?.coarse.seal()
        }
    }

    /// Splits points where a gap is longer than `gapSteps` steps (the app was closed or no
    /// screen showed stats), so charts do not draw a line across the gap. Returns segment numbers.
    public static func segments(_ points: [StatsPoint], step: Int) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(points.count)
        var segment = 0
        var previous: Date?
        let limit = TimeInterval(step * ObservabilityConfig.gapSteps)
        for point in points {
            if let previous, point.time.timeIntervalSince(previous) > limit { segment += 1 }
            result.append(segment)
            previous = point.time
        }
        return result
    }
}
