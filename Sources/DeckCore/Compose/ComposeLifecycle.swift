import Foundation

// Lifecycle pieces of ComposeRunner: hooks, stop signals, pull policies,
// orphans and the dry run. Kept apart so the main runner stays readable.

public extension ComposeRunner {

    /// Which hook list to run.
    enum HookKind: String, Sendable {
        case postStart = "post_start"
        case preStop = "pre_stop"
    }

    /// What Up does about a service's image.
    enum ImageAction: Equatable, Sendable {
        case none
        case pull
        case build
        /// The image is missing and the policy says never pull.
        case missingNeverPull
    }

    /// `--pull` from Up wins, then the service's `pull_policy`, then "missing".
    static func imageAction(for service: ComposeServicePlan, hasImage: Bool, options: UpOptions) -> ImageAction {
        let policy = options.pull ?? service.service.pullPolicy ?? .missing
        if service.build != nil {
            if options.alwaysBuild || policy == .build || !hasImage { return .build }
            return .none
        }
        switch policy {
        case .always:
            return .pull
        case .never:
            return hasImage ? .none : .missingNeverPull
        case .missing, .build:
            return hasImage ? .none : .pull
        }
    }

    /// Containers of the plan's project whose service is no longer in the file.
    static func orphans(_ plan: ComposePlan, containers: [ContainerSummary]) -> [ContainerSummary] {
        let known = Set(plan.project.services.map(\.name))
        return containers.filter { container in
            guard ComposeLabel.belongs(container.labels, to: plan.projectName),
                  let service = ComposeLabel.serviceName(container.labels) else { return false }
            return !known.contains(service)
        }
    }

    /// `container stop` arguments when the service sets a stop signal or grace
    /// period (from the plan, else the container labels). nil means a plain stop.
    static func stopArguments(_ container: ContainerSummary, plan: ComposeServicePlan?) -> [String]? {
        let signal = plan?.stopSignal ?? container.labels[ComposeLabel.stopSignal]
        let timeout = plan?.stopTimeout ?? container.labels[ComposeLabel.stopTimeout].flatMap { Int($0) }
        guard (signal?.isEmpty == false) || timeout != nil else { return nil }
        var args = ["stop"]
        if let signal, !signal.isEmpty { args += ["--signal", signal] }
        if let timeout { args += ["--time", String(max(0, timeout))] }
        args.append(container.id)
        return args
    }

    /// Stops with the service's stop signal and grace period when it has them.
    func stopContainer(_ container: ContainerSummary, plan: ComposeServicePlan?) async throws {
        if let args = Self.stopArguments(container, plan: plan) {
            try await client.run(args)
        } else {
            try await client.stopContainer(container.id)
        }
    }

    /// Runs the service's hooks in order with `container exec`. Output goes to
    /// the events. A failed post_start hook throws. A failed pre_stop hook warns.
    func runHooks(_ kind: HookKind, service: ComposeServicePlan, container: String, events: @escaping ComposeEventHandler) async throws {
        let hooks = kind == .postStart ? service.service.postStart : service.service.preStop
        for (index, hook) in hooks.enumerated() {
            try Task.checkCancellation()
            let number = hooks.count > 1 ? " \(index + 1) of \(hooks.count)" : ""
            events(ComposeEvent(.step, "Running \(kind.rawValue) hook\(number): \(hook.command.joined(separator: " "))", service: service.name))
            let result = try await client.runner.run(client.cli.path, hook.execArguments(container: container))
            for line in (result.stdout + "\n" + result.stderr).split(whereSeparator: \.isNewline) {
                let text = line.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { events(ComposeEvent(.output, text, service: service.name)) }
            }
            guard result.succeeded else {
                let message = "The \(kind.rawValue) hook of \(service.name) failed with exit code \(result.exitCode)."
                if kind == .postStart { throw ComposeError.failed(message) }
                events(ComposeEvent(.warning, message + " Stopping anyway.", service: service.name))
                continue
            }
        }
    }

    /// post_start hooks for containers that were just started, in plan order.
    internal func runPostStartHooks(_ containers: [ContainerSummary], plan: ComposePlan?, events: @escaping ComposeEventHandler) async throws {
        guard let plan else { return }
        for container in containers {
            guard let name = ComposeLabel.serviceName(container.labels), let service = plan.service(name) else { continue }
            try await runHooks(.postStart, service: service, container: container.id, events: events)
        }
    }

    // MARK: - Dry run

