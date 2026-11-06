import Foundation

// The app's single entry point to Apple's container platform. UI code calls these
// methods, so keep existing signatures stable and add new methods as needed.
// Results are mapped into the models in ResourceModels.swift, from the direct API
// (see API/README.md) or from `container --format json` output.

/// One place to talk to Apple's `container` platform.
public struct ContainerClient: Sendable {
    public let cli: ContainerCLI
    public let runner: any CommandRunning
    public let streamer: any CommandStreaming
    /// When set, the calls marked "Direct" in `DeckCore/API/README.md` go through the
    /// router (direct API with CLI fallback). The router keeps its own plain client for
    /// the CLI path, so nothing loops. nil means a pure CLI client (tests, MockRunner).
    public var router: ContainerBackendRouter?

    public init(cliPath: String, runner: any CommandRunning = ProcessRunner(), streamer: any CommandStreaming = ProcessRunner()) {
        self.cli = ContainerCLI(path: cliPath, runner: runner)
        self.runner = runner
        self.streamer = streamer
    }

    public var cliPath: String { cli.path }

    /// Runs a command and fails on a non zero exit.
    @discardableResult
    public func run(_ arguments: [String]) async throws -> CommandResult {
        try await runner.run(cli.path, arguments).orThrow()
    }

    /// Runs a command with text on stdin (passwords).
    @discardableResult
    public func run(_ arguments: [String], stdin: String) async throws -> CommandResult {
        try await runner.run(cli.path, arguments, stdin: Data(stdin.utf8)).orThrow()
    }

    /// Streams output lines of a long command.
    public func stream(_ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        streamer.stream(cli.path, arguments)
    }

    /// The exact shell command for a set of arguments, shown in the UI as
    /// "the CLI command for this action".
    public func commandLine(_ arguments: [String]) -> String {
        (["container"] + arguments).map { arg in
            arg.contains(" ") || arg.isEmpty ? "'\(arg)'" : arg
        }.joined(separator: " ")
    }
}

// MARK: - Containers

public extension ContainerClient {
    func listContainers(all: Bool = true) async throws -> [ContainerSummary] {
        if let router { return try await router.listContainers(all: all) }
        var args = ["list", "--format", "json"]
        if all { args.insert("--all", at: 1) }
        let result = try await run(args)
        return try ContainerOutputParser.containers(result.stdout)
    }

    func inspectContainer(_ id: String) async throws -> ContainerDetail {
        if let router { return try await router.inspectContainer(id) }
        let result = try await run(["inspect", id])
        let details = try ContainerOutputParser.containerDetails(result.stdout)
        guard let detail = details.first(where: { $0.summary.id == id }) ?? details.first else {
            throw DeckError.commandFailed("Container \(id) was not found.")
        }
        return detail
    }

    func startContainer(_ id: String) async throws {
        if let router { return try await router.startContainer(id) }
        try await run(["start", id])
    }

    func stopContainer(_ id: String) async throws {
        if let router { return try await router.stopContainer(id) }
        try await run(["stop", id])
    }

    func killContainer(_ id: String) async throws {
        if let router { return try await router.killContainer(id) }
        try await run(["kill", id])
    }

    func restartContainer(_ id: String) async throws {
        if let router { return try await router.restartContainer(id) }
        try await stopContainer(id)
        try await startContainer(id)
    }

    func deleteContainer(_ id: String, force: Bool = false) async throws {
        if let router { return try await router.deleteContainer(id, force: force) }
        try await run(force ? ["delete", "--force", id] : ["delete", id])
    }

    /// Removes all stopped containers.
    func pruneContainers() async throws {
        try await run(["prune"])
    }

