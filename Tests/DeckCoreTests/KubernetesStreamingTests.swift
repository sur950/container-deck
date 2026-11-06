import XCTest
import Network
import Security
@testable import DeckCore

// Streaming reads for Kubernetes (pod logs with follow): the HTTP/1.1 decoder, line
// splitting, reconnect, and the Network.framework connection with a throwaway CA,
// server certificate and client certificate against a local TLS server.

private func chunk(_ text: String) -> Data {
    let body = Data(text.utf8)
    return Data((String(body.count, radix: 16) + "\r\n").utf8) + body + Data("\r\n".utf8)
}

private let chunkedHead = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n"
private let lastChunk = Data("0\r\n\r\n".utf8)

/// Feeds the bytes in pieces of `size` and collects body text and events.
private func decode(_ data: Data, pieces size: Int) throws -> (head: KubeHTTPHead?, body: String, ended: Bool) {
    var decoder = KubeHTTPDecoder()
    var head: KubeHTTPHead?
    var body = Data()
    var ended = false
    var index = 0
    while index < data.count {
        let end = min(index + size, data.count)
        for event in try decoder.feed(data.subdata(in: index..<end)) {
            switch event {
            case .head(let value): head = value
            case .body(let part): body.append(part)
            case .end: ended = true
            }
        }
        index = end
    }
    if !ended {
        for event in try decoder.finish() where event == .end { ended = true }
    }
    return (head, String(decoding: body, as: UTF8.self), ended)
}

final class KubeHTTPDecoderTests: XCTestCase {

    func testChunkedInAnySplit() throws {
        var data = Data(chunkedHead.utf8)
        data += chunk("first line\n")
        data += chunk("sec")
        data += chunk("ond line\n")
        data += Data("5;name=value\r\nthird\r\n".utf8) // chunk extension
        data += lastChunk
        for size in [1, 2, 3, 7, 16, 1000] {
            let result = try decode(data, pieces: size)
            XCTAssertEqual(result.head?.status, 200, "size \(size)")
            XCTAssertEqual(result.head?.headers["transfer-encoding"], "chunked")
            XCTAssertEqual(result.body, "first line\nsecond line\nthird", "size \(size)")
            XCTAssertTrue(result.ended, "size \(size)")
        }
    }

    func testBodyIsHandedOnBeforeTheChunkEnds() throws {
        var decoder = KubeHTTPDecoder()
        _ = try decoder.feed(Data(chunkedHead.utf8))
        // Only part of a 20 byte chunk has arrived. It is handed on right away.
        let events = try decoder.feed(Data("14\r\nhello".utf8))
        XCTAssertEqual(events, [.body(Data("hello".utf8))])
    }

    func testTrailersAndLowercaseHeaders() throws {
        let data = Data("HTTP/1.1 200 OK\r\nTRANSFER-ENCODING: Chunked\r\nX-A: 1\r\nX-A: 2\r\n\r\n".utf8)
            + chunk("ok") + Data("0\r\nX-Trailer: yes\r\n\r\n".utf8)
        let result = try decode(data, pieces: 4)
        XCTAssertEqual(result.body, "ok")
        XCTAssertEqual(result.head?.headers["x-a"], "1, 2")
        XCTAssertTrue(result.ended)
    }

