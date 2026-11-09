import Foundation

/// Talks to Apple's container daemons over XPC, the same messages the `container`
/// CLI sends, and returns our models. Each method mirrors what the matching CLI
/// command does on the client side (filters, checks, follow up calls), so results
/// match `ContainerClient`. Use it through `ContainerBackendRouter`, which falls back
/// to the CLI when a call fails.
///
/// Throws `APIError`. `.needsCLI` means "let the CLI handle this one" (for example an
/// image name we cannot resolve), so the CLI shows its usual message.
public final class DirectAPIClient: Sendable {
    public let apiServer: any XPCTransport
    public let imageService: any XPCTransport
    let settings: DirectAPISettings
    let statsCache: CPUSampleCache
    let content = APIContentCache()
    /// Version from the last ping. Picks the list filter, which changed in 1.7.
    let daemonVersion = APIVersionBox()

    public init(
        apiServer: any XPCTransport = XPCConnection.shared(APIService.apiServer),
        imageService: any XPCTransport = XPCConnection.shared(APIService.images),
        settings: DirectAPISettings = .live,
        statsCache: CPUSampleCache = .shared
    ) {
        self.apiServer = apiServer
        self.imageService = imageService
        self.settings = settings
        self.statsCache = statsCache
    }

    // MARK: System

    /// `ping`: daemon version and paths. Fails with `.serviceUnavailable` when the
    /// services are not running.
    public func ping(timeout: Duration = APITimeouts.ping) async throws -> APIHealth {
        let reply = try await apiServer.call(XPCRequest(route: APIRoute.ping), timeout: timeout)
        let health = try APIDecode.health(reply)
        daemonVersion.set(SemanticVersion.firstMatch(in: health.version))
        return health
    }

    /// What the daemon's release does differently. Pings once when no version is known yet.
    func features() async -> ContainerPlatformFeatures {
        if let known = daemonVersion.get() { return ContainerPlatformFeatures(version: known) }
        _ = try? await ping()
        return ContainerPlatformFeatures(version: daemonVersion.get())
    }

    /// The filter `container list [--all]` sends in the daemon's release.
    func cliListFilters(all: Bool) async -> APIListFilters {
        .cliList(all: all, features: await features())
    }

    public func isServiceRunning() async throws -> Bool {
        do {
            _ = try await ping()
            return true
        } catch APIError.serviceUnavailable {
            return false
        }
    }

    /// `container system df`.
    public func diskUsage() async throws -> DiskUsage {
        let reply = try await apiServer.call(XPCRequest(route: APIRoute.systemDiskUsage), timeout: .seconds(60))
        return try APIDecode.diskUsage(reply.data(APIKey.diskUsageStats))
    }

    // MARK: Containers

    func snapshots(_ filters: APIListFilters) async throws -> Data? {
        var request = XPCRequest(route: APIRoute.containerList)
        try request.set(APIKey.listFilters, json: filters)
        let reply = try await apiServer.call(request, timeout: .seconds(10))
        return reply.data(APIKey.containers)
    }

    /// `container list [--all]`: machines are left out, like the CLI, and from 1.7 on cluster
    /// nodes too, so this matches the CLI of the same release.
    public func listContainers(all: Bool = true) async throws -> [ContainerSummary] {
        try APIDecode.containers(try await snapshots(await cliListFilters(all: all)))
    }

    /// Every cluster node (label `com.apple.container.plugin=cluster`), running or not.
    /// Works on every supported release. From 1.7 on, `container list` no longer shows them.
    public func listClusterNodes() async throws -> [ContainerSummary] {
        try APIDecode.containers(try await snapshots(.clusterNodes))
    }

    /// `container inspect <id>`.
    public func inspectContainer(_ id: String) async throws -> ContainerDetail {
        let details = try await inspectContainers([id])
        guard let detail = details.first(where: { $0.summary.id == id }) ?? details.first else {
            throw APIError.needsCLI("Container \(id) was not found.")
        }
        return detail
    }