    /// `container run` arguments for these options (without the leading "container").
    func runArguments(_ options: RunOptions) -> [String] {
        var args = ["run"]
        if options.detach { args.append("--detach") }
        if options.autoRemove { args.append("--rm") }
        if let name = CLIText.nonEmpty(options.name) { args += ["--name", name] }
        for env in options.env {
            let key = env.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            args += ["--env", "\(key)=\(env.value)"]
        }
        for port in options.ports {
            args += ["--publish", port.publishArgument]
        }
        for mount in options.mounts {
            args += Self.mountArguments(mount)
        }
        if let cpus = options.cpus, cpus > 0 { args += ["--cpus", String(cpus)] }
        if let memory = CLIText.nonEmpty(options.memory) { args += ["--memory", memory] }
        if let mac = CLIText.nonEmpty(options.macAddress) {
            args += ["--network", "\(CLIText.nonEmpty(options.network) ?? "default"),mac=\(mac)"]
        } else if let network = CLIText.nonEmpty(options.network) {
            args += ["--network", network]
        }
        for network in options.extraNetworks {
            if let value = CLIText.nonEmpty(network) { args += ["--network", value] }
        }
        if let workdir = CLIText.nonEmpty(options.workingDir) { args += ["--workdir", workdir] }
        for (key, value) in options.labels.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
            args += ["--label", "\(key)=\(value)"]
        }
        if let entrypoint = CLIText.nonEmpty(options.entrypoint) { args += ["--entrypoint", entrypoint] }
        if let platform = CLIText.nonEmpty(options.platform) { args += ["--platform", platform] }
        args += Self.extraRunArguments(options)
        args.append(options.image.trimmingCharacters(in: .whitespaces))
        args += options.command
        return args
    }

    /// Runs a new container. Returns its id.
    @discardableResult
    func runContainer(_ options: RunOptions) async throws -> String {
        let result = try await run(runArguments(options))
        if let id = ContainerOutputParser.runOutputID(result.stdout) {
            return id
        }
        return CLIText.nonEmpty(options.name) ?? ""
    }

    /// Streams log lines (color codes removed). Cancel the task to stop following.
    func logs(_ id: String, options: LogOptions = LogOptions()) -> AsyncThrowingStream<String, Error> {
        if let router { return router.logs(id, options: options) }
        return Self.cleanLines(stream(logArguments(id, options: options)), keepBlank: true)
    }

    /// One snapshot of stats for running containers. Empty ids means all running.
    func stats(_ ids: [String] = []) async throws -> [ContainerStats] {
        if let router { return try await router.stats(ids) }
        let result = try await run(["stats", "--no-stream", "--format", "json"] + ids)
        return try ContainerOutputParser.stats(result.stdout, cache: CPUSampleCache.shared)
    }

    /// Saves the container's root filesystem as a tar file.
    func exportContainer(_ id: String, to file: URL) async throws {
        try await run(["export", "--output", file.path, id])
    }

    /// Runs a command inside a running container and returns its output.
    /// Does not throw when the command exits non zero. Check `succeeded`.
    func exec(_ id: String, _ command: [String]) async throws -> CommandResult {
        try await runner.run(cli.path, ["exec", id] + command)
    }

    /// Shell command a terminal app runs to open a shell in the container.
    /// Every part is quoted for `sh`, so odd paths and names stay one word.
    func shellCommand(_ id: String, shell: String = "/bin/sh") -> String {
        ([cli.path] + shellArguments(id, shell: shell)).map(CLIText.shellQuoted).joined(separator: " ")
    }

    /// `container exec -it <id> <shell>` arguments, for CommandHint.
    func shellArguments(_ id: String, shell: String = "/bin/sh") -> [String] {
        ["exec", "-it", id, shell]
    }
}

// MARK: - Files inside a container

public extension ContainerClient {
    func listFiles(_ id: String, path: String) async throws -> [FileEntry] {
        let folder = path.isEmpty ? "/" : path
        let result = try await runner.run(cli.path, ["exec", id, "sh", "-c", ContainerOutputParser.listFilesScript, "sh", folder])
        if result.exitCode == 2 {
            throw DeckError.commandFailed("Could not open \(folder) in \(id).")
        }
        try result.orThrow()
        return ContainerOutputParser.fileEntries(result.stdout, in: folder)
    }

    /// Copies a file or folder from the container to the Mac.
    /// Like `cp`, an existing folder as destination receives the item inside it.
    func copyFromContainer(_ id: String, path: String, to destination: URL) async throws {
        // `container copy` splits on ":", so such paths go through tar instead.
        if !path.contains(":"), !destination.path.contains(":") {
            let result = try await runner.run(cli.path, ["copy", "\(id):\(path)", destination.path])
            if result.succeeded { return }
            guard Self.isMissingCommand(result) else { throw DeckError.commandFailed(result.failureMessage) }
        }
        try await copyOutWithTar(id, path: path, to: destination)
    }

    /// Copies a file or folder from the Mac into the container.
    /// Like `cp`, an existing folder as `path` receives the item inside it.
    func copyToContainer(_ id: String, from source: URL, path: String) async throws {
        if !path.contains(":"), !source.path.contains(":") {
            let result = try await runner.run(cli.path, ["copy", source.path, "\(id):\(path)"])
            if result.succeeded { return }
            guard Self.isMissingCommand(result) else { throw DeckError.commandFailed(result.failureMessage) }
        }
        try await copyInWithTar(id, from: source, path: path)
    }