    func testContentLengthAndUntilClose() throws {
        let fixed = Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 5\r\n\r\nnope!extra".utf8)
        let result = try decode(fixed, pieces: 3)
        XCTAssertEqual(result.head?.status, 403)
        XCTAssertFalse(result.head?.isSuccess ?? true)
        XCTAssertEqual(result.body, "nope!")
        XCTAssertTrue(result.ended)

        let open = Data("HTTP/1.1 200 OK\r\n\r\nall of it".utf8)
        let untilClose = try decode(open, pieces: 2)
        XCTAssertEqual(untilClose.body, "all of it")
        XCTAssertTrue(untilClose.ended, "a body without a length ends at close")

        let empty = try decode(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8), pieces: 100)
        XCTAssertEqual(empty.body, "")
        XCTAssertTrue(empty.ended)
    }

    func testContinueIsSkipped() throws {
        let data = Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi".utf8)
        let result = try decode(data, pieces: 5)
        XCTAssertEqual(result.head?.status, 200)
        XCTAssertEqual(result.body, "hi")
    }

    func testEarlyCloseIsTruncated() throws {
        var decoder = KubeHTTPDecoder()
        _ = try decoder.feed(Data(chunkedHead.utf8) + chunk("line\n") + Data("a\r\nabc".utf8))
        XCTAssertThrowsError(try decoder.finish()) { error in
            XCTAssertEqual(error as? KubeStreamError, .truncated)
        }
        var noHead = KubeHTTPDecoder()
        _ = try noHead.feed(Data("HTTP/1.1 200".utf8))
        XCTAssertThrowsError(try noHead.finish())
    }

    func testMalformedReplies() {
        var decoder = KubeHTTPDecoder()
        XCTAssertThrowsError(try decoder.feed(Data("SSH-2.0-OpenSSH\r\n\r\n".utf8)))
        var badSize = KubeHTTPDecoder()
        XCTAssertThrowsError(try badSize.feed(Data(chunkedHead.utf8) + Data("zz\r\n".utf8)))
        var badEnd = KubeHTTPDecoder()
        XCTAssertThrowsError(try badEnd.feed(Data(chunkedHead.utf8) + Data("2\r\nabXY".utf8)))
    }
}

final class KubeLineSplitterTests: XCTestCase {

    func testLinesSplitAcrossChunks() {
        var splitter = KubeLineSplitter()
        XCTAssertEqual(splitter.feed(Data("one\ntw".utf8)), ["one"])
        XCTAssertEqual(splitter.feed(Data("o".utf8)), [])
        XCTAssertEqual(splitter.feed(Data("\r\nthree\n\nfour".utf8)), ["two", "three", ""])
        XCTAssertEqual(splitter.flush(), "four")
        XCTAssertNil(splitter.flush())
    }

    func testMultiByteCharacterSplitAcrossChunks() {
        var splitter = KubeLineSplitter()
        let bytes = Array("héllo ✓\n".utf8)
        var lines: [String] = []
        for byte in bytes { lines += splitter.feed(Data([byte])) }
        XCTAssertEqual(lines, ["héllo ✓"])
    }
}

final class KubeLogFollowerTests: XCTestCase {

    func testTimestampSplit() {
        XCTAssertEqual(KubeLogFollower.split("2026-11-06T05:04:56.099105123Z hello world").text, "hello world")
        XCTAssertEqual(KubeLogFollower.split("2026-11-06T05:04:56.099105123Z hello world").stamp, "2026-11-06T05:04:56.099105123Z")
        XCTAssertNil(KubeLogFollower.split("plain line").stamp)
        XCTAssertEqual(KubeLogFollower.split("plain line").text, "plain line")
        XCTAssertEqual(KubeLogFollower.split("2026-11-06T05:04:56Z ").text, "")
        XCTAssertEqual(KubeLogFollower.normalized("2026-11-06T05:04:56.1Z"), "2026-11-06T05:04:56.100000000Z")
        XCTAssertEqual(KubeLogFollower.normalized("2026-11-06T05:04:56Z"), "2026-11-06T05:04:56.000000000Z")
        XCTAssertNil(KubeLogFollower.normalized("2026-11-06 05:04:56Z"))
        // Text order of normalized stamps is time order. Raw stamps are not ("56Z" sorts after "56.1Z").
        XCTAssertLessThan(KubeLogFollower.normalized("2026-11-06T05:04:56Z")!, KubeLogFollower.normalized("2026-11-06T05:04:56.1Z")!)
        XCTAssertGreaterThan("2026-11-06T05:04:56Z", "2026-11-06T05:04:56.1Z")
    }

