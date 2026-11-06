import Foundation

/// One step of progress for the UI.
public struct ComposeEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case step, info, output, success, warning, failure
    }

    public let id: UUID
    public var date: Date
    public var kind: Kind
    public var service: String?
    public var message: String

    public init(_ kind: Kind, _ message: String, service: String? = nil, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.kind = kind
        self.service = service
        self.message = message
    }
}

public typealias ComposeEventHandler = @Sendable (ComposeEvent) -> Void

/// A log line from one service.
public struct ComposeLogLine: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var service: String
    public var text: String

    public init(service: String, text: String) {
        self.id = UUID()
        self.service = service
        self.text = text
    }
}

/// A running or stopped container that belongs to a compose project.
public struct ComposeServiceStatus: Sendable, Hashable, Identifiable {
    public var service: String
    public var container: ContainerSummary

    public var id: String { container.id }
    public var ipAddress: String? { ComposeRunner.cleanIP(container.ipAddress) }

    public init(service: String, container: ContainerSummary) {
        self.service = service
        self.container = container
    }
}

/// A compose project found on the Mac by its labels.
public struct ComposeStack: Sendable, Hashable, Identifiable {
    public var name: String
    /// Compose file from the label, when known.
    public var file: URL?
    /// Every compose file from the labels, main file first. Holds `file` alone for one file.
    public var files: [URL]
    public var services: [ComposeServiceStatus]
    /// Who started it. `.docker` stacks were made by another compose tool.
    public var origin: ComposeOrigin

    public var id: String { name }
    public var runningCount: Int { services.filter { $0.container.isRunning }.count }

    public init(name: String, file: URL?, files: [URL]? = nil, services: [ComposeServiceStatus], origin: ComposeOrigin = .deck) {
        self.name = name
        self.file = file
        self.files = files ?? (file.map { [$0] } ?? [])
        self.services = services
        self.origin = origin
    }

    /// Groups containers by the project label. Our own label first, then Docker
    /// Compose labels, so stacks started by other compose tools show up too.
    public static func group(_ containers: [ContainerSummary]) -> [ComposeStack] {
        var byProject: [String: [ContainerSummary]] = [:]
        for container in containers {
            guard let project = ComposeLabel.projectName(container.labels) else { continue }
            byProject[project, default: []].append(container)
        }
        return byProject.keys.sorted().map { (name: String) -> ComposeStack in
            let members = byProject[name] ?? []
            let file = members.compactMap { ComposeLabel.filePath($0.labels) }.first.map { URL(fileURLWithPath: $0) }
            let files = (members.map { ComposeLabel.filePaths($0.labels) }.first { !$0.isEmpty } ?? []).map { URL(fileURLWithPath: $0) }
            let services = members
                .map { ComposeServiceStatus(service: ComposeLabel.serviceName($0.labels) ?? $0.name, container: $0) }
                .sorted { $0.service < $1.service }
            let origin: ComposeOrigin = members.contains { ComposeLabel.origin($0.labels) == .deck } ? .deck : .docker
            return ComposeStack(name: name, file: file, files: files.isEmpty ? nil : files, services: services, origin: origin)
        }
    }
}

/// One name to put in /etc/hosts.
public struct ComposeHostEntry: Sendable, Hashable {
    public var service: String
    public var containerName: String
    public var ip: String
    public var aliases: [String]

    public init(service: String, containerName: String, ip: String, aliases: [String] = []) {
        self.service = service
        self.containerName = containerName
        self.ip = ip
        self.aliases = aliases
    }
}

/// Runs a compose plan with Apple's container tool.
public struct ComposeRunner: Sendable {
    public struct UpOptions: Sendable, Hashable {
        /// Recreate every service even when its config did not change.
        public var forceRecreate: Bool
        /// Build images even when they exist.
        public var alwaysBuild: Bool
        /// Take everything down again when a step fails.
        public var downOnFailure: Bool
        /// Show what Up would do and change nothing.
        public var dryRun: Bool
        /// Remove containers of the project whose service is no longer in the file.
        public var removeOrphans: Bool
        /// `--pull` for every service. nil uses each service's `pull_policy` (missing by default).
        public var pull: ComposePullPolicy?

