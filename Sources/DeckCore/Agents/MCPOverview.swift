import Foundation

/// One row of the "every MCP server on this Mac" list: a server we installed, or a server
/// found in agent configs (the same name and target in several agents is one row).
public struct MCPOverviewRow: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable, Hashable {
        /// Long running container is up.
        case running
        /// Long running container is not up.
        case stopped
        /// stdio: the agent starts it when needed.
        case onDemand
        /// Only in an agent config (not run by us).
        case external
    }

    public var id: String
    public var name: String
    public var transport: MCPTransport
    public var target: String
    public var installed: MCPInstalledServer?
    public var entries: [DiscoveredMCPServer]
    public var status: Status
    /// Live containers of this server (long running one, or stdio sessions an agent started).
    public var containers: [String]

    public var agents: [AgentKind] {
        var seen = Set<AgentKind>()
        return entries.map(\.agent).filter { seen.insert($0).inserted }
    }

    public var isManaged: Bool { installed != nil }
}

public enum MCPOverview {
    public static func rows(installed: [MCPInstalledServer], discovered: [DiscoveredMCPServer],
                            containers: [ContainerSummary], cliPath: String) -> [MCPOverviewRow] {
        let live = ContainerClient.mcpContainers(containers)
        var used = Set<String>()
        var rows: [MCPOverviewRow] = []

        for server in installed {
            let url = MCPLaunch.url(server)
            let matches = discovered.filter { entry in
                entry.managedServer == server.name || (url != nil && entry.url == url)
            }
            matches.forEach { used.insert($0.id) }
            let running = live[server.name]?.filter { $0.state == .running } ?? []
            let status: MCPOverviewRow.Status
            if server.isLongRunning {
                status = running.contains { $0.name == MCPLaunch.containerName(server) } ? .running : .stopped
            } else {
                status = .onDemand
            }
            let entry = MCPLaunch.entry(server, cliPath: cliPath)
            rows.append(MCPOverviewRow(
                id: "deck:" + server.name, name: server.name, transport: server.transport,
                target: server.kind == .hostCommand ? entry.target : (url ?? server.image),
                installed: server, entries: matches, status: status, containers: running.map(\.name)
            ))
        }

        // Group the rest by name and target.
        var groups: [String: [DiscoveredMCPServer]] = [:]
        var order: [String] = []
        for entry in discovered where !used.contains(entry.id) {
            let key = entry.name + "\u{1F}" + entry.target
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        for key in order {
            guard let entries = groups[key], let first = entries.first else { continue }
            rows.append(MCPOverviewRow(
                id: "cfg:" + key, name: first.name, transport: first.transport, target: first.target,
                installed: nil, entries: entries, status: .external, containers: []
            ))
        }
        return rows
    }
}