    /// `container inspect <ids>`. A missing id goes to the CLI for its message.
    public func inspectContainers(_ ids: [String]) async throws -> [ContainerDetail] {
        guard !ids.isEmpty else { return [] }
        let details = try APIDecode.containerDetails(try await snapshots(APIListFilters(ids: ids)))
        let found = Set(details.map(\.summary.id))
        guard Set(ids).isSubset(of: found) else {
            throw APIError.needsCLI("Container not found: \(Set(ids).subtracting(found).sorted().joined(separator: ", "))")
        }
        return details
    }

    /// `container start <id>` (detached): bootstrap the VM, then start the init process.
    public func startContainer(_ id: String) async throws {
        guard let detail = try APIDecode.containerDetails(try await snapshots(APIListFilters(ids: [id]))).first(where: { $0.summary.id == id }) else {
            throw APIError.needsCLI("Container \(id) was not found.")
        }
        if detail.summary.state == .running { return }
        // The CLI refuses when a shared folder is gone. Let it say so.
        for mount in detail.mounts where mount.type == "bind" && !mount.source.isEmpty {
            if !settings.fileExists(mount.source) {
                throw APIError.needsCLI("mount source path '\(mount.source)' does not exist")
            }
        }

        var bootstrap = XPCRequest(route: APIRoute.containerBootstrap)
        bootstrap.set(APIKey.id, id)
        var dynamicEnv: [String: String] = [:]
        if let socket = settings.sshAuthSocket() { dynamicEnv["SSH_AUTH_SOCK"] = socket }
        try bootstrap.set(APIKey.dynamicEnv, json: dynamicEnv)

        var start = XPCRequest(route: APIRoute.containerStartProcess)
        start.set(APIKey.id, id)
        start.set(APIKey.processIdentifier, id)

        do {
            _ = try await apiServer.call(bootstrap, timeout: APITimeouts.start)
            _ = try await apiServer.call(start, timeout: APITimeouts.start)
        } catch {
            // Same clean up as `container start`: leave it stopped, not half started.
            try? await stopContainer(id)
            throw error
        }
    }

    /// `container stop [--time t] [--signal s] <id>`.
    public func stopContainer(_ id: String, timeoutSeconds: Int32 = 5, signal: String? = nil) async throws {
        var request = XPCRequest(route: APIRoute.containerStop)
        request.set(APIKey.id, id)
        try request.set(APIKey.stopOptions, json: APIStopOptions(timeoutInSeconds: timeoutSeconds, signal: signal))
        _ = try await apiServer.call(request, timeout: .seconds(Int64(max(timeoutSeconds, 0))) + APITimeouts.stopMargin)
    }

    /// `container kill [--signal s] <id>`. Default KILL like the CLI.
    public func killContainer(_ id: String, signal: String = "KILL") async throws {
        var request = XPCRequest(route: APIRoute.containerKill)
        request.set(APIKey.id, id)
        request.set(APIKey.processIdentifier, id)
        request.set(APIKey.signal, signal)
        _ = try await apiServer.call(request)
    }

    /// `container delete [--force] <id>`.
    public func deleteContainer(_ id: String, force: Bool = false) async throws {
        var request = XPCRequest(route: APIRoute.containerDelete)
        request.set(APIKey.id, id)
        request.set(APIKey.forceDelete, force)
        _ = try await apiServer.call(request, timeout: APITimeouts.delete)
    }

