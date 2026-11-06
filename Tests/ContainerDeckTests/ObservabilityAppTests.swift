import XCTest
@testable import ContainerDeck
import DeckCore

@MainActor
final class ObservabilityAppTests: XCTestCase {
    func testLogsModelAddsUpToFourPanes() {
        let model = LogsModel(containerIDs: ["a", "b"])
        XCTAssertEqual(model.panes.map(\.containerID), ["a", "b"])
        XCTAssertEqual(model.panes.map(\.colorSlot), [0, 1])
        model.add("c")
        model.add("d")
        XCTAssertFalse(model.canAdd)
        XCTAssertNil(model.add("e"))
        XCTAssertEqual(model.panes.count, 4)
        XCTAssertEqual(model.savedValue, "a,b,c,d")
    }

    func testLogsModelReusesPanes() {
        let model = LogsModel()
        XCTAssertEqual(model.panes.count, 1, "starts with one empty pane")
        XCTAssertNil(model.panes[0].containerID)
        model.add("web")
        XCTAssertEqual(model.panes.count, 1, "the empty pane is filled first")
        XCTAssertEqual(model.panes[0].containerID, "web")
        model.add("web")
        XCTAssertEqual(model.panes.count, 1, "the same container is not shown twice")
    }

    func testRemovingKeepsColorsAndRefillsTheGap() {
        let model = LogsModel(containerIDs: ["a", "b", "c"])
        model.remove(model.panes[1])
        XCTAssertEqual(model.panes.map(\.colorSlot), [0, 2])
        model.add("d")
        XCTAssertEqual(model.panes.last?.colorSlot, 1)
        model.remove(model.panes[0])
        model.remove(model.panes[0])
        model.remove(model.panes[0])
        XCTAssertEqual(model.panes.count, 1, "never zero panes")
        XCTAssertNil(model.panes[0].containerID)
    }

    func testRestoreSavedPanes() {
        XCTAssertEqual(LogsModel.restore("a, b,,c"), ["a", "b", "c"])
        XCTAssertEqual(LogsModel.restore(""), [])
    }

    func testPausedPaneCountsNewLines() {
        let pane = LogPaneModel(containerID: "a", colorSlot: 0)
        XCTAssertFalse(pane.isPaused)
        pane.setPaused(true)
        XCTAssertTrue(pane.isPaused)
        XCTAssertEqual(pane.newWhilePaused, 0)
        pane.setPaused(false)
        XCTAssertFalse(pane.isPaused)
    }

    func testContainerChoicesPutRunningFirstAndHideBuilder() {
        let list = LogsContainerChoices.list([
            ContainerSummary(id: "zeta", name: "zeta", image: "x", state: .running),
            ContainerSummary(id: "alpha", name: "alpha", image: "x", state: .stopped),
            ContainerSummary(id: "buildkit", name: "buildkit", image: "x", state: .running),
            ContainerSummary(id: "beta", name: "beta", image: "x", state: .running)
        ])
        XCTAssertEqual(list.map(\.id), ["beta", "zeta", "alpha"])
    }

    func testNiceTop() {
        XCTAssertEqual(HistoryScale.niceTop(87), 100)
        XCTAssertEqual(HistoryScale.niceTop(101), 200)
        XCTAssertEqual(HistoryScale.niceTop(2.1), 2.5)
        XCTAssertEqual(HistoryScale.niceTop(0), 1)
        XCTAssertEqual(HistoryScale.niceTop(.infinity), 1)
    }

    func testRateText() {
        XCTAssertEqual(HistoryScale.rate(0), "0 B/s")
        XCTAssertEqual(HistoryScale.rate(512), "512 B/s")
        XCTAssertTrue(HistoryScale.rate(2_000_000).hasSuffix("/s"))
    }

    func testPaletteWraps() {
        XCTAssertEqual(LogPalette.colors.count, 6)
        _ = LogPalette.color(-1)
        _ = LogPalette.color(13)
    }
}
