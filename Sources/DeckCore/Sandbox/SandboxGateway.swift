import Foundation
import Network

/// One thing the sandbox network did: a host let through, a host blocked, or a model call relayed.
public struct SandboxEgressEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case allowed, blocked, relay, failed
    }

    public var id = UUID()
    public var date: Date
    public var kind: Kind
    public var host: String
    public var port: Int
    public var detail: String

    public init(date: Date = Date(), kind: Kind, host: String, port: Int, detail: String = "") {
        self.date = date
        self.kind = kind
        self.host = host
        self.port = port
        self.detail = detail
    }
}

/// Network services the app runs for one sandbox, bound only to the sandbox's gateway
/// address on this Mac (never on other interfaces):
///
/// - Allow list proxy: a forward HTTP proxy that understands `CONNECT` (HTTPS) and absolute
///   `http://` requests and lets through only hosts in the `EgressPolicy`.
/// - Model relay: plain TCP from `gateway:relayPort` to a model server (usually on 127.0.0.1).
///
/// `stop()` closes the listeners and every open connection at once (the kill switch).
public final class SandboxGateway: @unchecked Sendable {
    public struct Relay: Sendable, Hashable {
        public var port: UInt16
        public var targetHost: String
        public var targetPort: Int

        public init(port: UInt16, targetHost: String, targetPort: Int) {
            self.port = port
            self.targetHost = targetHost
            self.targetPort = targetPort
        }
    }

    public enum GatewayError: LocalizedError {
        case bindFailed(String, String)
        case timedOut(String)

        public var errorDescription: String? {
            switch self {
            case .bindFailed(let address, let reason): return "Could not listen on \(address). \(reason)"
            case .timedOut(let address): return "Could not listen on \(address) in time."
            }
        }
    }

    public let bindHost: String
    public let proxyPort: UInt16?
    public let relay: Relay?
    public let policy: EgressPolicy

    private let queue: DispatchQueue
    private let onEvent: @Sendable (SandboxEgressEvent) -> Void
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false

    /// - Parameters:
    ///   - bindHost: the sandbox network gateway, like 192.168.128.1.
    ///   - proxyPort: port of the allow list proxy. nil runs no proxy.
    ///   - relay: model relay. nil runs no relay.
    public init(bindHost: String, proxyPort: UInt16?, policy: EgressPolicy, relay: Relay?,
                onEvent: @escaping @Sendable (SandboxEgressEvent) -> Void = { _ in }) {
        self.bindHost = bindHost
        self.proxyPort = proxyPort
        self.relay = relay
        self.policy = policy
        self.onEvent = onEvent
        self.queue = DispatchQueue(label: "\(AppConfig.bundleID).sandbox-gateway.\(bindHost)")
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        // No queue hop here: deinit can run on the queue itself (last reference dropped in a callback).
        for listener in listeners { listener.cancel() }
        for connection in connections.values { connection.forceCancel() }
    }

    /// Opens the listeners. Throws when one cannot bind (for example the gateway
    /// interface is not up yet because the container is not running).
    public func start(timeout: TimeInterval = 3) async throws {
        if let proxyPort {
            try await listen(port: proxyPort, timeout: timeout) { [weak self] connection in self?.handleProxy(connection) }
        }
        if let relay {
            do {
                try await listen(port: relay.port, timeout: timeout) { [weak self] connection in self?.handleRelay(connection, relay: relay) }
            } catch {
                stop()
                throw error
            }
        }
    }

    /// Closes everything now. Safe to call more than once.
    public func stop() {
        onQueue {
            stopped = true
            for listener in listeners { listener.cancel() }
            listeners.removeAll()
            for connection in connections.values { connection.forceCancel() }
            connections.removeAll()
        }
    }

    /// Open client and upstream connections (for tests and the UI).
    public var openConnections: Int {
        onQueue { connections.count }
    }

    private let queueKey = DispatchSpecificKey<Bool>()