    func testRetryableErrors() {
        XCTAssertTrue(KubeLogFollower.isRetryable(KubeStreamError.truncated))
        XCTAssertTrue(KubeLogFollower.isRetryable(KubeAPIError.unreachable("reset")))
        XCTAssertFalse(KubeLogFollower.isRetryable(KubeAPIError.http(404, nil)))
        XCTAssertFalse(KubeLogFollower.isRetryable(KubeStreamError.malformed("x")))
    }

    func testReconnectsWithSinceTimeAndSkipsShownLines() async throws {
        let opened = KubeRecorder<String?>()
        let stream = KubeLogFollower.follow(delay: { _ in }) { since in
            opened.add(since)
            return AsyncThrowingStream { continuation in
                switch opened.count {
                case 1:
                    continuation.yield("2026-11-06T05:00:01.5Z one")
                    continuation.yield("2026-11-06T05:00:02.25Z two")
                    continuation.yield("2026-11-06T05:00:02.25Z two again")
                    continuation.finish(throwing: KubeStreamError.truncated)
                case 2:
                    // sinceTime is inclusive, so the server repeats the last second.
                    continuation.yield("2026-11-06T05:00:01.5Z one")
                    continuation.yield("2026-11-06T05:00:02.25Z two")
                    continuation.yield("2026-11-06T05:00:02.25Z two again")
                    continuation.yield("2026-11-06T05:00:02.25Z two more")
                    continuation.yield("2026-11-06T05:00:03Z three")
                    continuation.finish(throwing: KubeAPIError.unreachable("connection reset"))
                default:
                    continuation.yield("2026-11-06T05:00:04Z four")
                    continuation.finish()
                }
            }
        }
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        XCTAssertEqual(lines, ["one", "two", "two again", "two more", "three", "four"])
        XCTAssertEqual(opened.values, [nil, "2026-11-06T05:00:02.25Z", "2026-11-06T05:00:03Z"])
    }

    func testGivesUpAfterRetriesAndStopsOnHTTPErrors() async {
        let opened = KubeRecorder<String?>()
        let failing = KubeLogFollower.follow(maxRetries: 2, delay: { _ in }) { since in
            opened.add(since)
            return AsyncThrowingStream { $0.finish(throwing: KubeAPIError.unreachable("refused")) }
        }
        do {
            for try await _ in failing {}
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? KubeAPIError, .unreachable("refused"))
        }
        XCTAssertEqual(opened.count, 3, "the first try and two more")

