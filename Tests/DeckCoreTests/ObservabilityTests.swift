import XCTest
@testable import DeckCore

final class ObservabilityStatsHistoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000) // on a minute boundary

    private func point(_ offset: TimeInterval, cpu: Double? = 10, memory: Double = 100, rx: Double = 0) -> StatsPoint {
        StatsPoint(time: base.addingTimeInterval(offset), cpuPercent: cpu, memoryBytes: memory, memoryLimitBytes: 1000, netRxPerSec: rx)
    }

    func testBucketsAverageIntoTwoSecondPoints() {
        var store = StatsHistoryStore()
        store.record(["web": point(0, cpu: 10)], at: base)
        store.record(["web": point(1, cpu: 30)], at: base.addingTimeInterval(1))
        store.record(["web": point(2, cpu: 50)], at: base.addingTimeInterval(2))
        let points = store.points("web", range: .fiveMinutes, now: base.addingTimeInterval(3))
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].cpuPercent ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(points[0].time, base)
        XCTAssertEqual(points[1].cpuPercent ?? -1, 50, accuracy: 0.001)
    }

    func testCPUWithoutReadingStaysNil() {
        var store = StatsHistoryStore()
        store.record(["web": point(0, cpu: nil)], at: base)
        let points = store.points("web", range: .fiveMinutes, now: base.addingTimeInterval(1))
        XCTAssertNil(points.first?.cpuPercent)
        XCTAssertEqual(points.first?.memoryBytes, 100)
    }

    func testTotalSumsContainers() {
        var store = StatsHistoryStore()
        store.record(["a": point(0, cpu: 10, memory: 100, rx: 5), "b": point(0, cpu: 15, memory: 50, rx: 7)], at: base)
        let total = store.totals(range: .fiveMinutes, now: base.addingTimeInterval(1))
        XCTAssertEqual(total.count, 1)
        XCTAssertEqual(total[0].cpuPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(total[0].memoryBytes, 150)
        XCTAssertEqual(total[0].netRxPerSec, 12)
    }

    func testTotalCPUIsNilUntilAllMeasured() {
        let total = StatsPoint.total([point(0, cpu: 10), point(0, cpu: nil)], at: base)
        XCTAssertNil(total.cpuPercent)
    }

    func testFineTierKeepsOneHourCoarseKeepsADay() {
        var store = StatsHistoryStore()
        // Two hours at one sample every 2 seconds.
        for i in stride(from: 0, through: 7200, by: 2) {
            let t = TimeInterval(i)
            store.record(["web": point(t)], at: base.addingTimeInterval(t))
        }
        let now = base.addingTimeInterval(7200)
        let series = store.series["web"]!
        XCTAssertLessThanOrEqual(series.fine.points.count, ObservabilityConfig.fineSpan / ObservabilityConfig.fineStep)
        XCTAssertGreaterThanOrEqual(series.fine.points.first!.time, now.addingTimeInterval(-3600))
        XCTAssertEqual(series.coarse.points.count, 120)
        // 24 hour view uses the minute tier, the hour view the fine tier.
        XCTAssertEqual(store.points("web", range: .day, now: now).count, 121)
        XCTAssertGreaterThan(store.points("web", range: .hour, now: now).count, 1700)
        XCTAssertLessThanOrEqual(store.points("web", range: .fiveMinutes, now: now).count, 152)
    }

    func testLateSamplesAreIgnored() {
        var store = StatsHistoryStore()
        store.record(["web": point(10, cpu: 10)], at: base.addingTimeInterval(10))
        store.record(["web": point(4, cpu: 90)], at: base.addingTimeInterval(4))
        let points = store.points("web", range: .fiveMinutes, now: base.addingTimeInterval(12))
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].cpuPercent ?? -1, 10, accuracy: 0.001)
    }

    func testSeriesLimitDropsLeastRecentlySeen() {
        var store = StatsHistoryStore(maxSeries: 2)
        store.record(["a": point(0)], at: base)
        store.record(["b": point(2)], at: base.addingTimeInterval(2))
        store.record(["c": point(4)], at: base.addingTimeInterval(4))
        XCTAssertNil(store.series["a"])
        XCTAssertNotNil(store.series["b"])
        XCTAssertNotNil(store.series["c"])
        XCTAssertNotNil(store.series[ObservabilityConfig.totalKey], "the total never counts against the limit")
    }

    func testOldSeriesExpire() {
        var store = StatsHistoryStore()
        store.record(["old": point(0)], at: base)
        store.record(["new": point(0)], at: base.addingTimeInterval(25 * 3600))
        XCTAssertNil(store.series["old"])
        XCTAssertNotNil(store.series["new"])
    }

    func testNamesAreKept() {
        var store = StatsHistoryStore()
        store.record(["abc": point(0)], names: ["abc": "web"], at: base)
        XCTAssertEqual(store.series["abc"]?.name, "web")
    }

    func testSegmentsBreakOnGaps() {
        let points = [point(0), point(2), point(4), point(30), point(32)]
        XCTAssertEqual(StatsHistoryStore.segments(points, step: 2), [0, 0, 0, 1, 1])
    }

    func testRangeSteps() {
        XCTAssertEqual(StatsHistoryRange.fiveMinutes.step, 2)
        XCTAssertEqual(StatsHistoryRange.day.step, 60)
        XCTAssertEqual(StatsHistoryRange.allCases.map(\.title), ["5m", "15m", "1h", "24h"])
    }

    func testAbsorbAddsNewerSamples() {
        var saved = StatsHistoryStore()
        saved.record(["web": point(0, cpu: 10)], at: base)
        var fresh = StatsHistoryStore()
        fresh.record(["web": point(10, cpu: 40)], at: base.addingTimeInterval(10))
        saved.absorb(fresh)
        let points = saved.points("web", range: .fiveMinutes, now: base.addingTimeInterval(12))
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.last?.cpuPercent ?? -1, 40, accuracy: 0.001)
    }
}