    private func onQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return work() }
        return queue.sync(execute: work)
    }

    // MARK: - Listening

    private func listen(port: UInt16, timeout: TimeInterval, handler: @escaping @Sendable (NWConnection) -> Void) async throws {
        let address = "\(bindHost):\(port)"
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw GatewayError.bindFailed(address, "Bad port.") }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost), port: nwPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw GatewayError.bindFailed(address, error.localizedDescription)
        }
        listener.newConnectionHandler = handler
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() {
                        listener.cancel()
                        continuation.resume(throwing: GatewayError.bindFailed(address, error.localizedDescription))
                    }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: GatewayError.bindFailed(address, "Stopped.")) }
                default:
                    break
                }
            }
            queue.async {
                if self.stopped {
                    if once.claim() { continuation.resume(throwing: GatewayError.bindFailed(address, "Stopped.")) }
                    return
                }
                self.listeners.append(listener)
                listener.start(queue: self.queue)
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    listener.cancel()
                    continuation.resume(throwing: GatewayError.timedOut(address))
                }
            }
        }
    }

    // MARK: - Connection bookkeeping (on queue)

    private func track(_ connection: NWConnection) -> Bool {
        guard !stopped else {
            connection.forceCancel()
            return false
        }
        connections[ObjectIdentifier(connection)] = connection
        return true
    }

    private func close(_ items: NWConnection...) {
        for connection in items {
            connections.removeValue(forKey: ObjectIdentifier(connection))
            connection.cancel()
        }
    }

    private func emit(_ kind: SandboxEgressEvent.Kind, _ host: String, _ port: Int, _ detail: String = "") {
        onEvent(SandboxEgressEvent(kind: kind, host: host, port: port, detail: detail))
    }

    // MARK: - Proxy

    private func handleProxy(_ client: NWConnection) {
        guard track(client) else { return }
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(client)
            default: break
            }
        }
        client.start(queue: queue)
        watchFirewall(client)
        readHead(client, buffer: Data())
    }

    private func readHead(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch ProxyRequest.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    self.close(client)
                } else {
                    self.readHead(client, buffer: buffer)
                }
            case .invalid(let status, let reason):
                self.reply(client, ProxyRequest.response(status, reason, body: reason + "\n"))
            case .request(let request):
                let rest = buffer.count > request.headLength ? Data(buffer.suffix(from: buffer.startIndex + request.headLength)) : Data()
                self.forward(request, from: client, leftover: rest)
            }
        }
    }

    private func forward(_ request: ProxyRequest, from client: NWConnection, leftover: Data) {
        guard policy.allows(host: request.host, port: request.port) else {
            emit(.blocked, request.host, request.port, request.kind == .tunnel ? "CONNECT" : request.method)
            let body = "Blocked by the \(AppConfig.appName) sandbox allow list: \(request.host)\n"
            reply(client, ProxyRequest.response(403, "Forbidden", body: body))
            return
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: request.port)) else {
            reply(client, ProxyRequest.response(400, "Bad Request", body: "Bad port\n"))
            return
        }
        let upstream = NWConnection(host: NWEndpoint.Host(request.host), port: port, using: .tcp)
        guard track(upstream) else {
            close(client)
            return
        }
        var opened = false
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !opened else { return }
                opened = true
                self.emit(.allowed, request.host, request.port, request.kind == .tunnel ? "CONNECT" : request.method)
                let first: Data
                switch request.kind {
                case .tunnel:
                    client.send(content: ProxyRequest.response(200, "Connection Established"), completion: .contentProcessed { _ in })
                    first = leftover
                case .http:
                    first = request.originHead() + leftover
                }
                if !first.isEmpty {
                    upstream.send(content: first, completion: .contentProcessed { _ in })
                }
                self.pipe(from: client, to: upstream)
                self.pipe(from: upstream, to: client)
            case .waiting(let error), .failed(let error):
                guard !opened else {
                    self.close(client, upstream)
                    return
                }
                opened = true
                self.emit(.failed, request.host, request.port, error.localizedDescription)
                self.connections.removeValue(forKey: ObjectIdentifier(upstream))
                upstream.cancel()
                self.reply(client, ProxyRequest.response(502, "Bad Gateway", body: "Could not reach \(request.host)\n"))
            case .cancelled:
                self.close(client, upstream)
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    /// Sends a response and closes the client.
    private func reply(_ client: NWConnection, _ data: Data) {
        client.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 0.2) { self?.close(client) }
        })
    }

    // MARK: - Relay

    private func handleRelay(_ client: NWConnection, relay: Relay) {
        guard track(client),
              let port = NWEndpoint.Port(rawValue: UInt16(clamping: relay.targetPort)) else {
            client.cancel()
            return
        }
        let upstream = NWConnection(host: NWEndpoint.Host(relay.targetHost), port: port, using: .tcp)
        guard track(upstream) else {
            close(client)
            return
        }
        var opened = false
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !opened else { return }
                opened = true
                self.emit(.relay, relay.targetHost, relay.targetPort, "Model")
                self.pipe(from: client, to: upstream)
                self.pipe(from: upstream, to: client)
            case .waiting(let error), .failed(let error):
                if !opened {
                    opened = true
                    self.emit(.failed, relay.targetHost, relay.targetPort, error.localizedDescription)
                }
                self.close(client, upstream)
            case .cancelled:
                self.close(client, upstream)
            default:
                break
            }
        }
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(client, upstream)
            default: break
            }
        }
        client.start(queue: queue)
        watchFirewall(client)
        upstream.start(queue: queue)
    }

    /// The host that marks "held by the macOS firewall" events.
    public static let firewallHost = "macOS firewall"

    /// An accepted connection that never gets ready is held by the application firewall,
    /// which asks once whether the app may accept incoming connections.
    private func watchFirewall(_ client: NWConnection) {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.stopped, case .preparing = client.state else { return }
            self.emit(.failed, Self.firewallHost, 0, "Allow \(AppConfig.appName) to accept incoming connections")
        }
    }

    // MARK: - Piping

    private func pipe(from source: NWConnection, to target: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                target.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil {
                        self.close(source, target)
                    } else if isComplete {
                        self.finish(target, then: source)
                    } else if error == nil {
                        self.pipe(from: source, to: target)
                    } else {
                        self.close(source, target)
                    }
                })
            } else if isComplete {
                self.finish(target, then: source)
            } else if error != nil {
                self.close(source, target)
            } else {
                self.pipe(from: source, to: target)
            }
        }
    }

    /// One side finished sending: pass the end on, then close both.
    private func finish(_ target: NWConnection, then source: NWConnection) {
        target.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 0.1) { self?.close(source, target) }
        })
    }
}

/// Resumes a continuation only once, whichever callback comes first.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

