import Foundation

/// One `kubectl port-forward` the app runs.
public struct KubePortForward: Identifiable, Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case starting
        case running
        case failed(String)
        case stopped
    }

    public var id: UUID
    public var cluster: String
    public var namespace: String
    /// "service" or "pod".
    public var kind: String
    public var name: String
    public var remotePort: Int
    /// Port on this Mac. 0 until kubectl says which port it picked.
    public var localPort: Int
    public var state: State
    public var startedAt: Date

    public var target: String { "\(kind == "service" ? "svc" : kind)/\(name)" }
    public var localURL: String? { localPort > 0 ? "http://127.0.0.1:\(localPort)" : nil }
    public var isActive: Bool {
        switch state {
        case .starting, .running: return true
        default: return false
        }
    }
}

/// Runs and stops `kubectl port-forward` processes. Never installs kubectl.
public final class KubePortForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private var forwards: [UUID: KubePortForward] = [:]
    private var order: [UUID] = []
    private var processes: [UUID: Process] = [:]
    private var lastErrors: [UUID: String] = [:]
    private var stopping: Set<UUID> = []
    /// Called on any change, from a background queue.
    public var onChange: (@Sendable ([KubePortForward]) -> Void)?

    public init() {}

    public var all: [KubePortForward] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { forwards[$0] }
    }

    /// `kubectl port-forward` arguments. A local port of 0 lets kubectl pick a free one.
    public static func arguments(kubeconfig: String, context: String, namespace: String, kind: String, name: String, remotePort: Int, localPort: Int) -> [String] {
        let target = "\(kind == "service" ? "svc" : kind)/\(name)"
        let local = localPort > 0 ? String(localPort) : ""
        return [
            "--kubeconfig", kubeconfig, "--context", context,
            "--namespace", namespace,
            "port-forward", "--address", "127.0.0.1",
            target, "\(local):\(remotePort)",
        ]
    }

    /// "Forwarding from 127.0.0.1:54321 -> 80" gives 54321.
    public static func localPort(fromLine line: String) -> Int? {
        guard line.hasPrefix("Forwarding from"),
              let arrow = line.range(of: " -> ") else { return nil }
        let address = line[line.index(line.startIndex, offsetBy: "Forwarding from ".count)..<arrow.lowerBound]
        guard let colon = address.lastIndex(of: ":") else { return nil }
        return Int(address[address.index(after: colon)...])
    }

    @discardableResult
    public func start(
        kubectl: String, kubeconfig: String, context: String, cluster: String,
        namespace: String, kind: String, name: String, remotePort: Int, localPort: Int = 0
    ) -> UUID {
        let id = UUID()
        let forward = KubePortForward(
            id: id, cluster: cluster, namespace: namespace, kind: kind, name: name,
            remotePort: remotePort, localPort: localPort, state: .starting, startedAt: Date()
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kubectl)
        process.arguments = Self.arguments(
            kubeconfig: kubeconfig, context: context, namespace: namespace, kind: kind,
            name: name, remotePort: remotePort, localPort: localPort
        )
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in buffer.append(data) {
                self?.handle(line: line, id: id)
            }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.finished(id: id, status: finished.terminationStatus)
        }

        lock.lock()
        forwards[id] = forward
        order.append(id)
        processes[id] = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            update(id) { $0.state = .failed("Could not start kubectl. \(error.localizedDescription)") }
        }
        notify()
        return id
    }

    private func handle(line: String, id: UUID) {
        if let port = Self.localPort(fromLine: line) {
            update(id) { forward in
                forward.localPort = port
                forward.state = .running
            }
            notify()
        } else if line.lowercased().contains("error") || line.lowercased().contains("unable") {
            lock.lock(); lastErrors[id] = line; lock.unlock()
        }
    }

    private func finished(id: UUID, status: Int32) {
        lock.lock()
        let wasStopping = stopping.remove(id) != nil
        let message = lastErrors[id]
        processes[id] = nil
        lock.unlock()
        update(id) { forward in
            if wasStopping {
                forward.state = .stopped
            } else {
                forward.state = .failed(Self.friendly(message) ?? "kubectl stopped (exit \(status)).")
            }
        }
        notify()
    }

    static func friendly(_ line: String?) -> String? {
        guard let line else { return nil }
        let lower = line.lowercased()
        if lower.contains("address already in use") { return "That port is already in use on this Mac." }
        if lower.contains("not found") { return "The service or pod was not found." }
        if lower.contains("does not have any active pods") || lower.contains("no pods") { return "No running pod backs this service yet." }
        return line
    }

    public func stop(_ id: UUID) {
        lock.lock()
        let process = processes[id]
        if process != nil { stopping.insert(id) }
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        } else {
            update(id) { $0.state = .stopped }
            notify()
        }
    }

    /// Stops and forgets a forward.
    public func remove(_ id: UUID) {
        stop(id)
        lock.lock()
        forwards[id] = nil
        order.removeAll { $0 == id }
        lock.unlock()
        notify()
    }

    /// Stops every forward of a cluster, or all of them.
    public func stopAll(cluster: String? = nil) {
        for forward in all where forward.isActive && (cluster == nil || forward.cluster == cluster) {
            stop(forward.id)
        }
    }

    /// Stops everything and waits a moment. For app quit.
    public func stopAllBlocking() {
        lock.lock()
        let running = processes.values.filter(\.isRunning)
        lock.unlock()
        for process in running { process.terminate() }
        for process in running {
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline { usleep(20_000) }
        }
    }

    private func update(_ id: UUID, _ change: (inout KubePortForward) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var forward = forwards[id] else { return }
        change(&forward)
        forwards[id] = forward
    }

    private func notify() {
        let list = all
        onChange?(list)
    }
}
