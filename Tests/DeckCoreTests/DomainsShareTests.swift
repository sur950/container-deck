import XCTest
@testable import DeckCore

final class DomainsShareTests: XCTestCase {
    private let web = ProxyRoute(host: "deck-demo-web.localhost", container: "deck-demo-web", targetHost: "192.168.65.2", targetPort: 80, source: .published)

    func testTunnelArguments() {
        XCTAssertEqual(CloudflareShareProvider().arguments(for: web), ["tunnel", "--no-autoupdate", "--url", "http://192.168.65.2:80"])
        XCTAssertEqual(NgrokShareProvider().arguments(for: web), ["http", "192.168.65.2:80", "--log", "stdout", "--log-format", "json"])
        XCTAssertEqual(TailscaleFunnelProvider().arguments(funnelPort: 443, publishedPort: 18090), ["funnel", "--https=443", "http://127.0.0.1:18090"])
        XCTAssertEqual(TailscaleFunnelProvider().blocker(for: web, publishedPort: nil)?.kind, .needsPublishedPort)
        var stopped = web
        stopped.targetHost = nil
        XCTAssertNil(CloudflareShareProvider().arguments(for: stopped))
    }

    func testPublicURLParsing() {
        XCTAssertEqual(CloudflareShareProvider().publicURL(in: DomainsFixtures.cloudflaredQuickTunnel, launch: nil), DomainsFixtures.cloudflaredQuickTunnelURL)
        XCTAssertNil(CloudflareShareProvider().publicURL(in: "INF Requesting new quick Tunnel on trycloudflare.com...", launch: nil))
        XCTAssertEqual(NgrokShareProvider().publicURL(in: DomainsFixtures.ngrokStarted, launch: nil), "https://ab12-34-56.ngrok-free.app")
        XCTAssertEqual(TailscaleFunnelProvider().publicURL(in: "Available on the internet:\n\nhttps://mac.tail1234.ts.net/\n|-- proxy http://127.0.0.1:18090", launch: nil), "https://mac.tail1234.ts.net/")
    }

    func testToolLocator() {
        let present: Set<String> = ["/opt/homebrew/bin/cloudflared", "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/brew"]
        let locator = ShareToolLocator(searchPaths: ["/opt/homebrew/bin", "/usr/local/bin"], toolsDirectory: "/support/bin") { present.contains($0) }
        XCTAssertEqual(locator.installed(), ["cloudflared": "/opt/homebrew/bin/cloudflared", "tailscale": "/Applications/Tailscale.app/Contents/MacOS/Tailscale"])
        XCTAssertEqual(locator.homebrewPath, "/opt/homebrew/bin/brew")
        let own = ShareToolLocator(searchPaths: [], toolsDirectory: "/support/bin") { $0 == "/support/bin/cloudflared" }
        XCTAssertEqual(own.path(for: CloudflareShareProvider()), "/support/bin/cloudflared")
        XCTAssertNil(own.path(for: NgrokShareProvider()))
    }

    func testTunnelSessionFindsLinkAndStops() throws {
        // A stand in for cloudflared: prints the recorded output, then waits.
        let script = "printf '%s\\n' \"$1\" >&2; sleep 30"
        let session = TunnelSession(provider: CloudflareShareProvider(), routeHost: "deck-demo-web.localhost")
        let live = expectation(description: "live")
        let stopped = expectation(description: "stopped")
        session.onChange = { state in
            if case .live = state { live.fulfill() }
            if state == .stopped { stopped.fulfill() }
        }
        try session.start(executable: "/bin/sh", arguments: ["-c", script, "fake", DomainsFixtures.cloudflaredQuickTunnel])
        wait(for: [live], timeout: 5)
        XCTAssertEqual(session.publicURL, DomainsFixtures.cloudflaredQuickTunnelURL)
        session.stop()
        wait(for: [stopped], timeout: 5)
        XCTAssertFalse(session.isRunning)
    }

    func testTunnelSessionReportsFailure() throws {
        let session = TunnelSession(provider: NgrokShareProvider(), routeHost: "x.localhost")
        let failed = expectation(description: "failed")
        session.onChange = { state in
            if case .failed(let failure) = state {
                XCTAssertTrue(failure.message.contains("authtoken"))
                failed.fulfill()
            }
        }
        try session.start(executable: "/bin/sh", arguments: ["-c", "echo 'ERROR: authentication failed: Usage of ngrok requires a verified account and authtoken.' >&2; exit 1"])
        wait(for: [failed], timeout: 5)
    }

    func testTunnelStopsWhenTheAppGoesAway() throws {
        // Stand in for the app: a process that exits after one second.
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["1"]
        try parent.run()
        let session = TunnelSession(provider: CloudflareShareProvider(), routeHost: "x.localhost")
        let ended = expectation(description: "ended")
        session.onChange = { state in
            if case .failed = state { ended.fulfill() }
        }
        try session.start(executable: "/bin/sleep", arguments: ["60"], parent: parent.processIdentifier)
        XCTAssertTrue(session.isRunning)
        wait(for: [ended], timeout: 10)
        XCTAssertFalse(session.isRunning)
    }

    // MARK: cloudflared install

    func testReleaseParsing() throws {
        let release = try CloudflaredInstaller.release(fromJSON: Data(DomainsFixtures.cloudflaredRelease.utf8))
        XCTAssertEqual(release.version, "2026.10.7")
        XCTAssertEqual(release.sha256, "3586ccf397e98e5f437e60e7c307ca6ac463e110580503af8bb8e6f9ebf831bd")
        XCTAssertEqual(release.downloadURL.lastPathComponent, "cloudflared-darwin-arm64.tgz")
    }

    func testReleaseWithoutDigestIsRefused() {
        let json = #"{"tag_name":"1","assets":[{"name":"cloudflared-darwin-arm64.tgz","browser_download_url":"https://x/y.tgz"}]}"#
        XCTAssertThrowsError(try CloudflaredInstaller.release(fromJSON: Data(json.utf8)))
        XCTAssertThrowsError(try CloudflaredInstaller.release(fromJSON: Data("nope".utf8)))
    }

    func testChecksum() throws {
        let data = Data("hello".utf8)
        XCTAssertEqual(CloudflaredInstaller.sha256Hex(of: data), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertNoThrow(try CloudflaredInstaller.verify(data, expected: "2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"))
        XCTAssertThrowsError(try CloudflaredInstaller.verify(data, expected: String(repeating: "0", count: 64)))
    }

    func testHomebrewInstallCommand() async throws {
        let runner = MockRunner()
        runner.responses["install cloudflared"] = CommandResult(exitCode: 0, stdout: "")
        try await CloudflaredInstaller(runner: runner, destination: URL(fileURLWithPath: "/tmp/none")).installWithHomebrew(brew: "/opt/homebrew/bin/brew")
        XCTAssertEqual(runner.calls, [["/opt/homebrew/bin/brew", "install", "cloudflared"]])
    }
}
