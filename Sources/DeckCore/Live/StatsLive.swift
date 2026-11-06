import Foundation

// Live stats: turning consecutive readings into rates, and reading the
// streamed `container stats` table so one long running process can feed every screen.

// MARK: - Math

public enum StatsMath {
    /// CPU percent between two cumulative readings. 100 means one full core, like `docker stats`.
    /// nil when there is no usable earlier reading (first one, counter reset, no time passed).
    public static func cpuPercent(previousUsec: UInt64, previousTime: Date, currentUsec: UInt64, currentTime: Date) -> Double? {
        let elapsed = currentTime.timeIntervalSince(previousTime)
        guard elapsed > 0.2, currentUsec >= previousUsec else { return nil }
        let usedSeconds = Double(currentUsec - previousUsec) / 1_000_000
        return max(0, usedSeconds / elapsed * 100)
    }

    /// Bytes per second between two cumulative counters. nil when the counter went back or no time passed.
    public static func rate(previous: UInt64, current: UInt64, seconds: Double) -> Double? {
        guard seconds > 0.2, current >= previous else { return nil }
        return Double(current - previous) / seconds
    }
}

/// One container at one moment, ready to show.
public struct StatsReading: Sendable, Hashable {
    public var id: String
    public var date: Date
    /// nil until two readings exist (the UI shows "Measuring").
    public var cpuPercent: Double?
    public var memoryBytes: UInt64
    public var memoryLimitBytes: UInt64
    public var netRxPerSec: Double?
    public var netTxPerSec: Double?
    public var diskReadPerSec: Double?
    public var diskWritePerSec: Double?
    public var pids: Int

    public init(id: String, date: Date, cpuPercent: Double?, memoryBytes: UInt64, memoryLimitBytes: UInt64,
                netRxPerSec: Double? = nil, netTxPerSec: Double? = nil, diskReadPerSec: Double? = nil,
                diskWritePerSec: Double? = nil, pids: Int = 0) {
        self.id = id
        self.date = date
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.netRxPerSec = netRxPerSec
        self.netTxPerSec = netTxPerSec
        self.diskReadPerSec = diskReadPerSec
        self.diskWritePerSec = diskWritePerSec
        self.pids = pids
    }
}

/// Keeps the previous reading per container and works out CPU and rates from
/// its own consecutive samples. Not shared with any other poller.
public struct StatsTracker: Sendable {
    private var previous: [String: ContainerStats] = [:]

    public init() {}

    /// Adds one batch (all containers sampled at about the same time).
    /// Containers missing from the batch are forgotten, so a restart starts clean.
    public mutating func ingest(_ batch: [ContainerStats]) -> [String: StatsReading] {
        var next: [String: ContainerStats] = [:]
        var result: [String: StatsReading] = [:]
        for current in batch {
            // Exact JSON counters and rounded table counters do not mix: no rates across sources.
            let before = previous[current.id].flatMap { ($0.cpuUsageUsec == nil) == (current.cpuUsageUsec == nil) ? $0 : nil }
            var cpu = current.reportedCPUPercent
            if cpu == nil, let before, let now = current.cpuUsageUsec, let then = before.cpuUsageUsec {
                cpu = StatsMath.cpuPercent(previousUsec: then, previousTime: before.timestamp,
                                           currentUsec: now, currentTime: current.timestamp)
            }
            let seconds = before.map { current.timestamp.timeIntervalSince($0.timestamp) } ?? 0
            result[current.id] = StatsReading(
                id: current.id,
                date: current.timestamp,
                cpuPercent: cpu,
                memoryBytes: current.memoryUsageBytes,
                memoryLimitBytes: current.memoryLimitBytes,
                netRxPerSec: before.flatMap { StatsMath.rate(previous: $0.netRxBytes, current: current.netRxBytes, seconds: seconds) },
                netTxPerSec: before.flatMap { StatsMath.rate(previous: $0.netTxBytes, current: current.netTxBytes, seconds: seconds) },
                diskReadPerSec: before.flatMap { StatsMath.rate(previous: $0.blockReadBytes, current: current.blockReadBytes, seconds: seconds) },
                diskWritePerSec: before.flatMap { StatsMath.rate(previous: $0.blockWriteBytes, current: current.blockWriteBytes, seconds: seconds) },
                pids: current.pids
            )
            next[current.id] = current
        }
        previous = next
        return result
    }

    public mutating func reset() {
        previous = [:]
    }

    public var knownIDs: Set<String> { Set(previous.keys) }
}

// MARK: - Streamed table