        public init(
            forceRecreate: Bool = false, alwaysBuild: Bool = false, downOnFailure: Bool = false,
            dryRun: Bool = false, removeOrphans: Bool = true, pull: ComposePullPolicy? = nil
        ) {
            self.forceRecreate = forceRecreate
            self.alwaysBuild = alwaysBuild
            self.downOnFailure = downOnFailure
            self.dryRun = dryRun
            self.removeOrphans = removeOrphans
            self.pull = pull
        }
    }

    public static let hostsMarker = "# deck-compose"

    public let client: ContainerClient
    /// Seconds between status checks. Tests set it low.
    public var pollInterval: TimeInterval

    public init(client: ContainerClient, pollInterval: TimeInterval = 1) {
        self.client = client
        self.pollInterval = pollInterval
    }

    // MARK: - Up

    public func up(_ plan: ComposePlan, options: UpOptions = UpOptions(), events: @escaping ComposeEventHandler) async throws {
        let project = plan.projectName
        if plan.project.hasBlockingProblems {
            let error = ComposeError.blocked("Fix the problems marked \"Needs a fix\" first.")
            events(ComposeEvent(.failure, error.localizedDescription))
            throw error
        }
        if options.dryRun {
            await dryRun(plan, options: options, events: events)
            return
        }
        events(ComposeEvent(.step, "Starting \(project)"))
        do {
            try await performUp(plan, options: options, events: events)
            events(ComposeEvent(.success, "\(project) is up"))
        } catch {
            if error is CancellationError {
                events(ComposeEvent(.warning, "Stopped by you"))
            } else {
                events(ComposeEvent(.failure, error.localizedDescription))
            }
            if options.downOnFailure && !(error is CancellationError) {
                events(ComposeEvent(.step, "Taking \(project) down after the failure"))
                try? await down(project: project, removeVolumes: false, plan: plan, events: events)
            }
            throw error
        }
    }