    func deleteFile(_ id: String, path: String) async throws {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "/", trimmed.hasPrefix("/") else {
            throw DeckError.commandFailed("Refusing to delete \(path.isEmpty ? "an empty path" : path).")
        }
        try await runner.run(cli.path, ["exec", id, "rm", "-rf", "--", trimmed]).orThrow()
    }
}

// MARK: - Images

public extension ContainerClient {
    func listImages() async throws -> [ImageSummary] {
        if let router { return try await router.listImages() }
        let result = try await run(["image", "list", "--format", "json"])
        return try ContainerOutputParser.images(result.stdout)
    }

    func inspectImage(_ reference: String) async throws -> ImageDetail {
        if let router { return try await router.inspectImage(reference) }
        let result = try await run(["image", "inspect", reference])
        return try ContainerOutputParser.imageDetail(result.stdout, preferredArchitecture: Self.hostArchitecture)
    }

    /// Streams pull progress lines.
    func pullImage(_ reference: String, platform: String? = nil) -> AsyncThrowingStream<String, Error> {
        Self.cleanLines(stream(pullArguments(reference, platform: platform)))
    }

    func tagImage(_ source: String, as target: String) async throws {
        if let router { return try await router.tagImage(source, as: target) }
        try await run(["image", "tag", source, target])
    }

    func deleteImage(_ reference: String) async throws {
        if let router { return try await router.deleteImage(reference) }
        try await run(["image", "delete", reference])
    }

    /// Removes unused images. `all` also removes untagged and unreferenced ones.
    func pruneImages(all: Bool = false) async throws {
        try await run(all ? ["image", "prune", "--all"] : ["image", "prune"])
    }

    /// Loads an OCI tar archive into the image store.
    func loadImage(from file: URL) async throws {
        try await run(["image", "load", "--input", file.path])
    }

    /// Saves an image as an OCI tar. Images pulled for this Mac only (the app's default)
    /// lack the other platforms' layers, and a plain `image save` then fails with
    /// "content with digest …". In that case it saves this Mac's platform instead.
    func saveImage(_ reference: String, to file: URL, platform: String? = nil) async throws {
        try await run(saveImageArguments(reference, to: file, platform: platform))
    }

    func saveImage(_ reference: String, to file: URL) async throws {
        do {
            try await run(saveImageArguments(reference, to: file, platform: nil))
        } catch where Self.isMissingPlatformContent(error) {
            try? FileManager.default.removeItem(at: file)
            try await run(saveImageArguments(reference, to: file, platform: ImagePlatform.host))
        }
    }

    func saveImageArguments(_ reference: String, to file: URL, platform: String?) -> [String] {
        var args = ["image", "save", "--output", file.path]
        if let platform { args += ["--platform", platform] }
        return args + [reference]
    }

    /// `image save` on an image whose other platforms were never pulled.
    static func isMissingPlatformContent(_ error: Error) -> Bool {
        let text = String(describing: error) + " " + error.localizedDescription
        return text.contains("content with digest")
    }

    /// Streams build output lines (BuildKit).
    func build(_ options: BuildOptions) -> AsyncThrowingStream<String, Error> {
        Self.cleanLines(stream(buildArguments(options)))
    }
}

// MARK: - Volumes

public extension ContainerClient {
    /// Volumes with `usedBy` filled from the containers that mount them (best effort).
    func listVolumes() async throws -> [VolumeSummary] {
        if let router { return try await router.listVolumes() }
        let result = try await run(["volume", "list", "--format", "json"])
        var volumes = try ContainerOutputParser.volumes(result.stdout)
        guard !volumes.isEmpty, let containers = try? await listContainers(all: true) else { return volumes }
        let users = await volumeUsers(containers)
        for index in volumes.indices {
            volumes[index].usedBy = users[volumes[index].name] ?? []
        }
        return volumes
    }

    /// Size like "10G". nil uses the platform default (512 GB sparse, it only takes what is written).
    func createVolume(name: String, size: String? = nil, labels: [String: String] = [:]) async throws {
        if let router { return try await router.createVolume(name: name, size: size, labels: labels) }
        try await run(volumeCreateArguments(name: name, size: size, labels: labels))
    }