final class ObservabilityCodecTests: XCTestCase {
    private let now = Date()

    private func filledStore() -> StatsHistoryStore {
        var store = StatsHistoryStore()
        let start = now.addingTimeInterval(-600)
        for i in stride(from: 0, to: 600, by: 2) {
            let t = start.addingTimeInterval(TimeInterval(i))
            store.record([
                "web": StatsPoint(time: t, cpuPercent: i < 4 ? nil : Double(i % 50), memoryBytes: 200_000_000, memoryLimitBytes: 1_073_741_824,
                                  netRxPerSec: 1500, netTxPerSec: 300, diskReadPerSec: 4096, diskWritePerSec: 8192),
                "db": StatsPoint(time: t, cpuPercent: 3.5, memoryBytes: 90_000_000)
            ], names: ["web": "deck-demo-web", "db": "deck-demo-db"], at: t)
        }
        return store
    }

    func testRoundTrip() throws {
        var store = filledStore()
        let data = StatsHistoryCodec.encode(store)
        let decoded = try XCTUnwrap(StatsHistoryCodec.decode(data))
        store.seal()
        XCTAssertEqual(Set(decoded.series.keys), ["web", "db", ObservabilityConfig.totalKey])
        XCTAssertEqual(decoded.series["web"]?.name, "deck-demo-web")
        let a = store.series["web"]!.fine.points
        let b = decoded.series["web"]!.fine.points
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(a.first?.time, b.first?.time)
        XCTAssertNil(b.first?.cpuPercent, "unknown CPU survives as nil")
        XCTAssertEqual(b.last?.memoryBytes ?? 0, 200_000_000, accuracy: 100)
        XCTAssertEqual(b.last?.diskWritePerSec ?? 0, 8192, accuracy: 0.5)
        XCTAssertEqual(decoded.series["web"]!.coarse.points.count, store.series["web"]!.coarse.points.count)
    }

