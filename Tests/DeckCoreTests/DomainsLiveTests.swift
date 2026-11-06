import XCTest
import Security
@testable import DeckCore

/// Real proxy, real certificates, real container. Run with DECK_LIVE_DOMAINS=1.
/// Needs the demo container deck-demo-web (nginx on port 80) running.
/// Trust is never added to the person's keychain: the CA goes into a temporary keychain
/// with no trust settings, and clients pin the CA themselves.
/// The tunnel test needs DECK_LIVE_TUNNEL=1 and cloudflared already installed.
final class DomainsLiveTests: XCTestCase {
    private var workDir: URL!
    private var keychain: String!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_LIVE_DOMAINS"] == "1"
                          || ProcessInfo.processInfo.environment["DECK_LIVE_TUNNEL"] == "1", "Set DECK_LIVE_DOMAINS=1")
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-v2-net-live-\(UUID().uuidString)")
        keychain = workDir.appendingPathComponent("deck-v2-net-test.keychain-db").path
    }

    override func tearDown() async throws {
        if let keychain {
            _ = try? await ProcessRunner().run("/usr/bin/security", ["delete-keychain", keychain])
        }
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func demoWebAddress() async throws -> String {
        let client = ContainerClient(cliPath: "/usr/local/bin/container")
        let list = try await client.listContainers(all: false)
        let web = try XCTUnwrap(list.first { $0.name == "deck-demo-web" }, "start deck-demo-web first")
        return try XCTUnwrap(web.ipAddress)
    }

    private func freePort() -> UInt16 {
        for _ in 0..<50 {
            let port = UInt16.random(in: 20_000...40_000)
            if !LoopbackPortCheck.isListening(port) { return port }
        }
        return 28_443
    }

    private func curl(_ args: [String]) async throws -> CommandResult {
        try await ProcessRunner().run("/usr/bin/curl", ["-sS", "--max-time", "10"] + args)
    }

    func testProxyServesHTTPSToDemoWeb() async throws {
        let ip = try await demoWebAddress()
        let ca = LocalCertificateAuthority(directory: workDir.appendingPathComponent("ca"))
        try await ca.createIfNeeded()

        // Temporary keychain holding the CA, no trust settings, removed in tearDown.
        let security = ProcessRunner()
        try await security.run("/usr/bin/security", ["create-keychain", "-p", "deck-test", keychain]).orThrow()
        try await security.run("/usr/bin/security", ["import", ca.caCertificateURL.path, "-k", keychain, "-t", "cert"]).orThrow()
        let found = try await security.run("/usr/bin/security", ["find-certificate", "-c", DomainsConfig.caCommonName, keychain])
        XCTAssertTrue(found.succeeded, found.stderr)
        XCTAssertFalse(ca.isTrusted(), "the test never adds trust")

        let port = freePort()
        let routes = RoutePlanner.routes(
            containers: [ContainerSummary(id: "deck-demo-web", name: "deck-demo-web", image: "nginx:alpine", state: .running, ipAddress: ip,
                                          ports: [PortMapping(hostPort: 18090, containerPort: 80)])],
            aliases: [ProxyAlias(pattern: "*.gw.localhost", container: "deck-demo-web"),
                      ProxyAlias(pattern: "gone.localhost", container: "deck-v2-net-missing")]
        )
        let proxy = HTTPSProxyServer(port: port, authority: ca)
        try await proxy.start(routes: routes)
        defer { proxy.stop() }

        // Loopback only.
        let lsof = try await ProcessRunner().run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"])
        XCTAssertTrue(lsof.stdout.contains("127.0.0.1:\(port)"), lsof.stdout)
        XCTAssertFalse(lsof.stdout.contains("*:\(port)"), lsof.stdout)

        let url = "https://deck-demo-web.localhost:\(port)/"
        let resolve = ["--resolve", "deck-demo-web.localhost:\(port):127.0.0.1"]
        let page = try await curl(resolve + ["--cacert", ca.caCertificateURL.path, "-w", "\n%{http_code} %{ssl_verify_result}", url])
        XCTAssertTrue(page.stdout.contains("Welcome to nginx"), page.stdout + page.stderr)
        XCTAssertTrue(page.stdout.hasSuffix("200 0"), page.stdout)

        // Without the CA the certificate is not trusted (nothing was added to any trust store).
        let untrusted = try await curl(resolve + [url])
        XCTAssertFalse(untrusted.succeeded)

        // Leaf is made per name, checked by macOS with our CA as the only anchor.
        let leaf = ca.leafCertificateURL(for: "deck-demo-web.localhost")
        let verify = try await security.run("/usr/bin/security", ["verify-cert", "-c", leaf.path, "-r", ca.caCertificateURL.path, "-k", keychain, "-p", "ssl", "-s", "deck-demo-web.localhost"])
        XCTAssertTrue(verify.succeeded, verify.stdout + verify.stderr)

        // Apple's own TLS stack (URLSession) accepts it when the CA is the anchor.
        let pinned = try await PinnedSession(ca: XCTUnwrap(LocalCertificateAuthority.loadCertificate(ca.caCertificateURL)))
            .get(URL(string: "https://deck-demo-web.localhost:\(port)/")!)
        XCTAssertEqual(pinned.status, 200)
        XCTAssertTrue(pinned.body.contains("nginx"))

        // Wildcard alias gets its own certificate.
        let wild = try await curl(["--resolve", "a.gw.localhost:\(port):127.0.0.1", "--cacert", ca.caCertificateURL.path, "https://a.gw.localhost:\(port)/"])
        XCTAssertTrue(wild.stdout.contains("Welcome to nginx"), wild.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ca.leafCertificateURL(for: "a.gw.localhost").path))

        // Alias to a container that does not exist: a clear 503 page.
        let gone = try await curl(["--resolve", "gone.localhost:\(port):127.0.0.1", "--cacert", ca.caCertificateURL.path, "-w", "\n%{http_code}", "https://gone.localhost:\(port)/"])
        XCTAssertTrue(gone.stdout.hasSuffix("503"), gone.stdout)

        // Unknown name: connection closed, no certificate made.
        let unknown = try await curl(["--resolve", "nope.localhost:\(port):127.0.0.1", "--cacert", ca.caCertificateURL.path, "https://nope.localhost:\(port)/"])
        XCTAssertFalse(unknown.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ca.leafCertificateURL(for: "nope.localhost").path))

        // Plain http on the https port gets a short hint.
        let plain = try await curl(["http://127.0.0.1:\(port)/"])
        XCTAssertTrue(plain.stdout.contains("Use https://"), plain.stdout)

        // Many requests at once.
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let r = try await self.curl(resolve + ["--cacert", ca.caCertificateURL.path, "-o", "/dev/null", "-w", "%{http_code}", url])
                    return r.stdout == "200"
                }
            }
            for try await ok in group { XCTAssertTrue(ok) }
        }
        XCTAssertGreaterThanOrEqual(proxy.snapshot().requestsByHost["deck-demo-web.localhost"] ?? 0, 13)

        // Clean stop: the port is free again.
        proxy.stop()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(LoopbackPortCheck.isListening(port))
        XCTAssertFalse(proxy.snapshot().isRunning)
    }

    func testPortInUseGivesClearError() async throws {
        let ca = LocalCertificateAuthority(directory: workDir.appendingPathComponent("ca"))
        let port = freePort()
        let first = HTTPSProxyServer(port: port, authority: ca)
        try await first.start(routes: [])
        defer { first.stop() }
        let second = HTTPSProxyServer(port: port, authority: ca)
        do {
            try await second.start(routes: [])
            second.stop()
            XCTFail("second listener on the same port must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("in use") || error.localizedDescription.contains("could not listen"), error.localizedDescription)
        }
    }

    func testAliasDNSResponderAnswers() async throws {
        let port = freePort()
        let responder = AliasDNSResponder(port: port)
        try responder.start(patterns: ["*.gateway.test", "api.test"])
        defer { responder.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let dig = try await ProcessRunner().run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", "@127.0.0.1", "-p", String(port), "a.gateway.test", "A"])
        XCTAssertEqual(dig.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "127.0.0.1")
        let api = try await ProcessRunner().run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", "@127.0.0.1", "-p", String(port), "api.test", "A"])
        XCTAssertEqual(api.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "127.0.0.1")
        let other = try await ProcessRunner().run("/usr/bin/dig", ["+time=2", "+tries=1", "@127.0.0.1", "-p", String(port), "other.test", "A"])
        XCTAssertTrue(other.stdout.contains("NXDOMAIN"), other.stdout)
    }

    func testCloudflareQuickTunnel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_LIVE_TUNNEL"] == "1", "Set DECK_LIVE_TUNNEL=1")
        let path = try XCTUnwrap(ShareToolLocator().path(for: CloudflareShareProvider()), "cloudflared is not installed. The test never installs it.")
        let ip = try await demoWebAddress()
        let route = ProxyRoute(host: "deck-demo-web.localhost", container: "deck-demo-web", targetHost: ip, targetPort: 80, source: .published)
        let session = TunnelSession(provider: CloudflareShareProvider(), routeHost: route.host)
        let live = expectation(description: "public link")
        session.onChange = { if case .live = $0 { live.fulfill() } }
        try session.start(executable: path, arguments: XCTUnwrap(CloudflareShareProvider().arguments(for: route)))
        defer { session.stop() }
        await fulfillment(of: [live], timeout: 45)
        let url = try XCTUnwrap(session.publicURL)
        print("DECK_TUNNEL_URL \(url)")
        print("DECK_TUNNEL_OUTPUT_BEGIN\n\(session.outputTail)\nDECK_TUNNEL_OUTPUT_END")
        XCTAssertTrue(url.hasSuffix(DomainsConfig.quickTunnelHostSuffix))

        // The new name can take a few seconds to appear in public DNS.
        var served = false
        for _ in 0..<20 where !served {
            let r = try await ProcessRunner().run("/usr/bin/curl", ["-s", "--max-time", "8", "--doh-url", "https://1.1.1.1/dns-query", url])
            served = r.stdout.contains("Welcome to nginx")
            if !served { try await Task.sleep(for: .seconds(3)) }
        }
        XCTAssertTrue(served, "the public link did not serve the page")

        session.stop()
        try await Task.sleep(for: .seconds(4))
        XCTAssertFalse(session.isRunning)
    }
}

/// URLSession that trusts only the given CA, for checking the proxy without touching keychains.
private final class PinnedSession: NSObject, URLSessionDelegate {
    let ca: SecCertificate

    init(ca: SecCertificate) { self.ca = ca }

    func get(_ url: URL) async throws -> (status: Int, body: String) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