    /// `container volume create` arguments, for CommandHint.
    func volumeCreateArguments(name: String, size: String? = nil, labels: [String: String] = [:]) -> [String] {
        var args = ["volume", "create"]
        if let size = CLIText.nonEmpty(size) { args += ["-s", size] }
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
            args += ["--label", "\(key)=\(value)"]
        }
        args.append(name)
        return args
    }

    /// Bytes the volume's disk image really takes on the Mac. The image is sparse,
    /// so this is usually far below `sizeBytes` (the most it can hold).
    static func allocatedBytes(atPath path: String?) -> UInt64? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return nil }
        if let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize, size >= 0 { return UInt64(size) }
        return nil
    }

    func deleteVolume(_ name: String) async throws {
        if let router { return try await router.deleteVolume(name) }
        try await run(["volume", "delete", name])
    }

    func pruneVolumes() async throws {
        try await run(["volume", "prune"])
    }
}

// MARK: - Networks

public extension ContainerClient {
    /// Networks with `attachedContainers` filled from the containers that use them (best effort).
    /// Stopped containers count too, because `network delete` refuses while any
    /// container (running or not) still refers to the network.
    func listNetworks() async throws -> [NetworkSummary] {
        if let router { return try await router.listNetworks() }
        let result = try await run(["network", "list", "--format", "json"])
        var networks = try ContainerOutputParser.networks(result.stdout)
        guard !networks.isEmpty, let containers = try? await listContainers(all: true), !containers.isEmpty else { return networks }
        if let details = try? await inspectContainers(containers.map(\.id)) {
            let users = ContainerOutputParser.networkUsers(details)
            for index in networks.indices {
                networks[index].attachedContainers = users[networks[index].name] ?? []
            }
        }
        return networks
    }

    func createNetwork(name: String, subnet: String? = nil, internal isInternal: Bool = false) async throws {
        if let router { return try await router.createNetwork(name: name, subnet: subnet, internal: isInternal) }
        try await run(networkCreateArguments(name: name, subnet: subnet, internal: isInternal))
    }

    /// Like `createNetwork(name:subnet:internal:)` with an IPv6 prefix and labels.
    func createNetwork(name: String, subnet: String?, subnetV6: String?, internal isInternal: Bool, labels: [String: String]) async throws {
        if let router { return try await router.createNetwork(name: name, subnet: subnet, subnetV6: subnetV6, internal: isInternal, labels: labels) }
        try await run(networkCreateArguments(name: name, subnet: subnet, subnetV6: subnetV6, internal: isInternal, labels: labels))
    }

    /// `container network create` arguments, for CommandHint.
    func networkCreateArguments(name: String, subnet: String? = nil, subnetV6: String? = nil, internal isInternal: Bool = false, labels: [String: String] = [:]) -> [String] {
        var args = ["network", "create"]
        if let subnet = CLIText.nonEmpty(subnet) { args += ["--subnet", subnet] }
        if let subnetV6 = CLIText.nonEmpty(subnetV6) { args += ["--subnet-v6", subnetV6] }
        if isInternal { args.append("--internal") }
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
            args += ["--label", "\(key)=\(value)"]
        }
        args.append(name)
        return args
    }

    func deleteNetwork(_ name: String) async throws {
        if let router { return try await router.deleteNetwork(name) }
        try await run(["network", "delete", name])
    }

    func pruneNetworks() async throws {
        try await run(["network", "prune"])
    }
}

// MARK: - System, DNS, registries

public extension ContainerClient {
    func diskUsage() async throws -> DiskUsage {
        if let router { return try await router.diskUsage() }
        let result = try await run(["system", "df", "--format", "json"])
        return try ContainerOutputParser.diskUsage(result.stdout)
    }

    /// Merged config the service uses (`system property list --format json`), as dotted keys.
    func systemProperties() async throws -> [SystemProperty] {
        let result = try await run(["system", "property", "list", "--format", "json"])
        return try ContainerOutputParser.systemProperties(result.stdout)
    }

