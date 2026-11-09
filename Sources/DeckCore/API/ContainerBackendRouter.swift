import Foundation

/// Runs each container operation over the direct API when it can, and through the
/// CLI otherwise. Same method signatures as `ContainerClient` (`ContainerOperations`).
///
/// Per call:
/// - `BackendSelector` says direct, CLI, or "services stopped".
/// - A direct read that fails on the transport (timeout, interrupted, unreadable
///   reply, request rejected) is done again through the CLI and counted.
/// - A direct change is retried through the CLI only when the daemon surely did
///   not act on it (see `APIError.requestNotApplied`). After a timeout it is not.
/// - `.needsCLI` goes to the CLI without counting a failure.
/// - Errors the daemon reports (no such container, volume in use) are shown as they
///   are, like the CLI would.
/// - No service: the error says the services are not running.
///
/// `cli` must be a plain `ContainerClient` (one that does not route back here).
public final class ContainerBackendRouter: ContainerOperations {
    public let cli: ContainerClient
    public let api: DirectAPIClient
    public let selector: BackendSelector

    public init(cli: ContainerClient, api: DirectAPIClient = DirectAPIClient(), selector: BackendSelector? = nil) {
        // The CLI path must never come back here.
        var plain = cli
        plain.router = nil
        self.cli = plain
        self.api = api
        self.selector = selector ?? BackendSelector(client: api)
    }

    /// A router for the app session: direct API with a plain CLI client at `cliPath` as fallback.
    public convenience init(cliPath: String) {
        self.init(cli: ContainerClient(cliPath: cliPath))
    }

    /// For the Settings, Platform line.
    public func status() async -> BackendStatus {
        await selector.status()
    }

    // MARK: Routing

    func route<T: Sendable>(
        _ family: OperationFamily,
        changes: Bool = false,
        direct: @Sendable (DirectAPIClient) async throws -> T,
        cli fallback: @Sendable (ContainerClient) async throws -> T
    ) async throws -> T {
        switch await selector.decision(for: family) {
        case .cli:
            return try await fallback(cli)
        case .serviceStopped:
            throw APIError.serviceUnavailable(route: family.rawValue)
        case .direct:
            break
        }
        do {
            let value = try await direct(api)
            await selector.recordSuccess(family)
            return value
        } catch let error as APIError {
            switch error {
            case .needsCLI:
                return try await fallback(cli)
            case .serviceUnavailable:
                if await selector.confirmServiceStopped() { throw error }
                // The connection was stale but the daemon is up: use the CLI this time.
                await selector.recordFailure(family)
                return try await fallback(cli)
            case .server where !error.isRequestRejected:
                // A real answer from the daemon. The API works.
                await selector.recordSuccess(family)
                throw DeckError.commandFailed(error.errorDescription ?? "The container services reported an error.")
            default:
                if case .interrupted = error { await selector.connectionChanged() }
                await selector.recordFailure(family)
                if changes && !error.requestNotApplied { throw error }
                return try await fallback(cli)
            }
        }
    }

    // MARK: Containers

    public func listContainers(all: Bool = true) async throws -> [ContainerSummary] {
        try await route(.containerList, direct: { try await $0.listContainers(all: all) }, cli: { try await $0.listContainers(all: all) })
    }

    public func inspectContainer(_ id: String) async throws -> ContainerDetail {
        try await route(.containerList, direct: { try await $0.inspectContainer(id) }, cli: { try await $0.inspectContainer(id) })
    }

    public func inspectContainers(_ ids: [String]) async throws -> [ContainerDetail] {
        try await route(.containerList, direct: { try await $0.inspectContainers(ids) }, cli: { try await $0.inspectContainers(ids) })
    }

    public func startContainer(_ id: String) async throws {
        try await route(.containerLifecycle, changes: true, direct: { try await $0.startContainer(id) }, cli: { try await $0.startContainer(id) })
    }

    public func stopContainer(_ id: String) async throws {
        try await route(.containerLifecycle, changes: true, direct: { try await $0.stopContainer(id) }, cli: { try await $0.stopContainer(id) })
    }

    public func killContainer(_ id: String) async throws {
        try await route(.containerLifecycle, changes: true, direct: { try await $0.killContainer(id) }, cli: { try await $0.killContainer(id) })
    }

    public func restartContainer(_ id: String) async throws {
        try await stopContainer(id)
        try await startContainer(id)
    }

