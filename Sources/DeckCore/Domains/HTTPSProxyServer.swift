import Foundation
import Network
@preconcurrency import Security

/// Local HTTPS proxy built on Network.framework.
///
/// How a request flows:
/// 1. The front listener (plain TCP, 127.0.0.1 only) reads the TLS ClientHello and the
///    server name (SNI) in it, without decrypting anything.
/// 2. It hands the bytes to a small TLS listener made for that one name, also on
///    127.0.0.1, which holds that name's own leaf certificate.
/// 3. That listener ends TLS and pipes the plain bytes to the container's IP and port.
///
/// So every name gets its own certificate, HTTP/1.1, WebSockets and server sent events
/// pass through untouched, and nothing listens beyond this Mac.
public final class HTTPSProxyServer: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var isRunning: Bool
        public var port: UInt16
        public var connections: Int
        public var requestsByHost: [String: Int]
        public var lastError: String?
    }

    public let host: String
    public let port: UInt16
    let authority: LocalCertificateAuthority
    private let queue = DispatchQueue(label: AppConfig.bundleID + ".proxy")

    // State below is only touched on `queue`.
    private var listener: NWListener?
    private var routes: [ProxyRoute] = []
    private var terminators: [String: Terminator] = [:]
    private var pendingTerminators: [String: [(Result<UInt16, Error>) -> Void]] = [:]
    private var liveBridges: [ObjectIdentifier: Bridge] = [:]
    private var requests: [String: Int] = [:]
    private var lastError: String?
    private var running = false

    public init(host: String = DomainsConfig.listenHost, port: UInt16 = DomainsConfig.defaultProxyPort, authority: LocalCertificateAuthority) {
        self.host = host
        self.port = port
        self.authority = authority
    }

    // MARK: - Control

    /// Starts listening. Returns once the port is open, throws when it cannot be.
    public func start(routes: [ProxyRoute]) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw DeckError.commandFailed("Port \(port) is not valid.") }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let listener = try NWListener(using: parameters)
        let portNumber = port
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: DeckError.commandFailed("The proxy stopped."))
                    return
                }
                self.stopLocked()
                self.routes = routes
                self.listener = listener
                var resumed = false
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.running = true
                        if !resumed { resumed = true; continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        let message = Self.describe(error, port: portNumber)
                        self?.lastError = message
                        self?.running = false
                        listener.cancel()
                        if !resumed { resumed = true; continuation.resume(throwing: DeckError.commandFailed(message)) }
                    case .cancelled:
                        self?.running = false
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.queue)
            }
        }
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    /// New route table. Open connections keep their current target.
    public func update(routes: [ProxyRoute]) {
        queue.async { self.routes = routes }
    }

    public func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(isRunning: running, port: port, connections: liveBridges.count, requestsByHost: requests, lastError: lastError)
        }
    }

    /// Forgets cached listeners, for example after the CA was made again.
    public func resetCertificates() {
        queue.async {
            self.terminators.values.forEach { $0.listener.cancel() }
            self.terminators = [:]
        }
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        running = false
        terminators.values.forEach { $0.listener.cancel() }
        terminators = [:]
        liveBridges.values.forEach { $0.cancel() }
        liveBridges = [:]
    }

    static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error {
            if code == .EADDRINUSE { return "Port \(port) is already in use by another app." }
            if code == .EACCES { return "Port \(port) needs admin rights. Use a port above 1024." }
        }
        return "The proxy could not listen on port \(port). \(error.localizedDescription)"
    }

    // MARK: - Front door

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHello(connection, buffer: Data())
    }

    private func readHello(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: TLSClientHello.maximumLength) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch TLSClientHello.parse(buffer) {
            case .needMoreData:
                if isComplete || error != nil || buffer.count >= TLSClientHello.maximumLength {
                    connection.cancel()
                } else {
                    self.readHello(connection, buffer: buffer)
                }
            case .notTLS:
                self.replyPlainHTTP(connection)
            case .noServerName:
                connection.cancel()
            case .serverName(let name):
                self.route(connection, name: name, hello: buffer)
            }
        }
    }

    /// Someone typed http:// instead of https://. Say so instead of hanging up.
    private func replyPlainHTTP(_ connection: NWConnection) {
        let body = "This is the \(AppConfig.appName) HTTPS proxy. Use https:// in the address.\n"
        let response = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func route(_ connection: NWConnection, name: String, hello: Data) {
        guard RoutePlanner.match(host: name, in: routes) != nil else {
            connection.cancel()
            return
        }
        requests[name, default: 0] += 1
        terminatorPort(for: name) { [weak self] result in
            guard let self else { connection.cancel(); return }
            switch result {
            case .failure(let error):
                self.lastError = error.localizedDescription
                connection.cancel()
            case .success(let port):
                let inner = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
                inner.start(queue: self.queue)
                inner.send(content: hello, completion: .contentProcessed { _ in })
                self.bridge(connection, inner)
            }
        }
    }

    // MARK: - Per name TLS listeners

    private final class Terminator {
        let listener: NWListener
        var port: UInt16
        init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }
    }

    /// Runs on `queue`. Makes the listener for a name once, then reuses it.
    private func terminatorPort(for name: String, completion: @escaping (Result<UInt16, Error>) -> Void) {
        if let existing = terminators[name], existing.port != 0 {
            completion(.success(existing.port))
            return
        }
        if pendingTerminators[name] != nil {
            pendingTerminators[name]?.append(completion)
            return
        }
        pendingTerminators[name] = [completion]
        let authority = self.authority
        Task {
            let result: Result<SecIdentity, Error>
            do { result = .success(try await authority.identity(for: name)) } catch { result = .failure(error) }
            self.queue.async { self.finishTerminator(name: name, identity: result) }
        }
    }

    private func finishTerminator(name: String, identity: Result<SecIdentity, Error>) {
        let waiters = pendingTerminators.removeValue(forKey: name) ?? []
        func finish(_ result: Result<UInt16, Error>) { waiters.forEach { $0(result) } }
        let secIdentity: SecIdentity
        switch identity {
        case .failure(let error): finish(.failure(error)); return
        case .success(let value): secIdentity = value
        }
        guard running else { finish(.failure(DeckError.commandFailed("The proxy stopped."))); return }
        do {
            let listener = try NWListener(using: Self.tlsParameters(identity: secIdentity))
            let terminator = Terminator(listener: listener, port: 0)
            var done = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    terminator.port = listener.port?.rawValue ?? 0
                    self?.terminators[name] = terminator
                    if !done { done = true; finish(.success(terminator.port)) }
                case .failed(let error):
                    self?.terminators[name] = nil
                    if !done { done = true; finish(.failure(error)) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptDecrypted(connection, name: name)
            }
            listener.start(queue: queue)
        } catch {
            finish(.failure(error))
        }
    }

    static func tlsParameters(identity: SecIdentity) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(options, secIdentity)
        }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        // Bytes are piped as is, so only offer HTTP/1.1 (no HTTP/2 framing to translate).
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return parameters
    }

    private func acceptDecrypted(_ inbound: NWConnection, name: String) {
        guard let route = RoutePlanner.match(host: name, in: routes), let target = route.targetHost, route.isRunning,
              let port = NWEndpoint.Port(rawValue: UInt16(clamping: route.targetPort)) else {
            inbound.start(queue: queue)
            replyError(inbound, status: "503 Service Unavailable", message: "\(name) is not running.")
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        let upstream = NWConnection(host: NWEndpoint.Host(target), port: port, using: NWParameters(tls: nil, tcp: tcp))
        var decided = false
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self, !decided else { return }
            switch state {
            case .ready:
                decided = true
                self.bridge(inbound, upstream)
            case .failed, .waiting:
                decided = true
                upstream.cancel()
                self.replyError(inbound, status: "502 Bad Gateway", message: "Could not reach \(route.container) at \(route.target).")
            default:
                break
            }
        }
        inbound.start(queue: queue)
        upstream.start(queue: queue)
    }

    private func replyError(_ connection: NWConnection, status: String, message: String) {
        // Read the request first so the browser sees the answer, then close.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
            let body = "\(message)\n\n\(AppConfig.appName) HTTPS proxy\n"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    // MARK: - Byte pipe

    private func bridge(_ a: NWConnection, _ b: NWConnection) {
        let bridge = Bridge(a, b)
        let key = ObjectIdentifier(bridge)
        liveBridges[key] = bridge
        bridge.onClose = { [weak self] in self?.liveBridges[key] = nil }
        bridge.start()
    }

    /// Copies bytes both ways until both sides are done. Runs on the proxy queue.
    final class Bridge {
        let a: NWConnection
        let b: NWConnection
        var onClose: (() -> Void)?
        private var finished = 0
        private var cancelled = false

        init(_ a: NWConnection, _ b: NWConnection) {
            self.a = a
            self.b = b
        }

        func start() {
            for connection in [a, b] {
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed, .cancelled: self?.cancel()
                    default: break
                    }
                }
            }
            pump(from: a, to: b)
            pump(from: b, to: a)
        }

        private func pump(from source: NWConnection, to sink: NWConnection) {
            source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self, !self.cancelled else { return }
                if let data, !data.isEmpty {
                    sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                        guard let self else { return }
                        if sendError != nil { self.cancel(); return }
                        if isComplete { self.finish(sink) } else { self.pump(from: source, to: sink) }
                    })
                } else if isComplete {
                    self.finish(sink)
                } else if error != nil {
                    self.cancel()
                } else {
                    self.pump(from: source, to: sink)
                }
            }
        }

        private func finish(_ sink: NWConnection) {
            sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            finished += 1
            if finished >= 2 { cancel() }
        }

        func cancel() {
            guard !cancelled else { return }
            cancelled = true
            a.cancel()
            b.cancel()
            onClose?()
            onClose = nil
        }
    }
}
