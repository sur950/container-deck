import Foundation

/// Saves build records and logs. One JSON file for the list, one text file per log.
/// A nil directory keeps everything in memory (tests).
public struct BuildHistoryStore: Sendable {
    public let directory: URL?

    public init(directory: URL?) {
        self.directory = directory
    }

    public static let memoryOnly = BuildHistoryStore(directory: nil)

    private struct FileShape: Codable {
        var version: Int
        var builds: [BuildRecord]
    }

    var historyURL: URL? { directory?.appendingPathComponent(BuildsConfig.historyFileName) }

    func logURL(_ id: UUID) -> URL? {
        directory?
            .appendingPathComponent(BuildsConfig.logsFolderName, isDirectory: true)
            .appendingPathComponent(id.uuidString + ".log")
    }

    /// Saved builds, newest first. Builds still marked running were cut off by a quit
    /// or crash, so they come back as interrupted. A broken file reads as empty.
    public func load(now: Date = Date()) -> [BuildRecord] {
        guard let url = historyURL, let data = try? Data(contentsOf: url) else { return [] }
        return Self.decode(data, now: now)
    }

    static func decode(_ data: Data, now: Date = Date()) -> [BuildRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = DeckDate.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
            }
            return date
        }
        guard let file = try? decoder.decode(FileShape.self, from: data) else { return [] }
        return file.builds.map { record in
            var record = record
            if record.status == .running {
                record.status = .interrupted
                record.finishedAt = record.finishedAt ?? now
                record.message = record.message ?? "The app closed while this build ran."
            }
            return record
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    static func encode(_ records: [BuildRecord]) throws -> Data {
        let encoder = JSONEncoder()
        // Milliseconds kept, so durations read the same after a restart.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dateText(date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(FileShape(version: 1, builds: records))
    }

    static func dateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public func save(_ records: [BuildRecord]) throws {
        guard let url = historyURL, let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(records).write(to: url, options: .atomic)
    }

    public func saveLog(_ lines: [String], for id: UUID) throws {
        guard let url = logURL(id) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
    }

    public func loadLog(for id: UUID) -> [String] {
        guard let url = logURL(id), let data = try? Data(contentsOf: url) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    public func deleteLog(for id: UUID) {
        guard let url = logURL(id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Keeps running builds and the newest finished ones up to `limit` in total.
    /// Returns what stays (newest first) and what goes.
    public static func trim(_ records: [BuildRecord], limit: Int) -> (kept: [BuildRecord], removed: [BuildRecord]) {
        let sorted = records.sorted { $0.startedAt > $1.startedAt }
        let running = sorted.filter { $0.status == .running }
        var room = max(0, max(limit, 1) - running.count)
        var kept: [BuildRecord] = []
        var removed: [BuildRecord] = []
        for record in sorted {
            if record.status == .running {
                kept.append(record)
            } else if room > 0 {
                kept.append(record)
                room -= 1
            } else {
                removed.append(record)
            }
        }
        return (kept, removed)
    }
}