    private func performUp(_ plan: ComposePlan, options: UpOptions, events: @escaping ComposeEventHandler) async throws {
        let project = plan.projectName

        // Networks. On older macOS only the default network exists, so a failed
        // create falls back to it. Services still find each other through /etc/hosts.
        var failedNetworks: Set<String> = []
        let existingNetworks = Set(((try? await client.listNetworks()) ?? []).map(\.name))
        for network in plan.networks where !existingNetworks.contains(network.name) {
            try Task.checkCancellation()
            if network.external {
                throw ComposeError.failed("The external network \(network.name) does not exist.")
            }
            events(ComposeEvent(.step, "Creating network \(network.name)"))
            do {
                try await client.createNetwork(name: network.name, subnet: network.subnet, internal: network.isInternal)
            } catch {
                failedNetworks.insert(network.name)
                events(ComposeEvent(.warning, "Could not create network \(network.name). Using the default network. \(error.localizedDescription)"))
            }
        }

        // Volumes
        let existingVolumes = Set(((try? await client.listVolumes()) ?? []).map(\.name))
        for volume in plan.volumes where !existingVolumes.contains(volume.name) {
            try Task.checkCancellation()
            if volume.external {
                throw ComposeError.failed("The external volume \(volume.name) does not exist.")
            }
            events(ComposeEvent(.step, "Creating volume \(volume.name)"))
            try await client.createVolume(name: volume.name, labels: volume.labels)
        }

        // Images
        let images = Set(((try? await client.listImages()) ?? []).map { Self.normalizeImage($0.reference) })
        for service in plan.services {
            try Task.checkCancellation()
            let hasImage = images.contains(Self.normalizeImage(service.options.image))
            switch Self.imageAction(for: service, hasImage: hasImage, options: options) {
            case .none:
                break
            case .build:
                if let build = service.build {
                    try await runBuild(build, service: service.name, events: events)
                }
            case .pull:
                try await runPull(service.options.image, platform: service.options.platform, service: service.name, events: events)
            case .missingNeverPull:
                throw ComposeError.failed("The image \(service.options.image) for \(service.name) is not on this Mac and the pull policy is never.")
            }
        }

        // Containers
        var allContainers = try await client.listContainers(all: true)

        // Orphans: containers of the project whose service left the file.
        let orphans = Self.orphans(plan, containers: allContainers)
        if !orphans.isEmpty {
            if options.removeOrphans {
                for orphan in orphans {
                    try Task.checkCancellation()
                    let service = ComposeLabel.serviceName(orphan.labels)
                    events(ComposeEvent(.step, "Removing orphan \(orphan.name)", service: service))
                    if orphan.isRunning {
                        try? await stopContainer(orphan, plan: nil)
                    }
                    try await client.deleteContainer(orphan.id, force: true)
                }
                let removed = Set(orphans.map(\.id))
                allContainers.removeAll { removed.contains($0.id) }
            } else {
                let names = orphans.map(\.name).joined(separator: ", ")
                events(ComposeEvent(.warning, "Kept containers that are no longer in the file: \(names)."))
            }
        }

        var existing: [String: ContainerSummary] = [:]
        for container in allContainers where ComposeLabel.belongs(container.labels, to: project) {
            if let service = ComposeLabel.serviceName(container.labels) { existing[service] = container }
        }
        var healthy: Set<String> = []
        // Services others wait on with service_completed_successfully. They run
        // attached so we get the exit code. `container inspect` has no exit code.
        let oneShots = Self.completionTargets(plan)
        var exitCodes: [String: Int32] = [:]

        for service in plan.services {
            try Task.checkCancellation()
            try await waitForDependencies(of: service, plan: plan, healthy: &healthy, exitCodes: exitCodes, events: events)

            var runOptions = service.options
            if let network = runOptions.network, failedNetworks.contains(network) {
                runOptions.network = nil
            }

            if let current = existing[service.name] {
                let sameConfig = current.labels[ComposeLabel.configHash] == service.configHash
                if sameConfig && !options.forceRecreate {
                    if current.isRunning {
                        events(ComposeEvent(.info, "Up to date", service: service.name))
                    } else if oneShots.contains(service.name) {
                        events(ComposeEvent(.step, "Running \(service.containerName)", service: service.name))
                        exitCodes[service.name] = try await runAttached(["start", "--attach", current.id], container: current.id)
                    } else {
                        events(ComposeEvent(.step, "Starting \(service.containerName)", service: service.name))
                        try await client.startContainer(current.id)
                        await updateServiceDiscovery(project: project, plan: plan, events: nil)
                        try await runHooks(.postStart, service: service, container: current.id, events: events)
                        continue
                    }
                    await updateServiceDiscovery(project: project, plan: plan, events: nil)
                    continue
                }
                events(ComposeEvent(.step, sameConfig ? "Recreating \(service.containerName)" : "Config changed. Recreating \(service.containerName)", service: service.name))
                if current.isRunning {
                    try? await runHooks(.preStop, service: service, container: current.id, events: events)
                    try? await stopContainer(current, plan: service)
                }
                try await client.deleteContainer(current.id, force: true)
            } else if let clash = allContainers.first(where: { $0.name == service.containerName || $0.id == service.containerName }) {
                throw ComposeError.failed("A container named \(clash.name) already exists and is not part of \(project). Remove it or set container_name.")
            }

            createBindFolders(for: service, events: events)
            if oneShots.contains(service.name) {
                runOptions.detach = false
                events(ComposeEvent(.step, "Running \(service.containerName)", service: service.name))
                exitCodes[service.name] = try await runAttached(client.runArguments(runOptions), container: service.containerName)
                continue
            }
            events(ComposeEvent(.step, "Starting \(service.containerName)", service: service.name))
            try await client.runContainer(runOptions)
            // Give dependents the new address as soon as we can.
            await updateServiceDiscovery(project: project, plan: plan, events: nil)
            try await runHooks(.postStart, service: service, container: service.containerName, events: events)
        }

        events(ComposeEvent(.step, "Writing service names to /etc/hosts"))
        await updateServiceDiscovery(project: project, plan: plan, events: events)
    }

    /// Names of services that some other service waits on to finish.
    static func completionTargets(_ plan: ComposePlan) -> Set<String> {
        var names: Set<String> = []
        for service in plan.services {
            for dependency in service.service.dependsOn where dependency.condition == .completed {
                names.insert(dependency.service)
            }
        }
        return names
    }

