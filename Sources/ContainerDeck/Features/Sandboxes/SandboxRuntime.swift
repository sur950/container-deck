import Foundation
import DeckCore

/// Keeps the allow list proxy and model relay running for every running sandbox,
/// and stops them the moment a sandbox stops or the kill switch is pressed.
///
/// Reads the shared container feed (`BackgroundServices.shared.containers`), so it adds
/// no polling of its own. Sandboxes are labelled containers, so after an app restart the
/// services come back from the labels alone.
@MainActor
@Observable
final class SandboxRuntime {
    static let shared = SandboxRuntime()

    /// Sandboxes from the latest container list.
    private(set) var sandboxes: [Sandbox] = []
    /// Recent egress events per sandbox, newest last.
    private(set) var events: [String: [SandboxEgressEvent]] = [:]
    /// Why the services of a sandbox are not running (cannot bind, and so on).
    private(set) var serviceErrors: [String: String] = [:]
    /// Sandboxes whose proxy or relay is up.
    private(set) var activeServices: Set<String> = []
    /// Selected sandbox on the screen. Kept here so it survives the screen being rebuilt
    /// (appearance change, leaving and coming back).
    var selection: Sandbox.ID?

    @ObservationIgnored private var gateways: [String: (plan: SandboxGatewayPlan, gateway: SandboxGateway)] = [:]
    @ObservationIgnored private var starting: Set<String> = []
    @ObservationIgnored private var lastAttempt: [String: Date] = [:]
    /// Killed by the kill switch: no services until the person starts the sandbox again.
    @ObservationIgnored private var killed: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?

    private init() {}

    /// Starts watching the container feed. Safe to call many times.
    func attach() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.reconcile(BackgroundServices.shared.containers)
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// Brings services in line with the container list.
    func reconcile(_ containers: [ContainerSummary]) {
        let list = ContainerClient.sandboxes(in: containers)
        if list != sandboxes { sandboxes = list }
        let names = Set(list.map(\.name))
        for name in gateways.keys where !names.contains(name) { stopServices(name) }

        for sandbox in list {
            guard sandbox.isRunning, !killed.contains(sandbox.name), let plan = sandbox.gatewayPlan else {
                if gateways[sandbox.name] != nil { stopServices(sandbox.name) }
                if !sandbox.isRunning { serviceErrors[sandbox.name] = nil }
                continue
            }
            if let current = gateways[sandbox.name], current.plan == plan { continue }
            if gateways[sandbox.name] != nil { stopServices(sandbox.name) }
            startServices(sandbox.name, plan: plan)
        }
    }

    private func startServices(_ name: String, plan: SandboxGatewayPlan) {
        guard !starting.contains(name) else { return }
        // Binding fails until the gateway interface is up. Retry every few seconds.
        if let last = lastAttempt[name], Date().timeIntervalSince(last) < 3 { return }
        lastAttempt[name] = Date()
        starting.insert(name)
        let gateway = plan.makeGateway { [weak self] event in
            Task { @MainActor in self?.record(event, for: name) }
        }
        Task {
            do {
                try await gateway.start()
                starting.remove(name)
                // Killed or changed while binding: drop it.
                guard !killed.contains(name), sandboxes.contains(where: { $0.name == name && $0.isRunning }) else {
                    gateway.stop()
                    return
                }
                gateways[name] = (plan, gateway)
                activeServices.insert(name)
                serviceErrors[name] = nil
            } catch {
                starting.remove(name)
                gateway.stop()
                serviceErrors[name] = "Network services are not up yet. \(error.localizedDescription)"
            }
        }
    }

    private func stopServices(_ name: String) {
        gateways[name]?.gateway.stop()
        gateways[name] = nil
        activeServices.remove(name)
    }

    private func record(_ event: SandboxEgressEvent, for name: String) {
        var list = events[name] ?? []
        list.append(event)
        if list.count > SandboxConfig.maxEvents { list.removeFirst(list.count - SandboxConfig.maxEvents) }
        events[name] = list
        if event.kind == .failed && event.host == SandboxGateway.firewallHost {
            serviceErrors[name] = "The macOS firewall is holding the sandbox's connections. Allow \(AppConfig.appName) to accept incoming connections when macOS asks, or in System Settings, Network, Firewall."
        } else if event.kind == .allowed || event.kind == .relay {
            serviceErrors[name] = nil
        }
    }

    func clearEvents(_ name: String) {
        events[name] = []
    }

    func isKilled(_ name: String) -> Bool { killed.contains(name) }

    // MARK: - Actions

    /// Kill switch: closes the proxy and relay (every open connection) first, then SIGKILLs the container.
    func kill(_ sandbox: Sandbox, client: ContainerClient) async throws {
        killed.insert(sandbox.name)
        stopServices(sandbox.name)
        record(SandboxEgressEvent(kind: .blocked, host: "Kill switch", port: 0, detail: "All traffic stopped"), for: sandbox.name)
        try await client.killSandbox(sandbox)
    }

    /// Starts a stopped sandbox and puts the key back into its memory folder.
    func start(_ sandbox: Sandbox, client: ContainerClient) async throws {
        killed.remove(sandbox.name)
        lastAttempt[sandbox.name] = nil
        let key = sandbox.model?.hasKey == true ? try SandboxKeychain().read(account: sandbox.name) : nil
        try await client.startSandbox(sandbox, apiKey: key)
    }

    func stop(_ sandbox: Sandbox, client: ContainerClient) async throws {
        stopServices(sandbox.name)
        try await client.stopContainer(sandbox.container.id)
    }

    /// Removes the container, its network and its Keychain key.
    func remove(_ sandbox: Sandbox, client: ContainerClient) async throws {
        killed.insert(sandbox.name)
        stopServices(sandbox.name)
        try await client.removeSandbox(sandbox)
        try? SandboxKeychain().delete(account: sandbox.name)
        events[sandbox.name] = nil
        serviceErrors[sandbox.name] = nil
        killed.remove(sandbox.name)
    }

    /// Forget a kill (a new sandbox reused the name).
    func clearKill(_ name: String) {
        killed.remove(name)
        lastAttempt[name] = nil
    }
}
