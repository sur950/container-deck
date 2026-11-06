import Foundation

/// Container calls for MCP servers.
public extension ContainerClient {
    /// `container run` arguments for a long running HTTP or SSE server.
    /// `envFile` carries the secrets so they never show up in the process list.
    func mcpServerRunArguments(_ server: MCPInstalledServer, envFile: String? = nil) throws -> [String] {
        var args = runArguments(try MCPLaunch.runOptions(server))
        if let envFile, let imageIndex = args.lastIndex(of: server.image) {
            args.insert(contentsOf: ["--env-file", envFile], at: imageIndex)
        }
        return args
    }

    /// Starts a long running server container. Any old container with the same name is removed first.
    /// Returns the container id.
    @discardableResult
    func startMCPServer(_ server: MCPInstalledServer, secrets: [String: String] = [:]) async throws -> String {
        let name = MCPLaunch.containerName(server)
        _ = try? await runner.run(cli.path, ["delete", "--force", name])
        var envFile: URL?
        if !secrets.isEmpty {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("deck-mcp-\(UUID().uuidString).env")
            let body = secrets.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
            FileManager.default.createFile(atPath: file.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o600])
            envFile = file
        }
        defer { if let envFile { try? FileManager.default.removeItem(at: envFile) } }
        let result = try await run(try mcpServerRunArguments(server, envFile: envFile?.path))
        return ContainerOutputParser.runOutputID(result.stdout) ?? name
    }

    /// Stops and removes the server container.
    func stopMCPServer(_ server: MCPInstalledServer) async throws {
        let name = MCPLaunch.containerName(server)
        _ = try? await runner.run(cli.path, ["stop", name])
        let result = try await runner.run(cli.path, ["delete", "--force", name])
        if !result.succeeded, !result.failureMessage.lowercased().contains("not found") {
            throw DeckError.commandFailed(result.failureMessage)
        }
    }

    /// Containers that run one of our MCP servers (long running and live stdio sessions).
    static func mcpContainers(_ containers: [ContainerSummary]) -> [String: [ContainerSummary]] {
        Dictionary(grouping: containers.filter { $0.labels[AgentsConfig.serverLabel] != nil }) {
            $0.labels[AgentsConfig.serverLabel] ?? ""
        }
    }
}
