import XCTest
import DeckCore
@testable import ContainerDeck

/// Palette and deep link navigation goes through AppState (no notifications), so it
/// works in release builds where DebugAutomation is off.
@MainActor
final class FocusRoutingTests: XCTestCase {
    func testOpenContainerWithTab() {
        let state = AppState()
        state.selection = .dashboard
        state.openContainer("deck-demo-worker", tab: .logs)
        XCTAssertEqual(state.selection, .containers)
        XCTAssertEqual(state.focusedContainerID, "deck-demo-worker")
        XCTAssertEqual(state.focusedContainerTab, ContainerTabFocus(containerID: "deck-demo-worker", tab: .logs))
    }

    func testOpenContainerWithoutTabClearsAnOldTabRequest() {
        let state = AppState()
        state.openContainer("a", tab: .stats)
        state.openContainer("b")
        XCTAssertEqual(state.focusedContainerID, "b")
        XCTAssertNil(state.focusedContainerTab)
    }

    func testTabRequestOnlyMatchesItsContainer() {
        let focus = ContainerTabFocus(containerID: "web", tab: .logs)
        XCTAssertEqual(focus.tab(forContainer: "web"), .logs)
        XCTAssertNil(focus.tab(forContainer: "db"), "Another open detail must not take it")
        XCTAssertEqual(focus.tab(forContainer: "3f2a", name: "web"), .logs, "A name works too")
        XCTAssertNil(focus.tab(forContainer: "3f2a", name: ""))
    }

    func testPaletteOpensContainerTabThroughState() async {
        let state = AppState()
        await PaletteRunner.run(.containerOpen(id: "deck-demo-worker", tab: "logs"), state: state)
        XCTAssertEqual(state.selection, .containers)
        XCTAssertEqual(state.focusedContainerID, "deck-demo-worker")
        XCTAssertEqual(state.focusedContainerTab?.tab, .logs)
    }

    func testPaletteUnknownTabOpensOverview() async {
        let state = AppState()
        await PaletteRunner.run(.containerOpen(id: "x", tab: "nope"), state: state)
        XCTAssertEqual(state.focusedContainerID, "x")
        XCTAssertNil(state.focusedContainerTab)
    }

    func testPaletteOpensComposeStackThroughState() async {
        let state = AppState()
        await PaletteRunner.run(.stackOpen(name: "shop", file: "/tmp/shop/compose.yaml"), state: state)
        XCTAssertEqual(state.selection, .compose)
        XCTAssertEqual(state.focusedComposeStack, ComposeStackFocus(name: "shop", file: "/tmp/shop/compose.yaml"))
    }

    func testComposeFocusPrefersAnExistingFile() {
        let focus = ComposeStackFocus(name: "shop", file: "/x/compose.yaml")
        XCTAssertEqual(focus.selection(fileExists: { _ in true }), .file("/x/compose.yaml"))
        XCTAssertEqual(focus.selection(fileExists: { _ in false }), .stack("shop"))
        XCTAssertEqual(ComposeStackFocus(name: "shop", file: nil).selection(fileExists: { _ in true }), .stack("shop"))
    }

    func testDeepLinkSetsContainerFocus() {
        let state = AppState()
        DeepLinkRouter.route(.container("deck-demo-web"), state: state)
        XCTAssertEqual(state.selection, .containers)
        XCTAssertEqual(state.focusedContainerID, "deck-demo-web")
    }

    func testPollPaceFollowsTheBackend() {
        // Direct API: 1 s with a window, 3 s with the panel.
        XCTAssertEqual(BackgroundServices.interval(for: .foreground, direct: true, preferred: 3), 1)
        XCTAssertEqual(BackgroundServices.interval(for: .panel, direct: true, preferred: 3), 3)
        XCTAssertEqual(BackgroundServices.interval(for: .background, direct: true, preferred: 3), 10)
        // The container command: the setting, 5 s for the panel, 10 s with nothing visible.
        XCTAssertEqual(BackgroundServices.interval(for: .foreground, direct: false, preferred: 3), 3)
        XCTAssertEqual(BackgroundServices.interval(for: .panel, direct: false, preferred: 3), 5)
        XCTAssertEqual(BackgroundServices.interval(for: .background, direct: false, preferred: 3), 10)
    }
}

@MainActor
final class PanelSignatureTests: XCTestCase {
    func testPanelSkipsUpdatesThatLookTheSame() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = ["web": StatsReading(id: "web", date: t0, cpuPercent: 1.04, memoryBytes: 16_500_000, memoryLimitBytes: 1)]
        let b = ["web": StatsReading(id: "web", date: t0.addingTimeInterval(3), cpuPercent: 0.98, memoryBytes: 16_700_000, memoryLimitBytes: 1)]
        let c = ["web": StatsReading(id: "web", date: t0, cpuPercent: 1.2, memoryBytes: 16_500_000, memoryLimitBytes: 1)]
        XCTAssertEqual(StatsSampler.panelSignature(a), StatsSampler.panelSignature(b), "Same to 0.1 % and 1 MB")
        XCTAssertNotEqual(StatsSampler.panelSignature(a), StatsSampler.panelSignature(c))
    }
}