    /// One stats sample per running container. Empty ids means all running ones.
    /// Like `container stats --no-stream`, containers that fail are skipped.
    /// CPU percent comes from the previous sample (`CPUSampleCache`), as on the CLI path.
    public func stats(_ ids: [String] = []) async throws -> [ContainerStats] {
        let filters = ids.isEmpty ? APIListFilters(status: "running") : APIListFilters(ids: ids)
        let containers = try APIDecode.containers(try await snapshots(filters))
        if !ids.isEmpty {
            let found = Set(containers.map(\.id))
            if let missing = ids.first(where: { !found.contains($0) }) {
                throw APIError.needsCLI("no such container: \(missing)")
            }
        }
        let running = containers.filter(\.isRunning).map(\.id)
        guard !running.isEmpty else { return [] }

        let server = apiServer
        let results = await withTaskGroup(of: (Int, Result<Data?, Error>).self) { group in
            for (index, id) in running.enumerated() {
                group.addTask {
                    var request = XPCRequest(route: APIRoute.containerStats)
                    request.set(APIKey.id, id)
                    do {
                        return (index, .success(try await server.call(request).data(APIKey.statistics)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<Data?, Error>)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        let now = Date()
        var stats: [ContainerStats] = []
        var firstError: Error?
        for result in results {
            switch result {
            case .success(let data):
                if let item = try? APIDecode.stats(data, cache: statsCache, now: now) { stats += item }
            case .failure(let error):
                if firstError == nil { firstError = error }
            }
        }
        // Every call failed the same way: that is the API, not one container.
        if stats.isEmpty, let firstError {
            if firstError is CancellationError { throw firstError }
            if let apiError = firstError as? APIError {
                if apiError.isTransportFailure { throw apiError }
                if case .serviceUnavailable = apiError { throw apiError }
            }
        }
        return stats
    }

    /// `container logs [-n N] [--follow] [--boot] <id>`. The daemon hands over the
    /// log files themselves. We read the tail and then watch the file for new lines.
    public func logs(_ id: String, options: LogOptions = LogOptions()) -> AsyncThrowingStream<String, Error> {
        let server = apiServer
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let file = try await Self.logFile(server, id: id, boot: options.boot)
                    try await APILogReader.read(file, tail: options.tail, follow: options.follow) { line in
                        continuation.yield(CLIText.strippingANSI(line))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The stdio log (or boot log) file of a container.
    static func logFile(_ server: any XPCTransport, id: String, boot: Bool) async throws -> OwnedFileDescriptor {
        var request = XPCRequest(route: APIRoute.containerLogs)
        request.set(APIKey.id, id)
        let reply = try await server.call(request)
        guard let files = reply.fileDescriptors(APIKey.logs), files.count >= 2 else {
            throw APIError.malformedReply("containerLogs \(APIKey.logs)")
        }
        return boot ? files[1] : files[0]
    }

    // MARK: Volumes

    /// `container volume list`. `usedBy` stays empty.
    public func listVolumeSummaries() async throws -> [VolumeSummary] {
        let reply = try await apiServer.call(XPCRequest(route: APIRoute.volumeList))
        return try APIDecode.volumes(reply.data(APIKey.volumes))
    }

    /// Volumes with `usedBy` from the containers that mount them (best effort, one list call).
    public func listVolumes() async throws -> [VolumeSummary] {
        var volumes = try await listVolumeSummaries()
        guard !volumes.isEmpty, let details = try? APIDecode.containerDetails(try await snapshots(await cliListFilters(all: true))) else {
            return volumes
        }
        let users = ContainerOutputParser.volumeUsers(details)
        for index in volumes.indices {
            volumes[index].usedBy = users[volumes[index].name] ?? []
        }
        return volumes
    }

    /// `container volume create [-s size] [--label k=v] <name>`.
    public func createVolume(name: String, size: String? = nil, labels: [String: String] = [:]) async throws {
        var request = XPCRequest(route: APIRoute.volumeCreate)
        request.set(APIKey.volumeName, name)
        request.set(APIKey.volumeDriver, "local")
        var options: [String: String] = [:]
        if let size = CLIText.nonEmpty(size) { options["size"] = size }
        try request.set(APIKey.volumeDriverOpts, json: options)
        try request.set(APIKey.volumeLabels, json: labels.filter { !$0.key.isEmpty })
        _ = try await apiServer.call(request, timeout: APITimeouts.create)
    }

    public func deleteVolume(_ name: String) async throws {
        var request = XPCRequest(route: APIRoute.volumeDelete)
        request.set(APIKey.volumeName, name)
        _ = try await apiServer.call(request, timeout: APITimeouts.delete)
    }

    // MARK: Networks

    /// `container network list`. `attachedContainers` stays empty.
    public func listNetworkSummaries() async throws -> [NetworkSummary] {
        let reply = try await apiServer.call(XPCRequest(route: APIRoute.networkList))
        return try APIDecode.networks(reply.data(APIKey.networkResources))
    }

    /// Networks with `attachedContainers` (stopped containers count, as on the CLI path).
    public func listNetworks() async throws -> [NetworkSummary] {
        var networks = try await listNetworkSummaries()
        guard !networks.isEmpty, let details = try? APIDecode.containerDetails(try await snapshots(await cliListFilters(all: true))), !details.isEmpty else {
            return networks
        }
        let users = ContainerOutputParser.networkUsers(details)
        for index in networks.indices {
            networks[index].attachedContainers = users[networks[index].name] ?? []
        }
        return networks
    }

    /// `container network create [--subnet] [--subnet-v6] [--internal] [--label] <name>`.
    public func createNetwork(name: String, subnet: String? = nil, subnetV6: String? = nil, internal isInternal: Bool = false, labels: [String: String] = [:]) async throws {
        let config = APINetworkConfiguration(name: name, subnet: subnet, subnetV6: subnetV6, internal: isInternal, labels: labels)
        var request = XPCRequest(route: APIRoute.networkCreate)
        request.set(APIKey.networkId, name)
        try request.set(APIKey.networkConfig, json: config)
        _ = try await apiServer.call(request, timeout: APITimeouts.create)
    }

    /// `container network delete <name>`. Builtin or unknown names go to the CLI for its message.
    public func deleteNetwork(_ name: String) async throws {
        let networks = try await listNetworkSummaries()
        guard let network = networks.first(where: { $0.name == name }), !network.isBuiltin else {
            throw APIError.needsCLI("Network \(name) cannot be deleted here.")
        }
        var request = XPCRequest(route: APIRoute.networkDelete)
        request.set(APIKey.networkId, name)
        _ = try await apiServer.call(request, timeout: APITimeouts.delete)
    }
}

// MARK: - Settings

/// Things the direct client reads from the Mac. Swapped in tests.
public struct DirectAPISettings: Sendable {
    /// `registry.domain` from the config file, "docker.io" when not set.
    public var registryDomain: @Sendable () -> String
    /// `build.image` and `vminit.image` when the config file sets them.
    public var configuredInfraImages: @Sendable () -> [String]
    public var sshAuthSocket: @Sendable () -> String?
    public var fileExists: @Sendable (String) -> Bool

    public init(
        registryDomain: @escaping @Sendable () -> String,
        configuredInfraImages: @escaping @Sendable () -> [String],
        sshAuthSocket: @escaping @Sendable () -> String?,
        fileExists: @escaping @Sendable (String) -> Bool
    ) {
        self.registryDomain = registryDomain
        self.configuredInfraImages = configuredInfraImages
        self.sshAuthSocket = sshAuthSocket
        self.fileExists = fileExists
    }

    public static let live = DirectAPISettings(
        registryDomain: { CLIText.nonEmpty(SystemConfigFile.value("registry.domain")) ?? "docker.io" },
        configuredInfraImages: { ["build.image", "vminit.image"].compactMap { CLIText.nonEmpty(SystemConfigFile.value($0)) } },
        sshAuthSocket: { CLIText.nonEmpty(ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]) },
        fileExists: { FileManager.default.fileExists(atPath: $0) }
    )

    /// Repositories of the builder and init images the CLI hides from `image list`.
    public static let infraRepositories = [
        "ghcr.io/apple/container-builder-shim/builder:",
        "ghcr.io/apple/containerization/vminit:"
    ]

    /// The CLI hides the exact builder and init images it is configured with. The
    /// default tags are built into the CLI, so we hide every tag of those repositories.
    func isInfraImage(_ reference: String) -> Bool {
        if configuredInfraImages().contains(reference) { return true }
        if reference == "vminit:latest" { return true }
        return Self.infraRepositories.contains { reference.hasPrefix($0) }
    }
}

/// The daemon version seen in the last ping, shared across tasks.
final class APIVersionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SemanticVersion?

    func get() -> SemanticVersion? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ version: SemanticVersion?) {
        lock.lock(); defer { lock.unlock() }
        value = version
    }
}