    func testSizeIsCompact() {
        let data = StatsHistoryCodec.encode(filledStore())
        // 3 series, about 300 fine and 10 coarse points each, 32 bytes a point.
        XCTAssertLessThan(data.count, 3 * 320 * 32 + 400)
    }

    func testFullStoreStaysBounded() {
        // Worst case: every series full in both tiers.
        let perSeries = (ObservabilityConfig.fineSpan / ObservabilityConfig.fineStep
            + ObservabilityConfig.coarseSpan / ObservabilityConfig.coarseStep) * StatsHistoryCodec.pointSize
        XCTAssertLessThan((ObservabilityConfig.maxSeries + 1) * perSeries, 3 * 1024 * 1024)
    }

    func testBrokenDataGivesNil() {
        XCTAssertNil(StatsHistoryCodec.decode(Data()))
        XCTAssertNil(StatsHistoryCodec.decode(Data("nope".utf8)))
        var data = StatsHistoryCodec.encode(filledStore())
        data.removeLast(17)
        XCTAssertNil(StatsHistoryCodec.decode(data), "a cut off file is not read half way")
        var wrongVersion = StatsHistoryCodec.encode(filledStore())
        wrongVersion[4] = 99
        XCTAssertNil(StatsHistoryCodec.decode(wrongVersion))
    }

    func testHugeCountDoesNotAllocate() {
        var data = Data("CDSH".utf8)
        data.append(contentsOf: [1, 0, 1, 0]) // version 1, one series
        data.append(contentsOf: [1, 0, 0x61, 1, 0, 0x61]) // key "a", name "a"
        data.append(contentsOf: [UInt8](repeating: 0, count: 8)) // last seen
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // 4 billion points
        XCTAssertNil(StatsHistoryCodec.decode(data))
    }

    func testSaveAndLoadFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-v2-obs-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try StatsHistoryCodec.save(filledStore(), to: url)
        let loaded = StatsHistoryCodec.load(from: url)
        XCTAssertEqual(loaded.series.count, 3)
        // A missing file is an empty store, not an error.
        XCTAssertTrue(StatsHistoryCodec.load(from: url.appendingPathExtension("missing")).isEmpty)
    }
}

final class ObservabilityLogTests: XCTestCase {
    func testSplitArrangements() {
        XCTAssertEqual(LogSplit.columns.arrangement(count: 3), [[0, 1, 2]])
        XCTAssertEqual(LogSplit.rows.arrangement(count: 3), [[0], [1], [2]])
        XCTAssertEqual(LogSplit.grid.arrangement(count: 2), [[0, 1]])
        XCTAssertEqual(LogSplit.grid.arrangement(count: 3), [[0, 1], [2]])
        XCTAssertEqual(LogSplit.grid.arrangement(count: 4), [[0, 1], [2, 3]])
        XCTAssertEqual(LogSplit.grid.arrangement(count: 9), [[0, 1], [2, 3]], "never more than four panes")
        XCTAssertEqual(LogSplit.columns.arrangement(count: 0), [])
    }

    func testQueryIncludeAndExclude() {
        let query = LogQuery("error -healthz")
        XCTAssertTrue(query.matches("ERROR: db down"))
        XCTAssertFalse(query.matches("error GET /healthz"))
        XCTAssertFalse(query.matches("all good"))
        XCTAssertTrue(LogQuery("").isEmpty)
        XCTAssertTrue(LogQuery("  ").isEmpty)
        XCTAssertTrue(LogQuery("-").isEmpty)
    }

    func testQuotedPhrase() {
        let query = LogQuery("\"GET /api\" 500")
        XCTAssertEqual(query.include, ["GET /api", "500"])
        XCTAssertTrue(query.matches("10.0.0.1 GET /api/users 500"))
        XCTAssertFalse(query.matches("GET /static 500"))
    }

