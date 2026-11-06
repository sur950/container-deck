import XCTest
import Network
@testable import DeckCore

/// Runs the real proxy and relay on 127.0.0.1 against a tiny local origin server. No internet needed.
final class SandboxGatewayTests: XCTestCase {
    private var origin: NWListener?

    override func tearDown() {
        origin?.cancel()
        origin = nil
        super.tearDown()
    }

    /// Answers every connection with "HTTP/1.1 200 OK" and body "origin:<first line>".
    private func startOrigin() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                let firstLine = text.components(separatedBy: "\r\n").first ?? ""
                let body = "origin:\(firstLine)"
                let reply = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(reply.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        let ready = expectation(description: "origin ready")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 3)
        origin = listener
        return listener.port?.rawValue ?? 0
    }

    private func freePort() -> UInt16 {
        UInt16.random(in: 42000...48000)
    }

    /// Sends bytes to host:port and reads until the server closes.
    private func exchange(port: UInt16, send: String) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let box = ReplyBox()
        return try await withCheckedThrowingContinuation { continuation in
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                    if let data { box.append(data) }
                    if done || error != nil {
                        connection.cancel()
                        if box.claim() { continuation.resume(returning: box.text) }
                    } else {
                        read()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data(send.utf8), completion: .contentProcessed { _ in read() })
                case .failed(let error):
                    if box.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                connection.cancel()
                if box.claim() { continuation.resume(returning: box.text) }
            }
        }
    }

    func testProxyAllowsListedHostAndBlocksOthers() async throws {
        let originPort = try await startOrigin()
        let proxyPort = freePort()
        let events = EventBox()
        let gateway = SandboxGateway(bindHost: "127.0.0.1", proxyPort: proxyPort,
                                     policy: EgressPolicy(entries: ["127.0.0.1"]), relay: nil) { events.add($0) }
        try await gateway.start()
        defer { gateway.stop() }

        let allowed = try await exchange(port: proxyPort, send: "GET http://127.0.0.1:\(originPort)/hello?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nProxy-Connection: keep-alive\r\n\r\n")
        XCTAssertTrue(allowed.hasPrefix("HTTP/1.1 200 OK"), allowed)
        XCTAssertTrue(allowed.contains("origin:GET /hello?x=1 HTTP/1.1"), allowed)

        let tunnel = try await exchange(port: proxyPort, send: "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\n\r\nPING / HTTP/1.1\r\n\r\n")
        XCTAssertTrue(tunnel.hasPrefix("HTTP/1.1 200 Connection Established\r\n\r\n"), tunnel)
        XCTAssertTrue(tunnel.contains("origin:PING / HTTP/1.1"), tunnel)

        let blocked = try await exchange(port: proxyPort, send: "CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        XCTAssertTrue(blocked.hasPrefix("HTTP/1.1 403 Forbidden"), blocked)
        XCTAssertTrue(blocked.contains("example.com"))

        let bad = try await exchange(port: proxyPort, send: "GET /direct HTTP/1.1\r\n\r\n")
        XCTAssertTrue(bad.hasPrefix("HTTP/1.1 400"), bad)

        let kinds = events.all.map(\.kind)
        XCTAssertTrue(kinds.contains(.allowed))
        XCTAssertTrue(kinds.contains(.blocked))
    }

    func testRelayForwardsAndStopClosesEverything() async throws {
        let originPort = try await startOrigin()
        let relayPort = freePort() &+ 1
        let gateway = SandboxGateway(bindHost: "127.0.0.1", proxyPort: nil, policy: EgressPolicy(entries: []),
                                     relay: .init(port: relayPort, targetHost: "127.0.0.1", targetPort: Int(originPort)))
        try await gateway.start()
        let reply = try await exchange(port: relayPort, send: "POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(reply.contains("origin:POST /v1/chat/completions HTTP/1.1"), reply)

        gateway.stop()
        XCTAssertEqual(gateway.openConnections, 0)
        do {
            let after = try await exchange(port: relayPort, send: "GET / HTTP/1.1\r\n\r\n")
            XCTAssertFalse(after.contains("origin:"), "relay must be closed after stop")
        } catch {
            // Connection refused: what we want.
        }
    }

    func testBindFailsOnAddressThatIsNotOnThisMac() async {
        let gateway = SandboxGateway(bindHost: "10.255.255.254", proxyPort: freePort(), policy: EgressPolicy(entries: []), relay: nil)
        do {
            try await gateway.start(timeout: 2)
            gateway.stop()
            XCTFail("should not bind")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("10.255.255.254"))
        }
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var done = false
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SandboxEgressEvent] = []
    func add(_ event: SandboxEgressEvent) { lock.lock(); events.append(event); lock.unlock() }
    var all: [SandboxEgressEvent] { lock.lock(); defer { lock.unlock() }; return events }
}