/// Reads the table `container stats` prints when it streams (one frame about every 2 seconds):
///
///     Container ID      Cpu %  Memory Usage           Net Rx/Tx              Block I/O               Pids
///     buildkit          0.01%  137.82 MiB / 2.00 GiB  633.71 KiB / 0.59 KiB  93.48 MiB / 29.24 MiB   21
///
/// Values the CLI does not have print as "--".
public enum StatsTableParser {
    public static func isHeader(_ line: String) -> Bool {
        clean(line).hasPrefix("Container ID")
    }

    /// The CLI prints this when one round failed. The stream goes on.
    public static func isError(_ line: String) -> Bool {
        clean(line).lowercased().hasPrefix("error")
    }

    /// One row, or nil when the line is not a stats row.
    public static func row(_ line: String, at date: Date) -> ContainerStats? {
        let text = clean(line)
        guard !text.isEmpty, !isHeader(text), !isError(text) else { return nil }
        let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // id, cpu, mem used (2), "/", mem limit (2), rx (2), "/", tx (2), read (2), "/", write (2), pids
        // Values may be "--" (one token instead of two), so read left to right.
        var cursor = 1
        guard parts.count >= 6 else { return nil }
        let id = parts[0]

        func next() -> String? {
            guard cursor < parts.count else { return nil }
            defer { cursor += 1 }
            return parts[cursor]
        }
        /// Reads "12.5 MiB" or "--". Returns (value, ok).
        func size() -> (UInt64?, Bool) {
            guard let first = next() else { return (nil, false) }
            if first == "--" { return (nil, true) }
            guard let number = Double(first), let unit = next(), let factor = unitFactor(unit) else { return (nil, false) }
            return (UInt64(max(0, number * factor).rounded()), true)
        }
        func pair() -> (UInt64?, UInt64?, Bool) {
            let (a, okA) = size()
            guard okA, next() == "/" else { return (nil, nil, false) }
            let (b, okB) = size()
            return (a, b, okB)
        }

        guard let cpuText = next() else { return nil }
        var cpu: Double?
        if cpuText != "--" {
            guard cpuText.hasSuffix("%"), let value = Double(cpuText.dropLast()) else { return nil }
            cpu = max(0, value)
        }
        let (memUsed, memLimit, okMem) = pair()
        let (rx, tx, okNet) = pair()
        let (read, write, okDisk) = pair()
        guard okMem, okNet, okDisk, let pidsText = next() else { return nil }
        let pids = Int(pidsText) ?? 0
        guard pidsText == "--" || Int(pidsText) != nil, cursor == parts.count else { return nil }

        return ContainerStats(
            id: id,
            cpuPercent: cpu ?? 0,
            memoryUsageBytes: memUsed ?? 0,
            memoryLimitBytes: memLimit ?? 0,
            netRxBytes: rx ?? 0,
            netTxBytes: tx ?? 0,
            blockReadBytes: read ?? 0,
            blockWriteBytes: write ?? 0,
            pids: pids,
            timestamp: date,
            cpuUsageUsec: nil,
            reportedCPUPercent: cpu
        )
    }

    static func unitFactor(_ unit: String) -> Double? {
        switch unit {
        case "B": return 1
        case "KiB", "KB", "kB": return 1024
        case "MiB", "MB": return 1024 * 1024
        case "GiB", "GB": return 1024 * 1024 * 1024
        case "TiB", "TB": return 1024 * 1024 * 1024 * 1024
        default: return nil
        }
    }

    static func clean(_ line: String) -> String {
        CLIText.strippingANSI(line)
            .replacingOccurrences(of: "\u{1B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Collects streamed lines into whole frames.
/// A frame ends when every expected container has a row, or when the next header arrives.
public struct StatsFrameAssembler: Sendable {
    /// How many rows make a full frame. 0 means "unknown, wait for the next header".
    public var expectedRows: Int
    private var rows: [ContainerStats] = []
    private var inFrame = false
    public private(set) var framesSeen = 0
    public private(set) var errorsSeen = 0

    public init(expectedRows: Int = 0) {
        self.expectedRows = expectedRows
    }

    /// Feeds one line. Returns a finished frame when this line completes one.
    public mutating func feed(_ line: String, at date: Date = Date()) -> [ContainerStats]? {
        if StatsTableParser.isHeader(line) {
            let finished = inFrame && !rows.isEmpty ? rows : nil
            rows = []
            inFrame = true
            if finished != nil { framesSeen += 1 }
            return finished
        }
        if StatsTableParser.isError(line) {
            errorsSeen += 1
            rows = []
            inFrame = false
            return nil
        }
        guard inFrame, let row = StatsTableParser.row(line, at: date) else { return nil }
        rows.removeAll { $0.id == row.id }
        rows.append(row)
        if expectedRows > 0, rows.count >= expectedRows {
            let finished = rows
            rows = []
            inFrame = false
            framesSeen += 1
            return finished
        }
        return nil
    }
}