    /// Runs `container run` or `container start --attach` and waits for the
    /// process to end. Returns its exit code. Throws when the container
    /// itself could not be made.
    private func runAttached(_ arguments: [String], container: String) async throws -> Int32 {
        let result = try await client.runner.run(client.cli.path, arguments)
        if result.exitCode == 0 { return 0 }
        let exists = ((try? await client.listContainers(all: true)) ?? [])
            .contains { $0.id == container || $0.name == container }
        if !exists {
            // stderr also carries progress lines like "[1/6] Fetching image". Keep the last real line.
            let lines = result.stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            let message = lines.last { !$0.isEmpty && !$0.hasPrefix("[") } ?? "Could not start \(container)."
            throw ComposeError.failed(message)
        }
        return result.exitCode
    }

    private func runBuild(_ build: BuildOptions, service: String, events: @escaping ComposeEventHandler) async throws {
        events(ComposeEvent(.step, "Building \(build.tags.first ?? service)", service: service))
        // Tracked, so the build also shows on the Builds screen with its log and history.
        for try await line in client.trackedBuild(build, origin: .compose, detail: service) {
            events(ComposeEvent(.output, line, service: service))
        }
    }

    private func runPull(_ image: String, platform: String?, service: String?, events: @escaping ComposeEventHandler) async throws {
        events(ComposeEvent(.step, "Pulling \(image)", service: service))
        var lastEmit = Date.distantPast
        var lastLine: String?
        for try await line in client.pullImage(image, platform: platform) {
            lastLine = line
            // Progress bars print many lines. Show a few.
            if Date().timeIntervalSince(lastEmit) > 0.8 {
                lastEmit = Date()
                events(ComposeEvent(.output, line, service: service))
                lastLine = nil
            }
        }
        if let lastLine { events(ComposeEvent(.output, lastLine, service: service)) }
    }

    private func createBindFolders(for service: ComposeServicePlan, events: @escaping ComposeEventHandler) {
        let manager = FileManager.default
        for mount in service.options.mounts where mount.kind == .bind {
            if manager.fileExists(atPath: mount.source) { continue }
            do {
                try manager.createDirectory(atPath: mount.source, withIntermediateDirectories: true)
                events(ComposeEvent(.info, "Created folder \(mount.source)", service: service.name))
            } catch {
                events(ComposeEvent(.warning, "Could not create folder \(mount.source)", service: service.name))
            }
        }
    }

    // MARK: - Waiting

    private func waitForDependencies(of service: ComposeServicePlan, plan: ComposePlan, healthy: inout Set<String>, exitCodes: [String: Int32] = [:], events: @escaping ComposeEventHandler) async throws {
        for dependency in service.service.dependsOn {
            guard let target = plan.service(dependency.service) else { continue }
            do {
                switch dependency.condition {
                case .started:
                    continue
                case .healthy:
                    if healthy.contains(target.name) { continue }
                    try await waitHealthy(target, events: events)
                    healthy.insert(target.name)
                case .completed:
                    if let code = exitCodes[target.name] {
                        if code != 0 {
                            throw ComposeError.failed("\(target.name) finished with exit code \(code).")
                        }
                        continue
                    }
                    try await waitCompleted(target, events: events)
                }
            } catch let error as ComposeError where !dependency.required {
                events(ComposeEvent(.warning, "\(error.localizedDescription) Going on because it is optional.", service: service.name))
            }
        }
    }

    private func waitHealthy(_ target: ComposeServicePlan, events: @escaping ComposeEventHandler) async throws {
        guard let check = target.service.healthcheck, !check.isDisabled else { return }
        events(ComposeEvent(.step, "Waiting for \(target.name) to be healthy", service: target.name))
        let started = Date()
        let limit = check.startPeriod + (check.interval + check.timeout) * Double(max(1, check.retries)) + 10
        let pause = max(0.05, min(check.interval, 2 * pollInterval))
        while true {
            try Task.checkCancellation()
            var passed = false
            if let result = try? await client.exec(target.containerName, check.command) {
                passed = result.succeeded
            }
            if passed {
                events(ComposeEvent(.success, "\(target.name) is healthy", service: target.name))
                return
            }
            if Date().timeIntervalSince(started) > limit {
                throw ComposeError.failed("\(target.name) did not become healthy.")
            }
            try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
        }
    }