        let forbidden = KubeLogFollower.follow(delay: { _ in }) { _ in
            AsyncThrowingStream { $0.finish(throwing: KubeAPIError.http(403, "no")) }
        }
        do {
            for try await _ in forbidden {}
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? KubeAPIError, .http(403, "no"))
        }
    }

    func testCleanEndDoesNotReconnect() async throws {
        let opened = KubeRecorder<String?>()
        let stream = KubeLogFollower.follow(delay: { _ in }) { since in
            opened.add(since)
            return AsyncThrowingStream { continuation in
                continuation.yield("no stamp here")
                continuation.finish()
            }
        }
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        XCTAssertEqual(lines, ["no stamp here"])
        XCTAssertEqual(opened.count, 1)
    }

    func testRequestBytes() throws {
        let client = KubeAPIClient(server: URL(string: "https://127.0.0.1:6445")!, token: "secret", transport: MockKubeTransport())
        let request = client.logRequest(namespace: "default", pod: "web 1", container: "nginx", follow: true, tail: nil, sinceTime: "2026-11-06T05:00:02.25Z", timestamps: true)
        let text = String(decoding: try XCTUnwrap(KubeHTTPStream.requestData(request)), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        XCTAssertTrue(lines[0].hasPrefix("GET /api/v1/namespaces/default/pods/web%201/log?container=nginx&follow=true&sinceTime=2026-11-06T05:00:02.25Z&timestamps=true HTTP/1.1"), lines[0])
        XCTAssertTrue(lines.contains("Host: 127.0.0.1:6445"))
        XCTAssertTrue(lines.contains("Authorization: Bearer secret"))
        XCTAssertTrue(lines.contains("Accept: */*"))
        XCTAssertTrue(lines.contains("Connection: close"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(text.contains("tailLines"), "a reconnect asks from the last time, not for the tail again")
    }
}

/// Thread safe list for test closures.
final class KubeRecorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { values.count }
}

// MARK: - TLS against a local server

/// Throwaway CA, server certificate for 127.0.0.1 and client certificate, made with /usr/bin/openssl.
struct ThrowawayPKI {
    let caDER: Data
    let caPEM: Data
    let serverCert: Data
    let serverKey: Data
    let clientCert: Data
    let clientKey: Data

    static func make(name: String = "kubernetes") throws -> ThrowawayPKI {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deck-k8s-pki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func run(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = args
            process.currentDirectoryURL = folder
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("openssl failed: \(args)") }
        }
        try write("ca.ext", "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n")
        try write("server.ext", "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n")
        try write("client.ext", "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n")
        try run(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.csr", "-subj", "/CN=\(name)"])
        try run(["x509", "-req", "-in", "ca.csr", "-signkey", "ca.key", "-out", "ca.crt", "-days", "2", "-extfile", "ca.ext"])
        try run(["x509", "-in", "ca.crt", "-outform", "DER", "-out", "ca.der"])
        try run(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key", "-out", "server.csr", "-subj", "/CN=kube-apiserver"])
        try run(["x509", "-req", "-in", "server.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial", "-out", "server.crt", "-days", "2", "-extfile", "server.ext"])
        try run(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "client.key", "-out", "client.csr", "-subj", "/O=kubeadm:cluster-admins/CN=kubernetes-admin"])
        try run(["x509", "-req", "-in", "client.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial", "-out", "client.crt", "-days", "2", "-extfile", "client.ext"])
        func read(_ name: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(name)) }
        return ThrowawayPKI(
            caDER: try read("ca.der"), caPEM: try read("ca.crt"),
            serverCert: try read("server.crt"), serverKey: try read("server.key"),
            clientCert: try read("client.crt"), clientKey: try read("client.key")
        )
    }
}

/// A TLS server on 127.0.0.1 that asks for a client certificate and answers each
/// connection with a scripted list of writes.
final class LocalTLSServer: @unchecked Sendable {
    struct Write {
        var after: TimeInterval
        var data: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "deck-test-tls-server")
    private let lock = NSLock()
    private var _requests: [String] = []
    private var _sentAt: [[Date]] = []
    private let certificates = KubeRecorder<Bool>()
    private var connections: [NWConnection] = []
    private let script: @Sendable (Int, String) -> [Write]

    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
    var sentAt: [[Date]] { lock.lock(); defer { lock.unlock() }; return _sentAt }
    var clientCertificates: Int { certificates.count }
    private(set) var port: UInt16 = 0

    init(pki: ThrowawayPKI, script: @escaping @Sendable (Int, String) -> [Write]) async throws {
        self.script = script
        let p12 = try await KubeTLS.pkcs12(certificatePEM: pki.serverCert, keyPEM: pki.serverKey, runner: ProcessRunner(), openssl: "/usr/bin/openssl")
        let identity = try KubeTLS.importIdentity(p12.data, passphrase: p12.passphrase)
        let ca = try XCTUnwrap(SecCertificateCreateWithData(nil, pki.caDER as CFData))
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        sec_protocol_options_set_local_identity(sec, try XCTUnwrap(sec_identity_create(identity)))
        sec_protocol_options_set_peer_authentication_required(sec, true)
        let queue = self.queue
        let certificates = self.certificates
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(secTrust, SecPolicyCreateBasicX509())
            SecTrustSetAnchorCertificates(secTrust, [ca] as CFArray)
            SecTrustSetAnchorCertificatesOnly(secTrust, true)
            let ok = SecTrustEvaluateWithError(secTrust, nil)
            if ok { certificates.add(true) }
            complete(ok)
        }, queue)
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { [weak listener] state in
                if case .ready = state { continuation.yield(listener?.port?.rawValue ?? 0); continuation.finish() }
                if case .failed = state { continuation.yield(0); continuation.finish() }
            }
        }
        listener.start(queue: queue)
        for await value in ready { port = value }
        guard port != 0 else { throw XCTSkip("Could not listen on 127.0.0.1") }
    }

    func stop() {
        listener.cancel()
        lock.lock(); let open = connections; lock.unlock()
        open.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { connection.cancel(); return }
            let all = buffer + data
            guard let text = String(data: all, encoding: .utf8), text.contains("\r\n\r\n") else {
                self.readRequest(connection, buffer: all)
                return
            }
            self.lock.lock()
            self._requests.append(text)
            let index = self._requests.count - 1
            self._sentAt.append([])
            self.lock.unlock()
            self.send(self.script(index, text), on: connection, index: index)
        }
    }

    private func send(_ writes: [Write], on connection: NWConnection, index: Int) {
        guard let first = writes.first else {
            connection.cancel()
            return
        }
        queue.asyncAfter(deadline: .now() + first.after) { [weak self] in
            connection.send(content: first.data, completion: .contentProcessed { _ in
                guard let self else { return }
                self.lock.lock(); self._sentAt[index].append(Date()); self.lock.unlock()
                self.send(Array(writes.dropFirst()), on: connection, index: index)
            })
        }
    }
}