    /// Writes the key to `~/.config/container/config.toml` (there is no CLI setter
    /// since 1.0). An empty value removes the key. Takes effect after
    /// `restartSystemService()`.
    func setSystemProperty(_ key: String, value: String) async throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else { throw DeckError.commandFailed("The setting name is empty.") }
        do {
            try SystemConfigFile.set(trimmedKey, value: value)
        } catch {
            throw DeckError.commandFailed("Could not save \(SystemConfigFile.defaultURL().path). \(error.localizedDescription)")
        }
    }

    func dnsDomains() async throws -> [String] {
        let json = try await runner.run(cli.path, ["system", "dns", "list", "--format", "json"])
        if json.succeeded, let domains = ContainerOutputParser.dnsDomains(json.stdout) {
            return domains
        }
        return try await cli.dnsDomains()
    }

    /// `sudo container system dns create` arguments (without "container").
    /// `localhost` is an IPv4 address that macOS redirects to 127.0.0.1 for this domain.
    func dnsCreateArguments(_ domain: String, localhost: String? = nil) -> [String] {
        var args = ["system", "dns", "create"]
        if let localhost = CLIText.nonEmpty(localhost) { args += ["--localhost", localhost] }
        args.append(domain)
        return args
    }

    /// Needs admin. Like `createDNSDomain(_:)` with `--localhost`.
    func createDNSDomain(_ domain: String, localhost: String?) async throws {
        try await PrivilegedRunner(runner: runner).run(cli.path, dnsCreateArguments(domain, localhost: localhost)).orThrow()
    }

    /// Needs admin. Runs through PrivilegedRunner.
    func createDNSDomain(_ domain: String) async throws {
        try await PrivilegedRunner(runner: runner).run(cli.path, ["system", "dns", "create", domain]).orThrow()
    }

    /// Needs admin. Runs through PrivilegedRunner.
    func deleteDNSDomain(_ domain: String) async throws {
        try await PrivilegedRunner(runner: runner).run(cli.path, ["system", "dns", "delete", domain]).orThrow()
    }

    func registries() async throws -> [String] {
        let json = try await runner.run(cli.path, ["registry", "list", "--format", "json"])
        if json.succeeded {
            return ContainerOutputParser.registries(json.stdout)
        }
        let table = try await run(["registry", "list"])
        return ContainerOutputParser.registries(table.stdout)
    }

    /// Logins with user names (`registry list --format json`). The CLI stores
    /// docker.io as registry-1.docker.io, `RegistryLogin.displayHost` maps it back.
    func registryLogins() async throws -> [RegistryLogin] {
        let json = try await runner.run(cli.path, ["registry", "list", "--format", "json"])
        if json.succeeded, let logins = RegistryLogin.parseList(json.stdout) {
            return logins
        }
        return try await registries().map { RegistryLogin(server: $0) }
    }

    /// Password goes over stdin, never on the command line.
    func registryLogin(server: String, username: String, password: String) async throws {
        try await run(["registry", "login", "--username", username, "--password-stdin", server], stdin: password)
    }

    /// `scheme` is "http" or "https" (`--scheme`). Use http for a local registry without TLS.
    func registryLogin(server: String, username: String, password: String, scheme: String?) async throws {
        try await run(registryLoginArguments(server: server, username: username, scheme: scheme), stdin: password)
    }

    /// `container registry login` arguments (password goes over stdin), for CommandHint.
    func registryLoginArguments(server: String, username: String, scheme: String? = nil) -> [String] {
        var args = ["registry", "login"]
        if let scheme = CLIText.nonEmpty(scheme) { args += ["--scheme", scheme] }
        args += ["--username", username, "--password-stdin", server]
        return args
    }

    func registryLogout(server: String) async throws {
        try await run(["registry", "logout", server])
    }
}

// MARK: - ContainerClient additions (see docs/ARCHITECTURE.md)

public extension ContainerClient {
    /// `container logs` arguments, for CommandHint.
    func logArguments(_ id: String, options: LogOptions = LogOptions()) -> [String] {
        var args = ["logs"]
        if options.follow { args.append("--follow") }
        if let tail = options.tail, tail >= 0 { args += ["-n", String(tail)] }
        if options.boot { args.append("--boot") }
        args.append(id)
        return args
    }

    /// `container image pull` arguments, for CommandHint.
    func pullArguments(_ reference: String, platform: String? = nil) -> [String] {
        var args = ["image", "pull"]
        if let platform = CLIText.nonEmpty(platform) { args += ["--platform", platform] }
        args.append(reference)
        return args
    }

    /// `container build` arguments, for CommandHint.
    func buildArguments(_ options: BuildOptions) -> [String] {
        var args = ["build", "--progress", "plain"]
        if let file = CLIText.nonEmpty(options.dockerfile) { args += ["--file", file] }
        for tag in options.tags {
            if let tag = CLIText.nonEmpty(tag) { args += ["--tag", tag] }
        }
        for arg in options.buildArgs {
            let key = arg.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            args += ["--build-arg", "\(key)=\(arg.value)"]
        }
        if let platform = CLIText.nonEmpty(options.platform) { args += ["--platform", platform] }
        if let target = CLIText.nonEmpty(options.target) { args += ["--target", target] }
        if options.noCache { args.append("--no-cache") }
        args.append(CLIText.nonEmpty(options.contextDir) ?? ".")
        return args
    }