    func testHighlightsAreMergedAndSorted() {
        let line = "Error error ERRORS"
        let ranges = LogQuery("error").highlights(in: line)
        XCTAssertEqual(ranges.map { String(line[$0]) }, ["Error", "error", "ERROR"])
        let overlap = LogQuery("abc bcd").highlights(in: "xabcdx")
        XCTAssertEqual(overlap.map { String("xabcdx"[$0]) }, ["abcd"])
        XCTAssertTrue(LogQuery("-noise").highlights(in: "noise").isEmpty, "excluded words are not marked")
    }

    func testHighlightsWithUnicode() {
        let line = "café ☕️ café"
        let ranges = LogQuery("café").highlights(in: line)
        XCTAssertEqual(ranges.count, 2)
    }

    func testTimestampFormat() {
        let date = Date(timeIntervalSince1970: 3600 * 13 + 60 * 5 + 7.25)
        XCTAssertEqual(LogFormat.timestamp(date, timeZone: TimeZone(identifier: "UTC")!), "13:05:07.250")
    }

    func testCopyText() {
        let utc = TimeZone(identifier: "UTC")!
        let entries = [
            LogEntry(id: 0, time: nil, text: "booted"),
            LogEntry(id: 1, time: Date(timeIntervalSince1970: 1.5), text: "hello")
        ]
        XCTAssertEqual(LogFormat.copyText(entries, timestamps: false), "booted\nhello")
        XCTAssertEqual(LogFormat.copyText(entries, timestamps: true, label: "web", timeZone: utc),
                       "             [web] booted\n00:00:01.500 [web] hello")
    }

    func testColorSlots() {
        XCTAssertEqual(LogFormat.nextColorSlot(used: [], slots: 6), 0)
        XCTAssertEqual(LogFormat.nextColorSlot(used: [0, 2], slots: 6), 1)
        XCTAssertEqual(LogFormat.nextColorSlot(used: [0, 1], slots: 2), 0)
    }

    func testBufferKeepsTheNewestLines() {
        var buffer = LogBuffer(limit: 3)
        buffer.append([(nil, "a"), (nil, "b")])
        buffer.append([(nil, "c"), (nil, "d")])
        XCTAssertEqual(buffer.entries.map(\.text), ["b", "c", "d"])
        XCTAssertEqual(buffer.entries.map(\.id), [1, 2, 3], "ids keep counting so lists stay stable")
        buffer.clear()
        buffer.append([(nil, "e")])
        XCTAssertEqual(buffer.entries.first?.id, 4)
    }
}

final class ObservabilityFreeSpaceTests: XCTestCase {
    private let usage = DiskUsage(
        images: UsageBucket(total: 10, active: 4, sizeBytes: 5_000, reclaimableBytes: 2_000),
        containers: UsageBucket(total: 5, active: 5, sizeBytes: 900, reclaimableBytes: 0),
        volumes: UsageBucket(total: 3, active: 1, sizeBytes: 700, reclaimableBytes: 300)
    )

    func testDefaultsSkipVolumesAndEmptyParts() {
        XCTAssertEqual(FreeSpacePlan.defaultSelection(usage), [.images])
        XCTAssertEqual(FreeSpacePlan.defaultSelection(nil), [])
    }

    func testEstimateAndOrder() {
        XCTAssertEqual(FreeSpacePlan.estimate(usage, picked: [.images, .volumes]), 2_300)
        XCTAssertEqual(FreeSpacePlan.order([.volumes, .networks, .containers, .images]), [.containers, .images, .volumes, .networks])
        XCTAssertEqual(FreeSpaceItem.containers.unusedCount(usage), 0)
        XCTAssertEqual(FreeSpaceItem.images.unusedCount(usage), 6)
        XCTAssertNil(FreeSpaceItem.networks.reclaimable(usage))
    }

    func testFreed() {
        var after = usage
        after.images.sizeBytes = 3_000
        XCTAssertEqual(FreeSpacePlan.freed(before: usage, after: after), 2_000)
        XCTAssertEqual(FreeSpacePlan.freed(before: after, after: usage), 0)
        XCTAssertEqual(FreeSpacePlan.freed(before: nil, after: usage), 0)
    }
}
