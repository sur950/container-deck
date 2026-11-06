import Foundation

/// Steps of creating a sandbox, for progress in the form.
public enum SandboxCreateStep: String, Sendable {
    case network = "Creating the network"
    case container = "Starting the container"
    case secrets = "Adding the model settings"
}

public extension ContainerClient {
    /// Sandboxes from a container list (no extra call).
    static func sandboxes(in containers: [ContainerSummary]) -> [Sandbox] {
        containers.compactMap(Sandbox.init(container:)).sorted { $0.name < $1.name }
    }

    /// All sandboxes, running or not.
    func listSandboxes() async throws -> [Sandbox] {
        Self.sandboxes(in: try await listContainers(all: true))
    }

    /// `network create` arguments for a sandbox network.
    func sandboxNetworkArguments(_ spec: SandboxSpec, subnet: String? = nil) -> [String] {
        networkCreateArguments(name: spec.networkName, subnet: subnet, internal: spec.egress.isInternal, labels: SandboxPlanner.networkLabels(spec))
    }

    /// Creates the network and the container, then writes the key into memory inside it.
    /// Undoes the network when the container cannot start.
    @discardableResult
    func createSandbox(_ spec: SandboxSpec, apiKey: String?, progress: @Sendable (SandboxCreateStep) -> Void = { _ in }) async throws -> String {
        progress(.network)
        let existing = try await listNetworkSummaries().first { $0.name == spec.networkName }
        var createdNetwork = false
        var createdChatVolume = false
        if existing == nil {
            try await run(sandboxNetworkArguments(spec))
            createdNetwork = true
        }
        do {
            guard let network = try await listNetworkSummaries().first(where: { $0.name == spec.networkName }),
                  let gateway = network.gateway else {
                throw DeckError.commandFailed("The sandbox network has no gateway address.")
            }
            progress(.container)
            let hasKey = !(apiKey ?? "").isEmpty
            let options = SandboxPlanner.runOptions(spec, gateway: gateway, subnet: network.subnet, hasKey: hasKey)
            let chatVolume = ChatVolumeSync.sandboxVolume(spec.name)
            if spec.saveChatHistory, try await !chatVolumeExists(chatVolume) {
                try await createVolume(name: chatVolume, labels: ChatVolumeSync.sandboxVolumeLabels(spec.name))
                createdChatVolume = true
            }
            let id = try await runContainer(options)
            progress(.secrets)
            try await writeSandboxSecrets(id.isEmpty ? spec.name : id, apiKey: apiKey)
            return id.isEmpty ? spec.name : id
        } catch {
            // Leave nothing half made behind.
            _ = try? await run(["delete", "--force", spec.name])
            if createdNetwork { _ = try? await run(["network", "delete", spec.networkName]) }
            if createdChatVolume { _ = try? await deleteVolume(ChatVolumeSync.sandboxVolume(spec.name)) }
            throw error
        }
    }

    /// Writes the env script and (when given) the key into the sandbox's tmpfs. The key goes
    /// over stdin, so it is never in a process argument list or on disk.
    func writeSandboxSecrets(_ id: String, apiKey: String?) async throws {
        try await run(["exec", "--interactive", "--uid", "0", id, "/bin/sh", "-c", SandboxPlanner.envScriptWriter],
                      stdin: SandboxPlanner.envScriptBody)
        if let apiKey, !apiKey.isEmpty {
            try await run(["exec", "--interactive", "--uid", "0", id, "/bin/sh", "-c", SandboxPlanner.secretScript], stdin: apiKey)
        }
    }

    /// Starts a stopped sandbox. Brings back its network first if it was removed,
    /// on the same subnet so the proxy and model addresses stay the same.
    func startSandbox(_ sandbox: Sandbox, apiKey: String?) async throws {
        if try await listNetworkSummaries().first(where: { $0.name == sandbox.networkName }) == nil {
            let args = networkCreateArguments(name: sandbox.networkName, subnet: sandbox.subnet, internal: sandbox.egress.isInternal,
                                              labels: [SandboxConfig.label: SandboxConfig.labelVersion, SandboxConfig.labelEgress: sandbox.egress.rawValue])
            try await run(args)
        }
        try await startContainer(sandbox.container.id)
        try await writeSandboxSecrets(sandbox.container.id, apiKey: apiKey)
    }

    /// Kill switch: SIGKILL right away. The VM and its network link go with it.
    func killSandbox(_ sandbox: Sandbox) async throws {
        try await run(["kill", sandbox.container.id])
    }

    /// Removes the container and its network, and its chat history volume unless asked to keep it.
    func removeSandbox(_ sandbox: Sandbox, keepChatHistory: Bool = false) async throws {
        try await run(["delete", "--force", sandbox.container.id])
        // Another container may still use the network. Not an error.
        _ = try? await run(["network", "delete", sandbox.networkName])
        if !keepChatHistory {
            let volume = sandbox.chatVolume ?? ChatVolumeSync.sandboxVolume(sandbox.name)
            // Older sandboxes may never have made one.
            if try await listVolumes().contains(where: { $0.name == volume }) {
                try await deleteVolume(volume)
            }
        }
    }

    /// Terminal command line for a sandbox shell.
    func sandboxShellCommand(_ sandbox: Sandbox) -> String {
        SandboxPlanner.shellQuote([cliPath] + SandboxPlanner.shellArguments(sandbox))
    }

    /// Sends a chat from inside the sandbox. Returns the reply text.
    func sandboxChat(_ sandbox: Sandbox, model: String, messages: [SandboxChatMessage]) async throws -> String {
        guard let base = sandbox.containerModelURL, let kind = sandbox.model?.kind else {
            throw DeckError.commandFailed("This sandbox has no model.")
        }
        let body = try SandboxChat.requestBody(model: model, messages: messages)
        let result = try await runner.run(cli.path, sandboxRequestArguments(sandbox, url: SandboxChat.completionsURL(base: base, kind: kind)), stdin: body)
        guard result.succeeded else {
            let detail = [result.stderr, result.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            throw DeckError.commandFailed(detail ?? "The request from the sandbox failed.")
        }
        return try SandboxChat.parseReply(result.stdout)
    }

    /// Model ids the sandbox can see (asks from inside the container).
    func sandboxModels(_ sandbox: Sandbox) async throws -> [String] {
        guard let base = sandbox.containerModelURL, let kind = sandbox.model?.kind else { return [] }
        let result = try await runner.run(cli.path, sandboxRequestArguments(sandbox, url: SandboxChat.modelsURL(base: base, kind: kind)), stdin: Data())
        guard result.succeeded else { return [] }
        return SandboxChat.parseModels(result.stdout)
    }

    func sandboxRequestArguments(_ sandbox: Sandbox, url: String) -> [String] {
        ["exec", "--interactive", sandbox.container.id, "/bin/sh", "-c", SandboxChat.postScript, "deck-chat", url]
    }
}
