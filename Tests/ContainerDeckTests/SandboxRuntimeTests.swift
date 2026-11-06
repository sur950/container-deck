import XCTest
import DeckCore
@testable import ContainerDeck

@MainActor
final class SandboxRuntimeTests: XCTestCase {
    private func container(_ name: String, egress: SandboxEgress, state: ContainerRunState) -> ContainerSummary {
        let options = SandboxPlanner.runOptions(SandboxSpec(name: name, image: "alpine", egress: egress),
                                                gateway: "10.255.255.254", subnet: nil, hasKey: false)
        return ContainerSummary(id: name, name: name, image: "alpine", state: state, labels: options.labels)
    }

    func testReconcileListsOnlySandboxes() {
        let runtime = SandboxRuntime.shared
        let plain = ContainerSummary(id: "web", name: "web", image: "nginx", state: .running)
        runtime.reconcile([plain, container("test-sbx-b", egress: .open, state: .stopped), container("test-sbx-a", egress: .isolated, state: .running)])
        XCTAssertEqual(runtime.sandboxes.map(\.name), ["test-sbx-a", "test-sbx-b"])
        // No model and no allow list: nothing to run for these.
        XCTAssertTrue(runtime.activeServices.isEmpty)
        runtime.reconcile([])
        XCTAssertTrue(runtime.sandboxes.isEmpty)
    }

    func testSelectionLivesInRuntime() {
        let runtime = SandboxRuntime.shared
        runtime.selection = "test-sbx-a"
        XCTAssertEqual(SandboxRuntime.shared.selection, "test-sbx-a")
        runtime.selection = nil
    }

    func testKillStateClears() {
        let runtime = SandboxRuntime.shared
        XCTAssertFalse(runtime.isKilled("test-sbx-k"))
        runtime.clearKill("test-sbx-k")
        XCTAssertFalse(runtime.isKilled("test-sbx-k"))
    }

    func testEgressPillTitles() {
        XCTAssertEqual(SandboxEgress.isolated.title, "Isolated")
        XCTAssertEqual(SandboxEgress.open.title, "Internet")
        XCTAssertEqual(SandboxEgress.allowList.title, "Allow list")
    }
}