final class KubeHTTPStreamTLSTests: XCTestCase {

    private func credentials(_ pki: ThrowawayPKI, port: UInt16, withClient: Bool = true) -> KubeConfigFile.Credentials {
        KubeConfigFile.Credentials(
            server: URL(string: "https://127.0.0.1:\(port)")!,
            certificateAuthority: pki.caDER,
            clientCertificatePEM: withClient ? pki.clientCert : nil,
            clientKeyPEM: withClient ? pki.clientKey : nil
        )
    }

    /// The server sends a short first line (well under 512 bytes), waits, then the next
    /// line split over two chunks. Each line must arrive before the next one is sent.
    func testLinesArriveAsSoonAsTheyAreSent() async throws {
        let pki = try ThrowawayPKI.make()
        let server = try await LocalTLSServer(pki: pki) { _, _ in [
            .init(after: 0, data: Data(chunkedHead.utf8) + chunk("2026-11-06T05:00:01.1Z first line\n")),
            .init(after: 0.6, data: chunk("2026-11-06T05:00:02.2Z sec")),
            .init(after: 0.05, data: chunk("ond line\n")),
            .init(after: 0.6, data: chunk("2026-11-06T05:00:03.3Z third\n") + lastChunk),
        ] }
        defer { server.stop() }
        let tls = try await KubeTLS.make(credentials(pki, port: server.port))
        let api = KubeAPIClient(server: URL(string: "https://127.0.0.1:\(server.port)")!, transport: URLSessionKubeTransport(tls: tls))

        var lines: [String] = []
        var arrivals: [Date] = []
        for try await line in api.podLogs(namespace: "default", pod: "ticker", follow: true, tail: 10) {
            lines.append(line)
            arrivals.append(Date())
        }
        XCTAssertEqual(lines, ["first line", "second line", "third"])
        XCTAssertEqual(server.clientCertificates, 1, "the client certificate from the kubeconfig was presented")
        let sent = try XCTUnwrap(server.sentAt.first)
        XCTAssertEqual(sent.count, 4)
        XCTAssertLessThan(arrivals[0], sent[1], "the first line came before the server sent the next one")
        XCTAssertLessThan(arrivals[0].timeIntervalSince(sent[0]), 0.3)
        XCTAssertLessThan(arrivals[1], sent[3])
        XCTAssertLessThan(arrivals[1].timeIntervalSince(sent[2]), 0.3)

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(request.hasPrefix("GET /api/v1/namespaces/default/pods/ticker/log?follow=true&tailLines=10&timestamps=true HTTP/1.1\r\n"), request)
    }

