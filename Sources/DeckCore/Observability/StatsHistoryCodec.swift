import Foundation

/// Compact binary file for `StatsHistoryStore`. Little endian.
///
///     "CDSH" UInt16 version UInt16 seriesCount
///     per series: UInt16 keyLength, key, UInt16 nameLength, name, Float64 lastSeen,
///                 then fine and coarse tiers: UInt32 count, count times
///                 (UInt32 seconds, 7 x Float32: cpu (NaN = none), memory, limit, rx, tx, read, write)
///
/// 32 bytes a point, so the full store stays under about 2.6 MB. Anything that does not
/// read cleanly gives nil and the app starts with an empty history.
public enum StatsHistoryCodec {
    static let magic: [UInt8] = Array("CDSH".utf8)
    public static let version: UInt16 = 1
    static let pointSize = 32

    public static func encode(_ store: StatsHistoryStore) -> Data {
        var sealed = store
        sealed.seal()
        var out = Data()
        out.append(contentsOf: magic)
        out.appendLE(version)
        let items = sealed.series.values.sorted { $0.key < $1.key }
        out.appendLE(UInt16(min(items.count, Int(UInt16.max))))
        for item in items.prefix(Int(UInt16.max)) {
            out.appendString(item.key)
            out.appendString(item.name)
            out.appendLE(item.lastSeen.timeIntervalSince1970.bitPattern)
            for tier in [item.fine, item.coarse] {
                out.appendLE(UInt32(tier.points.count))
                for point in tier.points {
                    out.appendLE(UInt32(clamping: Int64(max(0, point.time.timeIntervalSince1970))))
                    for value in [point.cpuPercent ?? .nan, point.memoryBytes, point.memoryLimitBytes,
                                  point.netRxPerSec, point.netTxPerSec, point.diskReadPerSec, point.diskWritePerSec] {
                        out.appendLE(Float(value).bitPattern)
                    }
                }
            }
        }
        return out
    }

    public static func decode(_ data: Data, maxSeries: Int = ObservabilityConfig.maxSeries) -> StatsHistoryStore? {
        var reader = ByteReader(data)
        guard reader.bytes(4) == magic, let version = reader.uint16(), version == Self.version,
              let count = reader.uint16() else { return nil }
        var series: [StatsSeries] = []
        for _ in 0..<count {
            guard let key = reader.string(), let name = reader.string(), let seen = reader.uint64() else { return nil }
            var tiers: [[StatsPoint]] = []
            for _ in 0..<2 {
                guard let pointCount = reader.uint32(), Int(pointCount) * pointSize <= reader.remaining else { return nil }
                var points: [StatsPoint] = []
                points.reserveCapacity(Int(pointCount))
                for _ in 0..<pointCount {
                    guard let seconds = reader.uint32() else { return nil }
                    var values: [Double] = []
                    for _ in 0..<7 {
                        guard let bits = reader.uint32() else { return nil }
                        values.append(Double(Float(bitPattern: bits)))
                    }
                    let clean = values.dropFirst().map { $0.finiteOrZero }
                    points.append(StatsPoint(
                        time: Date(timeIntervalSince1970: TimeInterval(seconds)),
                        cpuPercent: values[0].isFinite ? max(0, values[0]) : nil,
                        memoryBytes: clean[0], memoryLimitBytes: clean[1],
                        netRxPerSec: clean[2], netTxPerSec: clean[3],
                        diskReadPerSec: clean[4], diskWritePerSec: clean[5]
                    ))
                }
                tiers.append(points)
            }
            let lastSeen = Double(bitPattern: seen)
            series.append(StatsSeries(
                key: key, name: name,
                lastSeen: Date(timeIntervalSince1970: lastSeen.isFinite ? lastSeen : 0),
                fine: StatsTier(step: ObservabilityConfig.fineStep, span: ObservabilityConfig.fineSpan, points: tiers[0]),
                coarse: StatsTier(step: ObservabilityConfig.coarseStep, span: ObservabilityConfig.coarseSpan, points: tiers[1])
            ))
        }
        var store = StatsHistoryStore(maxSeries: maxSeries, series: series)
        store.prune(now: Date())
        return store
    }

    // MARK: Files

    /// Reads the file. A missing or broken file gives an empty store.
    public static func load(from url: URL = ObservabilityConfig.historyFile) -> StatsHistoryStore {
        guard let data = try? Data(contentsOf: url), let store = decode(data) else { return StatsHistoryStore() }
        return store
    }

    /// Writes the file atomically, making the folder when needed.
    public static func save(_ store: StatsHistoryStore, to url: URL = ObservabilityConfig.historyFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(store).write(to: url, options: .atomic)
    }
}

// MARK: - Bytes

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendString(_ text: String) {
        let bytes = Array(text.utf8.prefix(Int(UInt16.max)))
        appendLE(UInt16(bytes.count))
        append(contentsOf: bytes)
    }
}

private struct ByteReader {
    let data: [UInt8]
    var offset = 0

    init(_ data: Data) { self.data = Array(data) }

    var remaining: Int { data.count - offset }

    mutating func bytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Array(data[offset..<offset + count])
    }

    mutating func integer<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard let raw = bytes(size) else { return nil }
        var value: T = 0
        for (index, byte) in raw.enumerated() { value |= T(byte) << (8 * index) }
        return value
    }

    mutating func uint16() -> UInt16? { integer(UInt16.self) }
    mutating func uint32() -> UInt32? { integer(UInt32.self) }
    mutating func uint64() -> UInt64? { integer(UInt64.self) }

    mutating func string() -> String? {
        guard let length = uint16(), let raw = bytes(Int(length)) else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }
}
