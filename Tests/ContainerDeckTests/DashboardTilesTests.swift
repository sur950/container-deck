import XCTest
import DeckCore
@testable import ContainerDeck

final class DashboardTilesTests: XCTestCase {
    private func box(_ id: String, _ state: ContainerRunState = .running, labels: [String: String] = [:]) -> ContainerSummary {
        ContainerSummary(id: id, name: id, image: "img", state: state, labels: labels)
    }

    private func node(_ id: String, role: String, _ state: ContainerRunState = .running) -> ContainerSummary {
        box(id, state, labels: [KubernetesConfig.pluginLabel: KubernetesConfig.pluginName, KubernetesConfig.roleLabel: role])
    }

    func testEmptyListShowsNoneYet() {
        let counts = DashboardCounts.make([])
        XCTAssertEqual(counts, DashboardCounts())
        XCTAssertEqual(counts.containersSubtitle, "of 0")
        XCTAssertEqual(counts.kubernetesSubtitle, "None yet")
        XCTAssertEqual(counts.sandboxesSubtitle, "None yet")
        XCTAssertEqual(DashboardCounts.machinesSubtitle([]), "None yet")
    }

    func testContainersAndComposeStacks() {
        let list = [
            box("web", labels: [ComposeLabel.dockerProject: "shop"]),
            box("db", .stopped, labels: [ComposeLabel.dockerProject: "shop"]),
            box("api", .stopped, labels: [ComposeLabel.project: "blog"]),
            box("solo"),
            box("old", .stopped)
        ]
        let counts = DashboardCounts.make(list)
        XCTAssertEqual(counts.containers, 5)
        XCTAssertEqual(counts.containersRunning, 2)
        XCTAssertEqual(counts.composeStacks, 2)
        XCTAssertEqual(counts.containersSubtitle, "of 5, 2 stacks")
        XCTAssertEqual(DashboardCounts.make([list[0]]).containersSubtitle, "of 1, 1 stack")
        XCTAssertEqual(DashboardCounts.make([box("a"), box("b")]).containersSubtitle, "of 2")
    }

    func testCountsPrintShort() {
        let many = (0..<1_234).map { box("c\($0)", .stopped) }
        XCTAssertEqual(DashboardCounts.make(many).containersSubtitle, "of 1.2K")
        XCTAssertEqual(DashboardCounts.count(15_300), "15K")
        XCTAssertEqual(DashboardCounts.plural(2_450_000, "model"), "2.5M models")
    }

    func testClustersAndNodes() {
        let list = [
            node("dev", role: "control-plane"),
            node("dev-worker-1", role: "worker"),
            node("dev-worker-2", role: "worker", .stopped),
            node("lab", role: "control-plane,worker", .stopped),
            box("web")
        ]
        let counts = DashboardCounts.make(list)
        XCTAssertEqual(counts.clusters, 2)
        // A cluster with one worker down still counts as up.
        XCTAssertEqual(counts.clustersRunning, 1)
        XCTAssertEqual(counts.nodes, 4)
        XCTAssertEqual(counts.kubernetesSubtitle, "4 nodes")
        XCTAssertEqual(DashboardCounts.make([list[3]]).kubernetesSubtitle, "1 node")
    }

    func testSandboxes() {
        let list = [
            box("agent-a", labels: [SandboxConfig.label: SandboxConfig.labelVersion]),
            box("agent-b", .stopped, labels: [SandboxConfig.label: SandboxConfig.labelVersion]),
            box("web")
        ]
        let counts = DashboardCounts.make(list)
        XCTAssertEqual(counts.sandboxes, 2)
        XCTAssertEqual(counts.sandboxesRunning, 1)
        XCTAssertEqual(counts.sandboxesSubtitle, "of 2")
    }

    func testMCPServersCountRunningByName() {
        let list = [
            box("mcp-fetch", labels: [AgentsConfig.serverLabel: "fetch"]),
            // Two stdio sessions of one server count once.
            box("mcp-git-1", labels: [AgentsConfig.serverLabel: "git"]),
            box("mcp-git-2", labels: [AgentsConfig.serverLabel: "git"]),
            box("mcp-old", .stopped, labels: [AgentsConfig.serverLabel: "memory"]),
            box("web")
        ]
        XCTAssertEqual(DashboardCounts.make(list).mcpRunning, 2)
        XCTAssertEqual(DashboardCounts.make([list[3]]).mcpRunning, 0)
    }

    func testMachines() {
        let list = [
            MachineSummary(name: "dev", state: .running),
            MachineSummary(name: "old", state: .stopped)
        ]
        XCTAssertEqual(DashboardCounts.machineCounts(list).running, 1)
        XCTAssertEqual(DashboardCounts.machineCounts(list).total, 2)
        XCTAssertEqual(DashboardCounts.machinesSubtitle(list), "of 2")
    }

    func testAIServersAndModels() {
        func endpoint(_ id: String, _ status: ModelEndpointStatus, models: Int) -> ModelEndpoint {
            ModelEndpoint(id: id, kind: .ollama, name: "Ollama", host: "127.0.0.1", port: 11434,
                          baseURL: URL(string: "http://127.0.0.1:11434/v1")!, status: status,
                          models: (0..<models).map { ModelEndpointModel(id: "m\($0)") })
        }
        XCTAssertEqual(DashboardCounts.aiSubtitle([]), "None running")
        let list = [
            endpoint("a", .running, models: 3),
            endpoint("b", .running, models: 1),
            endpoint("c", .notResponding, models: 5)
        ]
        XCTAssertEqual(DashboardCounts.aiCounts(list).servers, 2)
        XCTAssertEqual(DashboardCounts.aiCounts(list).models, 4)
        XCTAssertEqual(DashboardCounts.aiSubtitle(list), "4 models served")
        XCTAssertEqual(DashboardCounts.aiSubtitle([endpoint("a", .running, models: 1)]), "1 model served")
    }

    func testSixTilesWrapEvenly() {
        XCTAssertEqual(DashboardFormat.tileColumns(width: 1100, tiles: 6), 6)
        XCTAssertEqual(DashboardFormat.tileColumns(width: 700, tiles: 6), 3)
        XCTAssertEqual(DashboardFormat.tileColumns(width: 400, tiles: 6), 2)
    }
}