    func testReconnectAfterTheConnectionDrops() async throws {
        let pki = try ThrowawayPKI.make()
        let server = try await LocalTLSServer(pki: pki) { index, _ in
            if index == 0 {
                // No last chunk: the connection closes in the middle of the stream.
                return [.init(after: 0, data: Data(chunkedHead.utf8) + chunk("2026-11-06T05:00:01Z one\n"))]
            }
            return [.init(after: 0, data: Data(chunkedHead.utf8) + chunk("2026-11-06T05:00:01Z one\n2026-11-06T05:00:02Z two\n") + lastChunk)]
        }
        defer { server.stop() }
        let tls = try await KubeTLS.make(credentials(pki, port: server.port))
        let api = KubeAPIClient(server: URL(string: "https://127.0.0.1:\(server.port)")!, transport: URLSessionKubeTransport(tls: tls))
        var lines: [String] = []
        for try await line in api.podLogs(namespace: "default", pod: "ticker", follow: true, tail: 10) {
            lines.append(line)
        }
        XCTAssertEqual(lines, ["one", "two"])
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertTrue(server.requests[1].contains("sinceTime=2026-11-06T05:00:01Z"), server.requests[1])
        XCTAssertFalse(server.requests[1].contains("tailLines"))
    }

    func testErrorStatusCarriesTheAPIMessage() async throws {
        let pki = try ThrowawayPKI.make()
        let body = #"{"kind":"Status","apiVersion":"v1","status":"Failure","message":"pods \"gone\" not found","reason":"NotFound","code":404}"#
        let server = try await LocalTLSServer(pki: pki) { _, _ in [
            .init(after: 0, data: Data("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)),
        ] }
        defer { server.stop() }
        let tls = try await KubeTLS.make(credentials(pki, port: server.port))
        let stream = KubeHTTPStream(tls: tls)
        let api = KubeAPIClient(server: URL(string: "https://127.0.0.1:\(server.port)")!, transport: MockKubeTransport())
        do {
            for try await _ in stream.lines(api.logRequest(namespace: "default", pod: "gone", container: nil, follow: false, tail: nil)) {}
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? KubeAPIError, .http(404, #"pods "gone" not found"#))
        }
    }

    func testWrongCAIsRefused() async throws {
        let pki = try ThrowawayPKI.make()
        let other = try ThrowawayPKI.make(name: "other")
        let server = try await LocalTLSServer(pki: pki) { _, _ in [.init(after: 0, data: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi".utf8))] }
        defer { server.stop() }
        var creds = credentials(pki, port: server.port)
        creds.certificateAuthority = other.caDER
        let tls = try await KubeTLS.make(creds)
        let request = URLRequest(url: URL(string: "https://127.0.0.1:\(server.port)/version")!)
        do {
            for try await _ in KubeHTTPStream(tls: tls, connectTimeout: 5).lines(request) {}
            XCTFail("should not trust a server signed by another CA")
        } catch {
            guard case .unreachable = error as? KubeAPIError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(server.clientCertificates, 0)
    }

    func testMissingClientCertificateIsRefused() async throws {
        let pki = try ThrowawayPKI.make()
        let server = try await LocalTLSServer(pki: pki) { _, _ in [.init(after: 0, data: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi".utf8))] }
        defer { server.stop() }
        let tls = try await KubeTLS.make(credentials(pki, port: server.port, withClient: false))
        XCTAssertNil(tls.identity)
        let request = URLRequest(url: URL(string: "https://127.0.0.1:\(server.port)/version")!)
        var got: [String] = []
        do {
            for try await line in KubeHTTPStream(tls: tls, connectTimeout: 5).lines(request) { got.append(line) }
            XCTFail("the server asks for a client certificate")
        } catch {
            XCTAssertTrue(got.isEmpty)
        }
    }

    func testConnectionRefused() async throws {
        // Port 1 on loopback has nothing listening.
        let request = URLRequest(url: URL(string: "https://127.0.0.1:1/version")!)
        do {
            for try await _ in KubeHTTPStream(tls: nil, connectTimeout: 3).lines(request) {}
            XCTFail("should fail")
        } catch {
            guard case .unreachable = error as? KubeAPIError else { return XCTFail("\(error)") }
        }
    }
}