    /// Reads the current state (nothing is changed) and reports what Up would do.
    internal func dryRun(_ plan: ComposePlan, options: UpOptions, events: @escaping ComposeEventHandler) async {
        let containers = (try? await client.listContainers(all: true)) ?? []
        let networks = Set(((try? await client.listNetworks()) ?? []).map(\.name))
        let volumes = Set(((try? await client.listVolumes()) ?? []).map(\.name))
        let images = Set(((try? await client.listImages()) ?? []).map { Self.normalizeImage($0.reference) })
        for event in dryRunEvents(plan, options: options, containers: containers, networks: networks, volumes: volumes, images: images) {
            events(event)
        }
    }

    /// The events a dry run emits for this state. Pure, so tests can check it.
    func dryRunEvents(
        _ plan: ComposePlan, options: UpOptions, containers: [ContainerSummary],
        networks: Set<String>, volumes: Set<String>, images: Set<String>
    ) -> [ComposeEvent] {
        var out: [ComposeEvent] = []
        func command(_ args: [String], service: String? = nil) {
            out.append(ComposeEvent(.output, client.commandLine(args), service: service))
        }
        let project = plan.projectName
        out.append(ComposeEvent(.step, "Dry run for \(project). Nothing is changed."))

        for network in plan.networks where !networks.contains(network.name) {
            if network.external {
                out.append(ComposeEvent(.warning, "The external network \(network.name) does not exist. Up would fail."))
            } else {
                out.append(ComposeEvent(.step, "Would create network \(network.name)"))
                command(network.createArguments)
            }
        }
        for volume in plan.volumes where !volumes.contains(volume.name) {
            if volume.external {
                out.append(ComposeEvent(.warning, "The external volume \(volume.name) does not exist. Up would fail."))
            } else {
                out.append(ComposeEvent(.step, "Would create volume \(volume.name)"))
                command(volume.createArguments)
            }
        }
        for service in plan.services {
            let hasImage = images.contains(Self.normalizeImage(service.options.image))
            switch Self.imageAction(for: service, hasImage: hasImage, options: options) {
            case .none:
                break
            case .build:
                out.append(ComposeEvent(.step, "Would build \(service.options.image)", service: service.name))
                if let build = service.build { command(ComposePlanner.buildArguments(build), service: service.name) }
            case .pull:
                out.append(ComposeEvent(.step, "Would pull \(service.options.image)", service: service.name))
                var args = ["image", "pull"]
                if let platform = service.options.platform { args += ["--platform", platform] }
                command(args + [service.options.image], service: service.name)
            case .missingNeverPull:
                out.append(ComposeEvent(.warning, "The image \(service.options.image) is not on this Mac and the pull policy is never. Up would fail.", service: service.name))
            }
        }

        for orphan in Self.orphans(plan, containers: containers) {
            let service = ComposeLabel.serviceName(orphan.labels)
            if options.removeOrphans {
                out.append(ComposeEvent(.step, "Would remove orphan \(orphan.name)", service: service))
            } else {
                out.append(ComposeEvent(.info, "Would keep orphan \(orphan.name)", service: service))
            }
        }

        var existing: [String: ContainerSummary] = [:]
        for container in containers where ComposeLabel.belongs(container.labels, to: project) {
            if let service = ComposeLabel.serviceName(container.labels) { existing[service] = container }
        }
        for service in plan.services {
            let name = service.name
            var creates = true
            if let current = existing[name] {
                let same = current.labels[ComposeLabel.configHash] == service.configHash
                if same && !options.forceRecreate {
                    creates = false
                    if current.isRunning {
                        out.append(ComposeEvent(.info, "Up to date", service: name))
                        continue
                    }
                    out.append(ComposeEvent(.step, "Would start \(service.containerName)", service: name))
                    command(["start", current.id], service: name)
                } else {
                    out.append(ComposeEvent(.step, same ? "Would recreate \(service.containerName)" : "Config changed. Would recreate \(service.containerName)", service: name))
                    if current.isRunning {
                        for hook in service.service.preStop {
                            out.append(ComposeEvent(.step, "Would run pre_stop hook: \(hook.command.joined(separator: " "))", service: name))
                        }
                    }
                }
            } else if containers.contains(where: { $0.name == service.containerName || $0.id == service.containerName }) {
                out.append(ComposeEvent(.warning, "A container named \(service.containerName) already exists and is not part of \(project). Up would fail.", service: name))
                continue
            }
            if creates {
                if existing[name] == nil {
                    out.append(ComposeEvent(.step, "Would create and start \(service.containerName)", service: name))
                }
                command(client.runArguments(service.options), service: name)
            }
            for hook in service.service.postStart {
                out.append(ComposeEvent(.step, "Would run post_start hook: \(hook.command.joined(separator: " "))", service: name))
                command(hook.execArguments(container: service.containerName), service: name)
            }
        }
        out.append(ComposeEvent(.success, "Dry run finished. Nothing was changed."))
        return out
    }
}
