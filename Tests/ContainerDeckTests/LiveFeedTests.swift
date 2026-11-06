import XCTest
import DeckCore
@testable import ContainerDeck

@MainActor
final class LiveFeedTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testFeedOrderRunningFirstThenName() {
        let list = [
            ContainerSummary(id: "b", name: "b", image: "x", state: .stopped),
            ContainerSummary(id: "z", name: "z", image: "x", state: .running),
            ContainerSummary(id: "a", name: "a", image: "x", state: .running)
        ]
        XCTAssertEqual(BackgroundServices.ordered(list).map(\.id), ["a", "z", "b"])
    }

    func testLiveRowOrderHoldsRowsAndResetsOnNewSort() {
        let keeper = LiveRowOrder()
        let band = StableOrder.band(absolute: 1, relative: 0.15)
        XCTAssertEqual(keeper.order([("a", 10), ("b", 9.5)], key: "cpu", descending: true, threshold: band), ["a", "b"])
        // b passes a by a hair: no jump.
        XCTAssertEqual(keeper.order([("a", 9.6), ("b", 10)], key: "cpu", descending: true, threshold: band), ["a", "b"])
        // A different sort starts fresh and sorts fully.
        XCTAssertEqual(keeper.order([("a", 9.6), ("b", 10)], key: "cpu-asc", descending: false, threshold: band), ["a", "b"])
        XCTAssertEqual(keeper.order([("a", 9.6), ("b", 10)], key: "cpu-desc", descending: true, threshold: band), ["b", "a"])
    }

    func testSampleFromReadingMarksMeasuring() {
        let waiting = ContainerStatsSample(StatsReading(id: "web", date: t0, cpuPercent: nil, memoryBytes: 2048, memoryLimitBytes: 4096))
        XCTAssertFalse(waiting.cpuMeasured)
        XCTAssertEqual(waiting.cpuPercent, 0)
        XCTAssertEqual(waiting.memoryBytes, 2048)

        let ready = ContainerStatsSample(StatsReading(id: "web", date: t0, cpuPercent: 12, memoryBytes: 1, memoryLimitBytes: 1, netRxPerSec: 5))
        XCTAssertTrue(ready.cpuMeasured)
        XCTAssertEqual(ready.netRxPerSec, 5)
    }

    func testDashboardWindowUsesRealTimestamps() {
        func sample(_ offset: Double) -> ContainerStatsSample {
            ContainerStatsSample(date: t0.addingTimeInterval(offset), cpuPercent: 0, memoryBytes: 0, memoryLimitBytes: 0,
                                 netRxPerSec: 0, netTxPerSec: 0, diskReadPerSec: 0, diskWritePerSec: 0, pids: 0)
        }
        XCTAssertNil(DashboardModel.windowText([sample(0)]))
        // 20 samples 2.2 s apart is about 42 seconds, not 20 x the refresh setting.
        XCTAssertEqual(DashboardModel.windowText((0..<20).map { sample(Double($0) * 2.2) }), "42 seconds")
        XCTAssertEqual(DashboardModel.windowText([sample(0), sample(300)]), "5 minutes")
    }

    func testCommitSuggestedName() {
        let item = ContainerSummary(id: "abc", name: "My Web_1", image: "nginx", state: .running)
        let name = CommitSheet.suggestedName(for: item)
        XCTAssertEqual(name, "my-web_1-snapshot:latest")
        XCTAssertNil(ImageReferenceCheck.problem(name))
    }
}