    /// Details for several containers in one `container inspect` call.
    func inspectContainers(_ ids: [String]) async throws -> [ContainerDetail] {
        guard !ids.isEmpty else { return [] }
        if let router { return try await router.inspectContainers(ids) }
        let result = try await run(["inspect"] + ids)
        return try ContainerOutputParser.containerDetails(result.stdout)
    }

    /// Stops and starts the platform services, so `config.toml` changes apply.
    func restartSystemService() async throws {
        try await cli.stopService().orThrow()
        try await cli.startService().orThrow()
    }

}

// MARK: - Helpers

extension ContainerClient {
    static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    /// `--volume src:dst[:ro]`, or `--mount` when a path contains ":".
    static func mountArguments(_ mount: MountSpec) -> [String] {
        let source = mount.source.trimmingCharacters(in: .whitespaces)
        let destination = mount.destination.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty, !destination.isEmpty else { return [] }
        if !source.contains(":") && !destination.contains(":") {
            return ["--volume", "\(source):\(destination)" + (mount.readOnly ? ":ro" : "")]
        }
        var parts = ["type=\(mount.kind == .bind ? "bind" : "volume")", "source=\(source)", "target=\(destination)"]
        if mount.readOnly { parts.append("readonly") }
        return ["--mount", parts.joined(separator: ",")]
    }

    /// True when the CLI does not know the subcommand (older releases).
    static func isMissingCommand(_ result: CommandResult) -> Bool {
        let text = (result.stderr + " " + result.stdout).lowercased()
        return text.contains("unknown command") || text.contains("unexpected argument")
            || text.contains("unknown argument") || text.contains("plugin")
    }

    /// Lines without ANSI codes. Blank lines are dropped unless `keepBlank`.
    static func cleanLines(_ source: AsyncThrowingStream<String, Error>, keepBlank: Bool = false) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in source {
                        let clean = CLIText.strippingANSI(line)
                        if keepBlank || !clean.trimmingCharacters(in: .whitespaces).isEmpty {
                            continuation.yield(clean)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func volumeUsers(_ containers: [ContainerSummary]) async -> [String: [String]] {
        guard let details = try? await inspectContainers(containers.map(\.id)) else { return [:] }
        return ContainerOutputParser.volumeUsers(details)
    }

    /// `container copy` fallback: tar inside the container, base64 over exec.
    func copyOutWithTar(_ id: String, path: String, to destination: URL) async throws {
        let script = #"cd "$(dirname "$1")" && tar -cf - "$(basename "$1")" | base64"#
        let result = try await runner.run(cli.path, ["exec", id, "sh", "-c", script, "sh", path]).orThrow()
        guard let data = Data(base64Encoded: result.stdout, options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw DeckError.parse("the copied files")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("deck-copy-\(UUID().uuidString)", isDirectory: true)
        let unpacked = work.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent("files.tar")
        try data.write(to: archive)
        try await runner.run("/usr/bin/tar", ["-xf", archive.path, "-C", unpacked.path]).orThrow()

        let name = (path as NSString).lastPathComponent
        let item = unpacked.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        var target = destination
        if fm.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            target = destination.appendingPathComponent(name)
        }
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: item, to: target)
    }

    /// `container copy` fallback: tar on the Mac, base64 over `exec -i`.
    func copyInWithTar(_ id: String, from source: URL, path: String) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("deck-copy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent("files.tar")
        let name = source.lastPathComponent
        try await runner.run("/usr/bin/tar", ["-cf", archive.path, "-C", source.deletingLastPathComponent().path, name]).orThrow()
        let encoded = try Data(contentsOf: archive).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])

        // An existing folder receives the item. Otherwise the item lands at `path`.
        let script = """
        dest="$1"; name="$2"
        case "$dest" in */) mkdir -p "$dest" ;; esac
        if [ -d "$dest" ]; then
          cd "$dest" && base64 -d | tar -xf -
        else
          parent=$(dirname "$dest"); base=$(basename "$dest")
          mkdir -p "$parent" && cd "$parent" && base64 -d | tar -xf - && if [ "$name" != "$base" ]; then mv -f "$name" "$base"; fi
        fi
        """
        try await runner.run(
            cli.path,
            ["exec", "-i", id, "sh", "-c", script, "sh", path, name],
            stdin: Data((encoded + "\n").utf8)
        ).orThrow()
    }
}
