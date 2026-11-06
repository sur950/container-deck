import XCTest
@testable import DeckCore

final class StatsLiveTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: CPU math

    func testCPUPercentFromTwoSamples() {
        // 1.1 s of CPU over 2.2 s is half a core.
        let percent = StatsMath.cpuPercent(previousUsec: 1_000_000, previousTime: t0,
                                           currentUsec: 2_100_000, currentTime: t0.addingTimeInterval(2.2))
        XCTAssertEqual(percent ?? -1, 50, accuracy: 0.001)
        // Two full cores.
        let busy = StatsMath.cpuPercent(previousUsec: 0, previousTime: t0, currentUsec: 4_000_000, currentTime: t0.addingTimeInterval(2))
        XCTAssertEqual(busy ?? -1, 200, accuracy: 0.001)
    }

    func testCPUPercentNilForResetOrNoTime() {
        XCTAssertNil(StatsMath.cpuPercent(previousUsec: 5_000_000, previousTime: t0, currentUsec: 10, currentTime: t0.addingTimeInterval(2)))
        XCTAssertNil(StatsMath.cpuPercent(previousUsec: 1, previousTime: t0, currentUsec: 2, currentTime: t0))
        XCTAssertNil(StatsMath.rate(previous: 10, current: 5, seconds: 2))
        XCTAssertEqual(StatsMath.rate(previous: 0, current: 2048, seconds: 2), 1024)
    }

    func testTrackerMeasuresFromItsOwnSamples() {
        var tracker = StatsTracker()
        let first = tracker.ingest([
            ContainerStats(id: "web", memoryUsageBytes: 100, netRxBytes: 1000, timestamp: t0, cpuUsageUsec: 1_000_000)
        ])
        // One sample: memory is known, CPU and rates are not.
        XCTAssertNil(first["web"]?.cpuPercent)
        XCTAssertNil(first["web"]?.netRxPerSec)
        XCTAssertEqual(first["web"]?.memoryBytes, 100)

        let second = tracker.ingest([
            ContainerStats(id: "web", memoryUsageBytes: 120, netRxBytes: 3000, timestamp: t0.addingTimeInterval(2), cpuUsageUsec: 1_500_000)
        ])
        XCTAssertEqual(second["web"]?.cpuPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(second["web"]?.netRxPerSec ?? -1, 1000, accuracy: 0.001)
    }

    func testTrackerPrefersCPUFromTheCLIAndForgetsGoneContainers() {
        var tracker = StatsTracker()
        let reported = tracker.ingest([ContainerStats(id: "a", timestamp: t0, reportedCPUPercent: 12.5)])
        XCTAssertEqual(reported["a"]?.cpuPercent, 12.5)

        _ = tracker.ingest([ContainerStats(id: "b", timestamp: t0, cpuUsageUsec: 10)])
        XCTAssertEqual(tracker.knownIDs, ["b"])
        // "a" comes back: it starts over, no percent from a stale reading.
        let back = tracker.ingest([ContainerStats(id: "a", timestamp: t0.addingTimeInterval(4), cpuUsageUsec: 10)])
        XCTAssertNil(back["a"]?.cpuPercent)
    }

    func testTrackerNoRatesAcrossSources() {
        var tracker = StatsTracker()
        // JSON seed (exact counters), then a table frame (rounded counters, CPU from the CLI).
        _ = tracker.ingest([ContainerStats(id: "web", blockReadBytes: 10_617_856, timestamp: t0, cpuUsageUsec: 5)])
        let frame = tracker.ingest([ContainerStats(id: "web", blockReadBytes: 10_622_116, timestamp: t0.addingTimeInterval(2), reportedCPUPercent: 3)])
        XCTAssertEqual(frame["web"]?.cpuPercent, 3)
        XCTAssertNil(frame["web"]?.diskReadPerSec)
        let next = tracker.ingest([ContainerStats(id: "web", blockReadBytes: 10_632_356, timestamp: t0.addingTimeInterval(4), reportedCPUPercent: 4)])
        XCTAssertEqual(next["web"]?.diskReadPerSec ?? -1, 5120, accuracy: 0.001)
    }

    func testJSONStatsKeepRawCounters() throws {
        let json = """
        [{"blockReadBytes":98025472,"blockWriteBytes":30662656,"cpuUsageUsec":1364940,"id":"buildkit","memoryLimitBytes":2147483648,"memoryUsageBytes":144646144,"networkRxBytes":582853,"networkTxBytes":602,"numProcesses":21}]
        """
        let stats = try ContainerOutputParser.stats(json, cache: CPUSampleCache(), now: t0)
        XCTAssertEqual(stats.first?.cpuUsageUsec, 1_364_940)
        XCTAssertNil(stats.first?.reportedCPUPercent)

        let newer = try ContainerOutputParser.stats(#"[{"id":"x","cpuUsageUsec":5,"cpuUtilization":0.25}]"#, cache: CPUSampleCache(), now: t0)
        XCTAssertEqual(newer.first?.reportedCPUPercent ?? -1, 25, accuracy: 0.0001)
    }

    // MARK: Streamed table (recorded from container 1.6.1)

    private let recorded = [
        "\u{1B}[?1049h\u{1B}[?25l\u{1B}[H\u{1B}[JContainer ID  Cpu %  Memory Usage  Net Rx/Tx  Block I/O  Pids",
        "\u{1B}[H\u{1B}[JContainer ID      Cpu %  Memory Usage           Net Rx/Tx              Block I/O               Pids",
        "buildkit          0.01%  137.82 MiB / 2.00 GiB  633.71 KiB / 0.59 KiB  93.48 MiB / 29.24 MiB   21",
        "deck-demo-worker  0.05%  2.70 MiB / 1.00 GiB    594.17 KiB / 0.59 KiB  1.60 MiB / 0.00 KiB     2",
        "deck-demo-web     0.00%  15.77 MiB / 1.00 GiB   626.93 KiB / 0.59 KiB  10.13 MiB / 144.00 KiB  6",
        "\u{1B}[H\u{1B}[JContainer ID      Cpu %  Memory Usage           Net Rx/Tx              Block I/O               Pids",
        "buildkit          1.25%  137.82 MiB / 2.00 GiB  637.01 KiB / 0.59 KiB  93.48 MiB / 29.24 MiB   21"
    ]

    func testParsesTableRow() throws {
        let row = try XCTUnwrap(StatsTableParser.row(recorded[2], at: t0))
        XCTAssertEqual(row.id, "buildkit")
        XCTAssertEqual(row.reportedCPUPercent, 0.01)
        XCTAssertEqual(row.memoryUsageBytes, UInt64((137.82 * 1024 * 1024).rounded()))
        XCTAssertEqual(row.memoryLimitBytes, 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(row.netTxBytes, UInt64((0.59 * 1024).rounded()))
        XCTAssertEqual(row.blockWriteBytes, UInt64((29.24 * 1024 * 1024).rounded()))
        XCTAssertEqual(row.pids, 21)
        XCTAssertEqual(row.timestamp, t0)
    }

    func testParsesMissingValues() throws {
        let row = try XCTUnwrap(StatsTableParser.row("web  --  -- / --  1.00 KiB / --  -- / --  --", at: t0))
        XCTAssertNil(row.reportedCPUPercent)
        XCTAssertEqual(row.netRxBytes, 1024)
        XCTAssertEqual(row.memoryUsageBytes, 0)
    }

    func testRejectsNonRows() {
        XCTAssertNil(StatsTableParser.row(recorded[1], at: t0))
        XCTAssertNil(StatsTableParser.row("error collecting stats: timeout", at: t0))
        XCTAssertNil(StatsTableParser.row("web 1.0% 2 MiB", at: t0))
        XCTAssertNil(StatsTableParser.row("", at: t0))
        XCTAssertTrue(StatsTableParser.isHeader(recorded[0]))
        XCTAssertTrue(StatsTableParser.isError("error collecting stats: x"))
    }

    func testAssemblerEmitsFrameWhenAllRowsArrive() {
        var assembler = StatsFrameAssembler(expectedRows: 3)
        var frames: [[ContainerStats]] = []
        for line in recorded {
            if let frame = assembler.feed(line, at: t0) { frames.append(frame) }
        }
        // The empty first frame is skipped, the full one comes out as soon as its third row arrives.
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.map(\.id), ["buildkit", "deck-demo-worker", "deck-demo-web"])
        XCTAssertEqual(assembler.framesSeen, 1)
    }

    func testAssemblerFlushesShortFrameOnNextHeader() {
        var assembler = StatsFrameAssembler(expectedRows: 3)
        var frames: [[ContainerStats]] = []
        // A container stopped: only one row comes. The next header ends the frame.
        for line in [recorded[1], recorded[6], recorded[1]] {
            if let frame = assembler.feed(line, at: t0) { frames.append(frame) }
        }
        XCTAssertEqual(frames.map { $0.map(\.id) }, [["buildkit"]])
        XCTAssertEqual(frames.first?.first?.reportedCPUPercent, 1.25)
    }

    func testAssemblerDropsFrameOnError() {
        var assembler = StatsFrameAssembler(expectedRows: 2)
        XCTAssertNil(assembler.feed(recorded[1]))
        XCTAssertNil(assembler.feed(recorded[2]))
        XCTAssertNil(assembler.feed("error collecting stats: lost"))
        XCTAssertNil(assembler.feed(recorded[3]))
        XCTAssertEqual(assembler.errorsSeen, 1)
        XCTAssertEqual(assembler.framesSeen, 0)
    }

    func testStreamArguments() {
        let client = ContainerClient(cliPath: "/c", runner: MockRunner())
        XCTAssertEqual(client.statsStreamArguments(["a", "b"]), ["stats", "a", "b"])
    }

    // MARK: Setup checks run at the same time

    func testSetupChecksStillReadAllThreeAnswers() async {
        let runner = MockRunner()
        let path = "/usr/local/bin/container"
        runner.responses["--version"] = CommandResult(exitCode: 0, stdout: "container CLI version 1.6.1", stderr: "")
        runner.responses["system status"] = CommandResult(exitCode: 0, stdout: "apiserver is running", stderr: "")
        runner.responses["system dns list"] = CommandResult(exitCode: 0, stdout: "DOMAIN\ntest\n", stderr: "")
        let files = FileSystem(fileExists: { $0 == path }, isExecutable: { $0 == path }, contentsOfDirectory: { _ in [] })
        let env = SetupEnvironment(system: SystemInfo(isAppleSilicon: true, osMajor: 26, osMinor: 0), files: files,
                                   pathEnv: "/usr/local/bin", customCLIPath: nil, appRoot: "/tmp/none")
        let report = await SetupService(runner: runner, environment: env).runChecks()
        XCTAssertEqual(report.cliVersion, SemanticVersion(1, 6, 1))
        XCTAssertTrue(report.serviceRunning)
        XCTAssertEqual(report.checks.first { $0.id == .dns }?.state.isPassing, true)
        XCTAssertEqual(Set(runner.calls.map { $0.dropFirst().joined(separator: " ") }), ["--version", "system status", "system dns list"])
    }
}