    private func waitCompleted(_ target: ComposeServicePlan, events: @escaping ComposeEventHandler) async throws {
        events(ComposeEvent(.step, "Waiting for \(target.name) to finish", service: target.name))
        let started = Date()
        while true {
            try Task.checkCancellation()
            let containers = try await client.listContainers(all: true)
            guard let container = containers.first(where: { $0.id == target.containerName || $0.name == target.containerName }) else {
                // Removed after it finished.
                return
            }
            if container.state == .stopped {
                if let detail = try? await client.inspectContainer(container.id),
                   let code = Self.exitCode(fromInspectJSON: detail.rawJSON), code != 0 {
                    throw ComposeError.failed("\(target.name) finished with exit code \(code).")
                }
                events(ComposeEvent(.success, "\(target.name) finished", service: target.name))
                return
            }
            if Date().timeIntervalSince(started) > 60 * 60 {
                throw ComposeError.failed("\(target.name) did not finish within an hour.")
            }
            try await Task.sleep(nanoseconds: UInt64(max(0.05, pollInterval) * 1_000_000_000))
        }
    }

    /// Looks for "exitCode": N in `container inspect` output.
    static func exitCode(fromInspectJSON json: String) -> Int? {
        guard let range = json.range(of: #""exit[Cc]ode"\s*:\s*-?\d+"#, options: .regularExpression) else { return nil }
        let match = json[range]
        guard let colon = match.lastIndex(of: ":") else { return nil }
        return Int(match[match.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Service discovery

    /// "192.168.64.3" from "192.168.64.3/24".
    public static func cleanIP(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.split(separator: "/").first.map(String.init)
    }

    /// Lines for /etc/hosts, one per service.
    public static func hostsLines(project: String, entries: [ComposeHostEntry]) -> [String] {
        entries.sorted { $0.service < $1.service }.map { (entry: ComposeHostEntry) -> String in
            var names = [entry.service, ComposePlanner.defaultContainerName(project: project, service: entry.service)]
            if !names.contains(entry.containerName) { names.append(entry.containerName) }
            for alias in entry.aliases where !names.contains(alias) { names.append(alias) }
            return "\(entry.ip) \(names.joined(separator: " "))  \(hostsMarker)"
        }
    }

    /// Shell script that swaps our old lines in /etc/hosts for new ones. The lines come in as $0.
    public static let hostsScript = #"grep -v '# deck-compose' /etc/hosts > /tmp/.deck-hosts 2>/dev/null; printf '%s\n' "$0" >> /tmp/.deck-hosts && cat /tmp/.deck-hosts > /etc/hosts; rm -f /tmp/.deck-hosts"#

    /// Writes every running service of the project into /etc/hosts of every
    /// running service, so names like `db` resolve. Best effort.
    public func updateServiceDiscovery(project: String, plan: ComposePlan?, events: ComposeEventHandler?) async {
        guard let containers = try? await projectContainers(project) else { return }
        let running = containers.filter(\.isRunning)
        let entries = running.compactMap { container -> ComposeHostEntry? in
            guard let service = ComposeLabel.serviceName(container.labels), let ip = Self.cleanIP(container.ipAddress) else { return nil }
            let aliases = plan?.service(service)?.service.networkAliases ?? []
            return ComposeHostEntry(service: service, containerName: container.name, ip: ip, aliases: aliases)
        }
        guard !entries.isEmpty else { return }
        let lines = Self.hostsLines(project: project, entries: entries)
        for container in running {
            let service = ComposeLabel.serviceName(container.labels) ?? container.name
            let extra = (plan?.service(service)?.service.extraHosts ?? []).map { "\($0)  \(Self.hostsMarker)" }
            let block = (lines + extra).joined(separator: "\n")
            var ok = false
            if let result = try? await client.exec(container.id, ["/bin/sh", "-c", Self.hostsScript, block]) {
                ok = result.succeeded
            }
            if !ok {
                events?(ComposeEvent(.warning, "Could not update /etc/hosts in \(container.name). Other services may not find it by name.", service: service))
            }
        }
    }

    // MARK: - Down, start, stop, restart

    public func projectContainers(_ project: String) async throws -> [ContainerSummary] {
        try await client.listContainers(all: true).filter { ComposeLabel.belongs($0.labels, to: project) }
    }

    /// Stops and deletes every container with the project label, removes the
    /// project networks and, when asked, its volumes.
    public func down(project: String, removeVolumes: Bool, keepNetworks: Bool = false, plan: ComposePlan?, events: @escaping ComposeEventHandler) async throws {
        let found = try await projectContainers(project)
        let containers = ordered(found, plan: plan).reversed()
        for container in containers {
            try Task.checkCancellation()
            let service = ComposeLabel.serviceName(container.labels)
            if container.isRunning {
                let servicePlan = service.flatMap { plan?.service($0) }
                if let servicePlan { try? await runHooks(.preStop, service: servicePlan, container: container.id, events: events) }
                events(ComposeEvent(.step, "Stopping \(container.name)", service: service))
                try? await stopContainer(container, plan: servicePlan)
            }
            events(ComposeEvent(.step, "Removing \(container.name)", service: service))
            try await client.deleteContainer(container.id, force: true)
        }

        let networks = keepNetworks ? [] : ((try? await client.listNetworks()) ?? [])
        let planned = Set((plan?.networks ?? []).filter { !$0.external }.map(\.name))
        for network in networks where !network.isDefault {
            let ours = planned.contains(network.name)
                || ComposeLabel.projectName(network.labels) == project
                || (plan == nil && network.name.hasPrefix("\(project)_"))
            guard ours else { continue }
            events(ComposeEvent(.step, "Removing network \(network.name)"))
            do {
                try await client.deleteNetwork(network.name)
            } catch {
                events(ComposeEvent(.warning, "Could not remove network \(network.name). \(error.localizedDescription)"))
            }
        }

        if removeVolumes {
            let volumes = (try? await client.listVolumes()) ?? []
            let plannedVolumes = Set((plan?.volumes ?? []).filter { !$0.external }.map(\.name))
            for volume in volumes where plannedVolumes.contains(volume.name) || ComposeLabel.projectName(volume.labels) == project {
                events(ComposeEvent(.step, "Removing volume \(volume.name)"))
                do {
                    try await client.deleteVolume(volume.name)
                } catch {
                    events(ComposeEvent(.warning, "Could not remove volume \(volume.name). \(error.localizedDescription)"))
                }
            }
        }
        events(ComposeEvent(.success, "\(project) is down"))
    }

    public func start(project: String, services: [String]? = nil, plan: ComposePlan?, events: @escaping ComposeEventHandler) async throws {
        let found = try await projectContainers(project)
        let containers = filter(ordered(found, plan: plan), services)
        var started: [ContainerSummary] = []
        for container in containers where !container.isRunning {
            try Task.checkCancellation()
            events(ComposeEvent(.step, "Starting \(container.name)", service: ComposeLabel.serviceName(container.labels)))
            try await client.startContainer(container.id)
            started.append(container)
        }
        await updateServiceDiscovery(project: project, plan: plan, events: events)
        try await runPostStartHooks(started, plan: plan, events: events)
        events(ComposeEvent(.success, "Started"))
    }

    public func stop(project: String, services: [String]? = nil, plan: ComposePlan?, events: @escaping ComposeEventHandler) async throws {
        let found = try await projectContainers(project)
        let containers = filter(ordered(found, plan: plan), services).reversed()
        for container in containers where container.isRunning {
            try Task.checkCancellation()
            let service = ComposeLabel.serviceName(container.labels)
            let servicePlan = service.flatMap { plan?.service($0) }
            if let servicePlan { try? await runHooks(.preStop, service: servicePlan, container: container.id, events: events) }
            events(ComposeEvent(.step, "Stopping \(container.name)", service: service))
            try await stopContainer(container, plan: servicePlan)
        }
        events(ComposeEvent(.success, "Stopped"))
    }

    public func restart(project: String, services: [String]? = nil, plan: ComposePlan?, events: @escaping ComposeEventHandler) async throws {
        let found = try await projectContainers(project)
        let containers = filter(ordered(found, plan: plan), services)
        for container in containers {
            try Task.checkCancellation()
            let service = ComposeLabel.serviceName(container.labels)
            let servicePlan = service.flatMap { plan?.service($0) }
            if container.isRunning, let servicePlan {
                try? await runHooks(.preStop, service: servicePlan, container: container.id, events: events)
            }
            events(ComposeEvent(.step, "Restarting \(container.name)", service: service))
            if container.isRunning {
                if Self.stopArguments(container, plan: servicePlan) == nil {
                    try await client.restartContainer(container.id)
                } else {
                    try await stopContainer(container, plan: servicePlan)
                    try await client.startContainer(container.id)
                }
            } else {
                try await client.startContainer(container.id)
            }
        }
        // Addresses can change on restart.
        await updateServiceDiscovery(project: project, plan: plan, events: events)
        try await runPostStartHooks(containers, plan: plan, events: events)
        events(ComposeEvent(.success, "Restarted"))
    }

    /// Pulls every image the plan uses that is not built from the file.
    public func pull(_ plan: ComposePlan, events: @escaping ComposeEventHandler) async throws {
        var done: Set<String> = []
        for service in plan.services where service.build == nil && !done.contains(service.options.image) {
            try Task.checkCancellation()
            done.insert(service.options.image)
            try await runPull(service.options.image, platform: service.options.platform, service: service.name, events: events)
        }
        events(ComposeEvent(.success, "Images are up to date"))
    }

    public func ps(project: String, plan: ComposePlan? = nil) async throws -> [ComposeServiceStatus] {
        let found = try await projectContainers(project)
        return ordered(found, plan: plan).map {
            ComposeServiceStatus(service: ComposeLabel.serviceName($0.labels) ?? $0.name, container: $0)
        }
    }

    /// Log lines from many services merged into one stream.
    public func logs(project: String, services: [String]? = nil, follow: Bool = true, tail: Int? = 200) -> AsyncThrowingStream<ComposeLogLine, Error> {
        let client = self.client
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let containers = try await client.listContainers(all: true).filter {
                        ComposeLabel.belongs($0.labels, to: project)
                            && (services == nil || services?.contains(ComposeLabel.serviceName($0.labels) ?? "") == true)
                    }
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for container in containers {
                            let service = ComposeLabel.serviceName(container.labels) ?? container.name
                            group.addTask {
                                let options = LogOptions(follow: follow, tail: tail)
                                for try await line in client.logs(container.id, options: options) {
                                    continuation.yield(ComposeLogLine(service: service, text: line))
                                }
                            }
                        }
                        try await group.waitForAll()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func ordered(_ containers: [ContainerSummary], plan: ComposePlan?) -> [ContainerSummary] {
        let fileOrder = plan?.project.services.map(\.name) ?? []
        let sortedOrder = (try? ComposeOrder.sorted(plan?.project.services ?? []))?.map(\.name) ?? fileOrder
        return containers.sorted { a, b in
            let sa = ComposeLabel.serviceName(a.labels) ?? a.name
            let sb = ComposeLabel.serviceName(b.labels) ?? b.name
            let ia = sortedOrder.firstIndex(of: sa) ?? Int.max
            let ib = sortedOrder.firstIndex(of: sb) ?? Int.max
            return ia == ib ? sa < sb : ia < ib
        }
    }

    private func filter(_ containers: [ContainerSummary], _ services: [String]?) -> [ContainerSummary] {
        guard let services else { return containers }
        return containers.filter { services.contains(ComposeLabel.serviceName($0.labels) ?? "") }
    }

    /// "nginx:latest" from "docker.io/library/nginx", for comparing image names.
    public static func normalizeImage(_ reference: String) -> String {
        var name = reference.lowercased()
        for prefix in ["docker.io/library/", "docker.io/", "index.docker.io/library/", "index.docker.io/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        if name.hasPrefix("library/") { name = String(name.dropFirst("library/".count)) }
        let lastPart = name.split(separator: "/").last.map(String.init) ?? name
        if !lastPart.contains(":") && !lastPart.contains("@") { name += ":latest" }
        return name
    }
}
