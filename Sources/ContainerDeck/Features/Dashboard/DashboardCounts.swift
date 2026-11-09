import Foundation
import DeckCore

/// Counts behind the Dashboard tiles. Pure: everything comes from the shared container
/// list (labels and run state), the machine list and the AI server discovery, so no
/// screen needs its own loop to fill the tiles. Counts print short (1.2K) via `CountFormat`.
struct DashboardCounts: Equatable {
    var containersRunning = 0
    var containers = 0
    /// Compose stacks found by their project labels (ours or Docker's).
    var composeStacks = 0
    /// Kubernetes clusters from the plugin's node containers.
    var clusters = 0
    var clustersRunning = 0
    var nodes = 0
    var sandboxes = 0
    var sandboxesRunning = 0
    /// MCP servers with a running container, by server name.
    var mcpRunning = 0

    static func make(_ containers: [ContainerSummary]) -> DashboardCounts {
        var counts = DashboardCounts()
        counts.containers = containers.count
        counts.containersRunning = containers.filter(\.isRunning).count

        counts.composeStacks = Set(containers.compactMap { ComposeLabel.projectName($0.labels) }).count

        let clusters = KubeClusterParser.clusters(from: containers)
        counts.clusters = clusters.count
        counts.clustersRunning = clusters.filter { $0.state == .running || $0.state == .partial }.count
        counts.nodes = clusters.reduce(0) { $0 + $1.nodes.count }

        let sandboxes = ContainerClient.sandboxes(in: containers)
        counts.sandboxes = sandboxes.count
        counts.sandboxesRunning = sandboxes.filter(\.isRunning).count

        // One server can have several containers (stdio sessions), so count by name.
        let mcp = ContainerClient.mcpContainers(containers.filter(\.isRunning))
        counts.mcpRunning = mcp.keys.filter { !$0.isEmpty }.count
        return counts
    }

    // MARK: Tile text

    /// "of 5", or "of 5, 2 stacks" when compose stacks exist.
    var containersSubtitle: String {
        guard composeStacks > 0 else { return "of \(Self.count(containers))" }
        return "of \(Self.count(containers)), \(Self.plural(composeStacks, "stack"))"
    }

    var kubernetesSubtitle: String {
        clusters == 0 ? "None yet" : Self.plural(nodes, "node")
    }

    var sandboxesSubtitle: String {
        sandboxes == 0 ? "None yet" : "of \(Self.count(sandboxes))"
    }

    // MARK: Machines

    static func machineCounts(_ machines: [MachineSummary]) -> (running: Int, total: Int) {
        (machines.filter { $0.state == .running }.count, machines.count)
    }

    static func machinesSubtitle(_ machines: [MachineSummary]) -> String {
        machines.isEmpty ? "None yet" : "of \(count(machines.count))"
    }

    // MARK: AI servers

    /// Running model servers and the models they serve.
    static func aiCounts(_ endpoints: [ModelEndpoint]) -> (servers: Int, models: Int) {
        let running = endpoints.filter(\.isRunning)
        return (running.count, running.reduce(0) { $0 + $1.models.count })
    }

    static func aiSubtitle(_ endpoints: [ModelEndpoint]) -> String {
        let counts = aiCounts(endpoints)
        if counts.servers == 0 { return "None running" }
        return "\(plural(counts.models, "model")) served"
    }

    // MARK: AI models on disk

    /// "6 models from Ollama, LM Studio and MLX", or "None downloaded".
    static func modelsSummary(_ totals: ModelDiskTotals) -> String {
        guard totals.count > 0 else { return "None downloaded" }
        let sources = ModelSource.allCases
            .filter { (totals.bySource[$0] ?? 0) > 0 || totals.bySource[$0] != nil }
            .sorted { (totals.bySource[$0] ?? 0) > (totals.bySource[$1] ?? 0) }
            .map(\.displayName)
        let list: String
        switch sources.count {
        case 0: list = ""
        case 1: list = sources[0]
        default: list = sources.dropLast().joined(separator: ", ") + " and " + sources.last!
        }
        return list.isEmpty ? plural(totals.count, "model") : "\(plural(totals.count, "model")) from \(list)"
    }

    /// 999, 1.2K, 2.5M.
    static func count(_ value: Int) -> String {
        CountFormat.compact(value)
    }

    static func plural(_ value: Int, _ word: String) -> String {
        value == 1 ? "1 \(word)" : "\(count(value)) \(word)s"
    }
}
