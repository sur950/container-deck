import Foundation

// Pure helpers for the multi pane log viewer: layout, filtering, highlight ranges,
// colours per pane and copy text. The app streams lines through `ContainerClient.logs`.

/// How panes share the space.
public enum LogSplit: String, CaseIterable, Sendable, Identifiable {
    /// Side by side.
    case columns
    /// One above the other.
    case rows
    /// Two by two once there are three or four panes.
    case grid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .columns: return "Side by Side"
        case .rows: return "Stacked"
        case .grid: return "Grid"
        }
    }

    /// Pane indices per line of the layout. The outer list runs top to bottom for `columns`
    /// and `grid` rows, the inner one left to right. For `rows` every inner list has one pane.
    public func arrangement(count: Int) -> [[Int]] {
        let n = max(0, min(count, ObservabilityConfig.maxLogPanes))
        guard n > 0 else { return [] }
        switch self {
        case .columns:
            return [Array(0..<n)]
        case .rows:
            return (0..<n).map { [$0] }
        case .grid:
            if n <= 2 { return [Array(0..<n)] }
            return [[0, 1], Array(2..<n)]
        }
    }
}

/// One received line. `time` is when the app read it. Lines loaded from the tail at
/// start have no real time (`container logs` prints none), so they carry nil.
public struct LogEntry: Sendable, Hashable, Identifiable {
    public let id: Int
    public let time: Date?
    public let text: String

    public init(id: Int, time: Date?, text: String) {
        self.id = id
        self.time = time
        self.text = text
    }
}

/// Filter text for log lines. Plain words, case insensitive. A leading "-" hides lines with that word.
public struct LogQuery: Sendable, Hashable {
    public var include: [String] = []
    public var exclude: [String] = []

    public init(_ text: String) {
        for word in LogQuery.words(text) {
            if word.hasPrefix("-"), word.count > 1 {
                exclude.append(String(word.dropFirst()))
            } else if word != "-" {
                include.append(word)
            }
        }
    }

    public var isEmpty: Bool { include.isEmpty && exclude.isEmpty }

    /// Words split on spaces. Text in double quotes stays one word.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for char in text {
            if char == "\"" {
                quoted.toggle()
                continue
            }
            if char == " " && !quoted {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// True when the line has every include word and none of the exclude words.
    public func matches(_ line: String) -> Bool {
        for word in exclude where line.range(of: word, options: .caseInsensitive) != nil { return false }
        for word in include where line.range(of: word, options: .caseInsensitive) == nil { return false }
        return true
    }

    /// Ranges of every include word in the line, sorted and merged, for highlighting.
    public func highlights(in line: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for word in include where !word.isEmpty {
            var start = line.startIndex
            while start < line.endIndex,
                  let found = line.range(of: word, options: .caseInsensitive, range: start..<line.endIndex) {
                ranges.append(found)
                start = found.upperBound
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

public enum LogFormat {
    /// "14:03:22.481"
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let millis = (parts.nanosecond ?? 0) / 1_000_000
        return String(format: "%02d:%02d:%02d.%03d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, millis)
    }

    /// Text for the clipboard. Adds the time when asked and a "[name]" prefix when a label is given.
    public static func copyText(_ entries: [LogEntry], timestamps: Bool, label: String? = nil, timeZone: TimeZone = .current) -> String {
        entries.map { entry in
            var parts: [String] = []
            if timestamps { parts.append(entry.time.map { timestamp($0, timeZone: timeZone) } ?? String(repeating: " ", count: 12)) }
            if let label, !label.isEmpty { parts.append("[\(label)]") }
            parts.append(entry.text)
            return parts.joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    /// Lowest colour slot not used by another pane. Wraps when every slot is taken.
    public static func nextColorSlot(used: [Int], slots: Int) -> Int {
        guard slots > 0 else { return 0 }
        let taken = Set(used)
        return (0..<slots).first { !taken.contains($0) } ?? (used.count % slots)
    }
}

/// Keeps the last `limit` entries and numbers them. Value type so it is easy to test.
public struct LogBuffer: Sendable {
    public private(set) var entries: [LogEntry] = []
    public let limit: Int
    private var nextID = 0

    public init(limit: Int = ObservabilityConfig.maxLogLines) {
        self.limit = max(1, limit)
    }

    public mutating func append(_ lines: [(Date?, String)]) {
        guard !lines.isEmpty else { return }
        var batch: [LogEntry] = []
        batch.reserveCapacity(lines.count)
        for (time, text) in lines {
            batch.append(LogEntry(id: nextID, time: time, text: text))
            nextID += 1
        }
        entries.append(contentsOf: batch)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    public mutating func clear() {
        entries = []
    }
}