    public func deleteContainer(_ id: String, force: Bool = false) async throws {
        try await route(.containerLifecycle, changes: true, direct: { try await $0.deleteContainer(id, force: force) }, cli: { try await $0.deleteContainer(id, force: force) })
    }

    /// Always the CLI. `container run` resolves the image (and pulls it), builds the
    /// full configuration, creates anonymous volumes and picks the kernel on the
    /// client side. Doing that over XPC means copying a lot of Apple's client code.
    public func runContainer(_ options: RunOptions) async throws -> String {
        try await cli.runContainer(options)
    }

    public func stats(_ ids: [String] = []) async throws -> [ContainerStats] {
        try await route(.stats, direct: { try await $0.stats(ids) }, cli: { try await $0.stats(ids) })
    }

    /// Direct when possible. If the direct stream fails before its first line, the
    /// CLI stream takes over. After lines were shown, the error is passed on.
    public func logs(_ id: String, options: LogOptions = LogOptions()) -> AsyncThrowingStream<String, Error> {
        let cli = self.cli
        let api = self.api
        let selector = self.selector
        return AsyncThrowingStream { continuation in
            let task = Task {
                var gotLine = false
                do {
                    switch await selector.decision(for: .logs) {
                    case .serviceStopped:
                        throw APIError.serviceUnavailable(route: APIRoute.containerLogs)
                    case .cli:
                        for try await line in cli.logs(id, options: options) { continuation.yield(line) }
                    case .direct:
                        do {
                            for try await line in api.logs(id, options: options) {
                                if !gotLine { gotLine = true; await selector.recordSuccess(.logs) }
                                continuation.yield(line)
                            }
                            if !gotLine { await selector.recordSuccess(.logs) }
                        } catch let error as APIError where !gotLine && Self.useCLIForLogs(after: error) {
                            if error.isTransportFailure { await selector.recordFailure(.logs) }
                            for try await line in cli.logs(id, options: options) { continuation.yield(line) }
                        }
                    }
                    continuation.finish()
                } catch let error as APIError {
                    if case .server = error, !error.isRequestRejected {
                        continuation.finish(throwing: DeckError.commandFailed(error.errorDescription ?? ""))
                    } else {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func useCLIForLogs(after error: APIError) -> Bool {
        if case .needsCLI = error { return true }
        return error.isTransportFailure
    }

    // MARK: Images

    public func listImages() async throws -> [ImageSummary] {
        try await route(.images, direct: { try await $0.listImages() }, cli: { try await $0.listImages() })
    }

    public func inspectImage(_ reference: String) async throws -> ImageDetail {
        try await route(.images, direct: { try await $0.inspectImage(reference) }, cli: { try await $0.inspectImage(reference) })
    }

    public func tagImage(_ source: String, as target: String) async throws {
        try await route(.images, changes: true, direct: { try await $0.tagImage(source, as: target) }, cli: { try await $0.tagImage(source, as: target) })
    }

    public func deleteImage(_ reference: String) async throws {
        try await route(.images, changes: true, direct: { try await $0.deleteImage(reference) }, cli: { try await $0.deleteImage(reference) })
    }

    // MARK: Volumes

    public func listVolumes() async throws -> [VolumeSummary] {
        try await route(.volumes, direct: { try await $0.listVolumes() }, cli: { try await $0.listVolumes() })
    }

    public func listVolumeSummaries() async throws -> [VolumeSummary] {
        try await route(.volumes, direct: { try await $0.listVolumeSummaries() }, cli: { try await $0.listVolumeSummaries() })
    }

    public func createVolume(name: String, size: String? = nil, labels: [String: String] = [:]) async throws {
        try await route(.volumes, changes: true, direct: { try await $0.createVolume(name: name, size: size, labels: labels) },
                        cli: { try await $0.createVolume(name: name, size: size, labels: labels) })
    }

    public func deleteVolume(_ name: String) async throws {
        try await route(.volumes, changes: true, direct: { try await $0.deleteVolume(name) }, cli: { try await $0.deleteVolume(name) })
    }

    // MARK: Networks

    public func listNetworks() async throws -> [NetworkSummary] {
        try await route(.networks, direct: { try await $0.listNetworks() }, cli: { try await $0.listNetworks() })
    }

    public func listNetworkSummaries() async throws -> [NetworkSummary] {
        try await route(.networks, direct: { try await $0.listNetworkSummaries() }, cli: { try await $0.listNetworkSummaries() })
    }

    public func createNetwork(name: String, subnet: String? = nil, internal isInternal: Bool = false) async throws {
        try await createNetwork(name: name, subnet: subnet, subnetV6: nil, internal: isInternal, labels: [:])
    }

    public func createNetwork(name: String, subnet: String?, subnetV6: String?, internal isInternal: Bool, labels: [String: String]) async throws {
        try await route(.networks, changes: true,
                        direct: { try await $0.createNetwork(name: name, subnet: subnet, subnetV6: subnetV6, internal: isInternal, labels: labels) },
                        cli: { try await $0.createNetwork(name: name, subnet: subnet, subnetV6: subnetV6, internal: isInternal, labels: labels) })
    }

    public func deleteNetwork(_ name: String) async throws {
        try await route(.networks, changes: true, direct: { try await $0.deleteNetwork(name) }, cli: { try await $0.deleteNetwork(name) })
    }

    // MARK: System

    public func diskUsage() async throws -> DiskUsage {
        try await route(.system, direct: { try await $0.diskUsage() }, cli: { try await $0.diskUsage() })
    }

    // MARK: Cluster nodes

    /// Every cluster node, running or not. Direct when possible, else the CLI path for the
    /// installed release (`ContainerClient.listClusterNodes`).
    public func listClusterNodes() async throws -> [ContainerSummary] {
        try await route(.containerList, direct: { try await $0.listClusterNodes() }, cli: { try await $0.listClusterNodes() })
    }

    /// Starts, stops, kills or deletes a cluster node straight through the daemon.
    ///
    /// From container 1.7 the CLI answers "not found" for cluster nodes, and the cluster
    /// plugin has no start or stop command, so no command can do this. The daemon itself
    /// still accepts it (the check is in the CLI). So this goes direct even when the
    /// Command line only switch is on or the version is newer than tested. It needs the
    /// services running, and says plainly what failed otherwise.
    public func clusterNode(_ action: ClusterNodeAction, _ id: String, features: ContainerPlatformFeatures) async throws {
        do {
            _ = try await api.ping()
        } catch let error as APIError {
            if case .serviceUnavailable = error { throw error }
            throw features.explainFailure(
                "Could not \(action.verb) cluster node \(id). \(features.releaseName) only does this through its service, and the service did not answer.",
                details: error.localizedDescription)
        }
        do {
            switch action {
            case .start: try await api.startContainer(id)
            case .stop: try await api.stopContainer(id)
            case .kill: try await api.killContainer(id)
            case .delete(let force): try await api.deleteContainer(id, force: force)
            }
            await selector.recordSuccess(.containerLifecycle)
        } catch let error as APIError {
            switch error {
            case .serviceUnavailable:
                throw error
            case .needsCLI(let why):
                throw DeckError.commandFailed(why)
            case .server where !error.isRequestRejected:
                throw DeckError.commandFailed(error.errorDescription ?? "The container services reported an error.")
            default:
                throw features.explainFailure(
                    "Could not \(action.verb) cluster node \(id) through the container service.",
                    details: error.localizedDescription)
            }
        }
    }

    /// True when the daemon answers a ping. Falls back to `container system status`
    /// when the support switch is on.
    public func isServiceRunning() async throws -> Bool {
        if selector.forcesCLI { return try await cli.cli.isServiceRunning() }
        do {
            return try await api.isServiceRunning()
        } catch {
            return try await cli.cli.isServiceRunning()
        }
    }

}

// MARK: - Wiring into ContainerClient

public extension ContainerClient {
    /// The same client with `router` set, so the calls marked "Direct" use the direct API.
    func routed(through router: ContainerBackendRouter) -> ContainerClient {
        var client = self
        client.router = router
        return client
    }

    /// True when the container services answer. Asks the daemon directly when a
    /// router is set (no process), else `container system status`.
    func isServiceRunning() async throws -> Bool {
        if let router { return try await router.isServiceRunning() }
        return try await cli.isServiceRunning()
    }

    /// Which backend calls use right now. nil for a pure CLI client.
    func backendStatus() async -> BackendStatus? {
        await router?.status()
    }
}

/// What `ContainerBackendRouter.clusterNode` does to a node.
public enum ClusterNodeAction: Sendable, Equatable {
    case start, stop, kill
    case delete(force: Bool)

    var verb: String {
        switch self {
        case .start: return "start"
        case .stop: return "stop"
        case .kill: return "kill"
        case .delete: return "delete"
        }
    }
}
