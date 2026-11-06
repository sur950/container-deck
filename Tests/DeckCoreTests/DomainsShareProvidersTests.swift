import XCTest
@testable import DeckCore

/// The three share providers behind `ShareProvider`, driven end to end through `ShareManager`
/// with stand in `cloudflared`, `ngrok` and `tailscale` programs. The stand ins print the real
/// tools' output (recorded ngrok 3.39.13 and cloudflared runs, Tailscale's messages taken from
/// its open source CLI) and use the same exit codes.
final class DomainsShareProvidersTests: XCTestCase {
    private let web = ProxyRoute(host: "web.localhost", container: "web", targetHost: "192.168.64.5", targetPort: 80, source: .published)
    private var fakes: FakeShareTools!

    override func setUpWithError() throws {
        fakes = try FakeShareTools()
    }

    override func tearDown() {
        fakes?.stopEverything()
        fakes?.remove()
        fakes = nil
    }

    // MARK: - Registry and protocol

    func testRegistryListsThreeEqualProviders() {
        XCTAssertEqual(ShareProviders.all.map(\.id), ["cloudflared", "ngrok", "tailscale"])
        XCTAssertEqual(ShareProviders.all.map(\.title), ["Cloudflare Tunnel", "ngrok", "Tailscale Funnel"])
        XCTAssertEqual(Set(ShareProviders.all.map(\.id)).count, ShareProviders.all.count)
        for provider in ShareProviders.all {
            XCTAssertFalse(provider.installOptions.isEmpty, provider.id)
            XCTAssertFalse(provider.summary.isEmpty, provider.id)
            XCTAssertNotNil(ShareProviders.provider(id: provider.id))
        }
        XCTAssertEqual(NgrokShareProvider().installOptions.first?.command, "brew install ngrok")
        XCTAssertEqual(CloudflareShareProvider().installOptions.first?.command, "brew install cloudflared")
        XCTAssertEqual(TailscaleFunnelProvider().installOptions, [.webPage(URL(string: "https://tailscale.com/download/mac")!)])
        XCTAssertEqual(NgrokShareProvider().setupFields.map(\.key), ["authtoken", "domain"])
        XCTAssertTrue(NgrokShareProvider().setupFields[0].isSecret)
        XCTAssertTrue(CloudflareShareProvider().setupFields.isEmpty)
    }

    func testLocatorFindsProvidersAndTheTailscaleApp() {
        let present: Set<String> = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/ngrok"]
        let locator = ShareToolLocator(searchPaths: ["/opt/homebrew/bin", "/usr/local/bin"], toolsDirectory: "/x") { present.contains($0) }
        XCTAssertEqual(locator.installed(), ["ngrok": "/usr/local/bin/ngrok", "tailscale": "/Applications/Tailscale.app/Contents/MacOS/Tailscale"])
        let cliFirst = ShareToolLocator(searchPaths: ["/opt/homebrew/bin"], toolsDirectory: "/x") {
            $0 == "/opt/homebrew/bin/tailscale" || $0 == DomainsConfig.tailscaleAppBinary
        }
        XCTAssertEqual(cliFirst.path(for: TailscaleFunnelProvider()), "/opt/homebrew/bin/tailscale")
        let only = ShareToolLocator.only("/fakes")
        XCTAssertEqual(only.path(for: TailscaleFunnelProvider()) == nil, !FileManager.default.isExecutableFile(atPath: "/fakes/tailscale"))
    }

    func testHomebrewInstallCommands() async throws {
        let runner = MockRunner()
        runner.responses["install ngrok"] = CommandResult(exitCode: 0, stdout: "")
        let context = ShareContext(runner: runner)
        try await NgrokShareProvider().install(.homebrew("ngrok"), context: context, brew: "/opt/homebrew/bin/brew")
        XCTAssertEqual(runner.calls, [["/opt/homebrew/bin/brew", "install", "ngrok"]])
        do {
            try await NgrokShareProvider().install(.homebrew("ngrok"), context: context, brew: nil)
            XCTFail("needs Homebrew")
        } catch {}
    }

    // MARK: - ngrok parsing, against the real recorded output

    func testRealNgrokNoAuthtokenOutput() throws {
        let ngrok = NgrokShareProvider()
        let fromStdout = try XCTUnwrap(ngrok.classify(DomainsShareFixtures.ngrokNoAuthtokenStdout))
        XCTAssertEqual(fromStdout.kind, .needsSetup)
        XCTAssertEqual(fromStdout.code, "ERR_NGROK_4018")
        XCTAssertTrue(fromStdout.opensSetup)
        XCTAssertEqual(fromStdout.message, "ngrok needs an authtoken.")
        XCTAssertEqual(fromStdout.link?.absoluteString, "https://dashboard.ngrok.com/get-started/your-authtoken")
        XCTAssertEqual(ngrok.classify(DomainsShareFixtures.ngrokNoAuthtokenStderr)?.code, "ERR_NGROK_4018")
        XCTAssertEqual(ngrok.earlyFailure(in: DomainsShareFixtures.ngrokNoAuthtokenStdout)?.code, "ERR_NGROK_4018")
        XCTAssertNil(ngrok.publicURL(in: DomainsShareFixtures.ngrokNoAuthtokenStdout, launch: nil), "no link in a failed run")
        XCTAssertEqual(NgrokLog.webAddress(in: DomainsShareFixtures.ngrokNoAuthtokenStdout), "127.0.0.1:4040")
        XCTAssertEqual(NgrokLog.errorMessage(in: DomainsShareFixtures.ngrokNoAuthtokenStdout)?.hasPrefix("This ngrok session is not authenticated."), true)
    }

    func testRealNgrokBadTokenOutputs() {
        let ngrok = NgrokShareProvider()
        let malformed = ngrok.classify(DomainsShareFixtures.ngrokMalformedTokenStderr)
        XCTAssertEqual(malformed?.code, "ERR_NGROK_105")
        XCTAssertEqual(malformed?.message, "This is not a valid ngrok authtoken.")
        XCTAssertEqual(ngrok.classify(DomainsShareFixtures.ngrokMalformedTokenStdoutErrors)?.code, "ERR_NGROK_105")
        let revoked = ngrok.classify(DomainsShareFixtures.ngrokRevokedTokenStderr)
        XCTAssertEqual(revoked?.code, "ERR_NGROK_107")
        XCTAssertEqual(revoked?.kind, .needsSetup)
        XCTAssertTrue(revoked?.opensSetup == true)
        XCTAssertEqual(NgrokLog.webAddress(in: DomainsShareFixtures.ngrokWebServiceMoved), "127.0.0.1:4041")
    }

    func testNgrokLinkAndOtherErrors() {
        let ngrok = NgrokShareProvider()
        XCTAssertEqual(ngrok.publicURL(in: DomainsFixtures.ngrokStarted, launch: nil), "https://ab12-34-56.ngrok-free.app")
        let custom = #"{"t":"2026-11-06T10:40:00+0530","lvl":"info","msg":"started tunnel","obj":"tunnels","name":"command_line","addr":"http://192.168.64.5:80","url":"https://demo.example.com"}"#
        XCTAssertEqual(ngrok.publicURL(in: custom, launch: nil), "https://demo.example.com", "your own domain works too")
        XCTAssertNil(ngrok.publicURL(in: #"{"lvl":"info","msg":"started tunnel","url":"https://abcd1234.ngrok"#, launch: nil), "half a line is never taken")
        XCTAssertEqual(ngrok.classify(NgrokFakeOutput.stderr(108))?.kind, .busy)
        XCTAssertEqual(ngrok.classify(NgrokFakeOutput.stderr(108))?.message, "Your ngrok plan allows one agent at a time.")
        XCTAssertEqual(ngrok.classify(NgrokFakeOutput.stderr(334))?.kind, .busy)
        XCTAssertEqual(ngrok.classify(NgrokFakeOutput.stderr(121))?.kind, .outdated)
        XCTAssertEqual(ngrok.classify("ERROR:  something new\nERROR:  ERR_NGROK_9999")?.link?.absoluteString, "https://ngrok.com/docs/errors/err_ngrok_9999")
        XCTAssertEqual(ngrok.classify(NgrokFakeOutput.offlineLine)?.kind, .offline)
        XCTAssertNil(ngrok.classify("all good"))
    }

    func testNgrokAgentAPIParsing() {
        // Shape from ngrok's agent API docs (GET /api/tunnels).
        let json = #"{"tunnels":[{"name":"command_line","uri":"/api/tunnels/command_line","public_url":"https://d95211d2.ngrok.app","proto":"https","config":{"addr":"localhost:80","inspect":true}}],"uri":"/api/tunnels"}"#
        XCTAssertEqual(NgrokAgentAPI.publicURL(fromTunnelsJSON: Data(json.utf8)), "https://d95211d2.ngrok.app")
        XCTAssertNil(NgrokAgentAPI.publicURL(fromTunnelsJSON: Data(#"{"tunnels":[]}"#.utf8)))
        XCTAssertNil(NgrokAgentAPI.publicURL(fromTunnelsJSON: Data("nope".utf8)))
    }

    func testNgrokConfigAndSetupHelpers() {
        XCTAssertTrue(NgrokSetup.configHasAuthtoken("version: \"3\"\nagent:\n    authtoken: 2abcDEF_123\n"))
        XCTAssertTrue(NgrokSetup.configHasAuthtoken("authtoken: 2abcDEF_123\nregion: eu\n"))
        XCTAssertFalse(NgrokSetup.configHasAuthtoken("version: \"3\"\nagent:\n    authtoken: \"\"\n"))
        XCTAssertFalse(NgrokSetup.configHasAuthtoken("version: \"3\"\n# authtoken: x\n"))
        XCTAssertEqual(NgrokSetup.configPaths(home: "/Users/me").first, "/Users/me/Library/Application Support/ngrok/ngrok.yml")
        XCTAssertTrue(NgrokSetup.looksLikeToken("2Xk9QpLmN3vB7cR1tY5uW8eZ0aS_4fG6hJ2kL9mN3pQ7rT1vX"))
        XCTAssertFalse(NgrokSetup.looksLikeToken("short"))
        XCTAssertFalse(NgrokSetup.looksLikeToken("has spaces in it but is long enough"))
        XCTAssertEqual(NgrokSetup.normalizedDomain(" https://Demo.ngrok.app/ "), "demo.ngrok.app")
        XCTAssertNil(NgrokSetup.normalizedDomain("*.ngrok.app"))
        XCTAssertNil(NgrokSetup.normalizedDomain("not a domain"))
        XCTAssertEqual(NgrokSetup.version(from: "ngrok version 3.39.13"), "3.39.13")
        let ngrok = NgrokShareProvider()
        XCTAssertNotNil(ngrok.validate(field: ngrok.setupFields[0], value: "nope"))
        XCTAssertNil(ngrok.validate(field: ngrok.setupFields[0], value: ""))
        XCTAssertNotNil(ngrok.validate(field: ngrok.setupFields[1], value: "bad domain"))
        XCTAssertEqual(ngrok.arguments(for: web, domain: "demo.ngrok.app"),
                       ["http", "192.168.64.5:80", "--log", "stdout", "--log-format", "json", "--url", "https://demo.ngrok.app"])
    }

    // MARK: - Tailscale parsing

    func testTailscaleStatusParsing() throws {
        let status = try XCTUnwrap(TailscaleStatus.parse(Data(TailscaleFakeOutput.statusRunning().utf8)))
        XCTAssertEqual(status.dnsName, "mac.tail1234.ts.net")
        XCTAssertEqual(status.httpsEnabled, true)
        XCTAssertEqual(status.funnelAllowed, true)
        XCTAssertEqual(status.funnelPorts, [443, 8443, 10000])
        XCTAssertNil(status.blockingFailure)

        let narrow = try XCTUnwrap(TailscaleStatus.parse(Data(TailscaleFakeOutput.statusRunning(ports: "8443").utf8)))
        XCTAssertEqual(narrow.funnelPorts, [8443])
        let range = try XCTUnwrap(TailscaleStatus.parse(Data(TailscaleFakeOutput.statusRunning(ports: "80,8000-9000").utf8)))
        XCTAssertEqual(range.funnelPorts, [8443])

        let noHTTPS = try XCTUnwrap(TailscaleStatus.parse(Data(TailscaleFakeOutput.statusRunning(caps: ["funnel"]).utf8)))
        XCTAssertEqual(noHTTPS.blockingFailure?.message, "HTTPS certificates are off in your tailnet.")
        XCTAssertEqual(noHTTPS.blockingFailure?.link?.absoluteString, "https://login.tailscale.com/admin/dns")
        let noFunnel = try XCTUnwrap(TailscaleStatus.parse(Data(TailscaleFakeOutput.statusRunning(caps: ["https"]).utf8)))
        XCTAssertEqual(noFunnel.funnelAllowed, false)
        XCTAssertNil(noFunnel.blockingFailure, "the CLI offers a link to allow Funnel, so this does not block")

        let loggedOut = try XCTUnwrap(TailscaleStatus.parse(Data(TailscaleFakeOutput.statusLoggedOut.utf8)))
        XCTAssertEqual(loggedOut.blockingFailure?.message, "Sign in to Tailscale first.")
        XCTAssertEqual(loggedOut.blockingFailure?.link?.absoluteString, "https://login.tailscale.com/a/1a2b3c4d5e")
        let stopped = try XCTUnwrap(TailscaleStatus.parse(Data(TailscaleFakeOutput.statusRunning(state: "Stopped").utf8)))
        XCTAssertEqual(stopped.blockingFailure?.kind, .notRunning)
        let waiting = try XCTUnwrap(TailscaleStatus.parse(Data(TailscaleFakeOutput.statusRunning(state: "NeedsMachineAuth").utf8)))
        XCTAssertEqual(waiting.blockingFailure?.kind, .notAllowed)
        let old = try XCTUnwrap(TailscaleStatus.parse(Data(TailscaleFakeOutput.statusRunning(version: "1.50.1-t123").utf8)))
        XCTAssertEqual(old.blockingFailure?.kind, .outdated)
        XCTAssertNil(TailscaleStatus.parse(Data("Failed to connect".utf8)))
    }

    func testFunnelConfigAndPortChoice() throws {
        let json = #"""
        {
          "TCP": { "443": { "HTTPS": true } },
          "Web": { "mac.tail1234.ts.net:443": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:3000" } } } },
          "AllowFunnel": { "mac.tail1234.ts.net:443": true },
          "Foreground": {
            "a1b2c3": {
              "TCP": { "8443": { "HTTPS": true } },
              "Web": { "mac.tail1234.ts.net:8443": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:18090" } } } },
              "AllowFunnel": { "mac.tail1234.ts.net:8443": true }
            }
          }
        }
        """#
        let config = try XCTUnwrap(FunnelServeConfig.parse(Data(json.utf8)))
        XCTAssertEqual(config.usedPorts, [443, 8443])
        XCTAssertEqual(config.backgroundProxy(host: "mac.tail1234.ts.net", port: 443), "http://127.0.0.1:3000")
        XCTAssertNil(config.backgroundProxy(host: "mac.tail1234.ts.net", port: 8443), "foreground sessions are not background config")
        let status = try XCTUnwrap(TailscaleStatus.parse(Data(TailscaleFakeOutput.statusRunning().utf8)))
        XCTAssertEqual(try TailscaleFunnelPlanner.choosePort(status: status, config: config), 10000)
        XCTAssertEqual(try TailscaleFunnelPlanner.choosePort(status: status, config: FunnelServeConfig()), 443)
        XCTAssertThrowsError(try TailscaleFunnelPlanner.choosePort(status: status, config: config, reserved: [10000])) { error in
            XCTAssertEqual((error as? ShareFailure)?.kind, .busy)
        }
        XCTAssertEqual(FunnelServeConfig.parse(Data("{}\n".utf8))?.usedPorts, [])
        XCTAssertEqual(TailscaleFunnelPlanner.publicURL(dnsName: "mac.tail1234.ts.net", port: 443), "https://mac.tail1234.ts.net/")
        XCTAssertEqual(TailscaleFunnelPlanner.publicURL(dnsName: "mac.tail1234.ts.net", port: 8443), "https://mac.tail1234.ts.net:8443/")
    }

    func testTailscaleMessagesFromItsSource() {
        let ts = TailscaleFunnelProvider()
        let cases: [(String, ShareFailure.Kind, String)] = [
            (TailscaleFakeOutput.daemonDown, .notRunning, "Tailscale is not running."),
            ("Logged out.", .needsSetup, "Sign in to Tailscale first."),
            ("Tailscale is stopped.", .notRunning, "Tailscale is turned off."),
            ("Machine is not yet approved by tailnet admin.", .notAllowed, "This Mac waits for approval in your tailnet."),
            (TailscaleFakeOutput.noHTTPS, .notAllowed, "HTTPS certificates are off in your tailnet."),
            (TailscaleFakeOutput.noAttribute, .notAllowed, "Your tailnet policy does not allow Funnel on this Mac."),
            (TailscaleFakeOutput.enableFunnel, .notAllowed, "Funnel is not turned on for your tailnet."),
            (TailscaleFakeOutput.nodeNotInPolicy, .notAllowed, "Your tailnet policy does not allow Funnel on this Mac."),
            ("listener already exists for port 443", .busy, "Port 443 on your tailnet name is already shared."),
            ("port 443 is not allowed for funnel; allowed ports are: 8443", .notAllowed, "Your tailnet does not allow Funnel on port 443."),
            ("Another client is changing the serve config; please try again.", .busy, "Another Tailscale share is changing at the same time."),
            ("Error: the CLI for serve and funnel has changed.", .outdated, "This Tailscale is too old for Funnel."),
        ]
        for (output, kind, message) in cases {
            let failure = ts.classify(output)
            XCTAssertEqual(failure?.kind, kind, output)
            XCTAssertEqual(failure?.message, message, output)
            XCTAssertFalse(failure?.fix.isEmpty ?? true, output)
        }
        XCTAssertEqual(ts.classify(TailscaleFakeOutput.enableFunnel)?.link?.absoluteString, "https://login.tailscale.com/f/funnel?node=nFAKE7CNTRL")
        XCTAssertNotNil(ts.earlyFailure(in: TailscaleFakeOutput.enableFunnel))
        XCTAssertNil(ts.earlyFailure(in: "Available on the internet:\n"))
        XCTAssertEqual(ts.publicURL(in: TailscaleFakeOutput.started(url: "https://mac.tail1234.ts.net:8443/", target: "http://127.0.0.1:18090"), launch: nil),
                       "https://mac.tail1234.ts.net:8443/")
        XCTAssertNil(ts.publicURL(in: "Available within your tailnet:\n\nhttps://mac.tail1234.ts.net/\n", launch: nil))
    }

    func testCloudflareParsing() {
        let cf = CloudflareShareProvider()
        XCTAssertEqual(cf.publicURL(in: DomainsFixtures.cloudflaredQuickTunnel, launch: nil), DomainsFixtures.cloudflaredQuickTunnelURL)
        XCTAssertEqual(cf.classify(CloudflareFakeOutput.blocked)?.kind, .offline)
        XCTAssertEqual(cf.classify("ERR quick tunnel provisioning failed")?.kind, .busy)
        XCTAssertNil(cf.classify(DomainsFixtures.cloudflaredQuickTunnel))
    }

    // MARK: - Full flow with the stand in ngrok

    func testNgrokSharesWithKeychainTokenPassedOnlyThroughTheEnvironment() async throws {
        let token = "2Xk9QpLmN3vB7cR1tY5uW8eZ0aS_4fG6hJ2kL9mN3pQ7rT1vX"
        try fakes.installNgrok(mode: "auth")
        try fakes.write("ngrok.validtoken", token)
        let manager = fakes.manager(secrets: ["ngrok.authtoken": token])
        let session = try await manager.share(web, with: NgrokShareProvider(), publishedPort: nil)
        let state = await fakes.wait(session) { if case .live = $0 { return true } else { return false } }
        XCTAssertEqual(state, .live("https://ab12-34-56.ngrok-free.app"))

        // ngrok got the token in its environment, and nowhere else.
        XCTAssertEqual(fakes.read("ngrok.token"), token)
        let calls = try XCTUnwrap(fakes.read("ngrok.calls"))
        XCTAssertEqual(calls.trimmingCharacters(in: .newlines), "http 192.168.64.5:80 --log stdout --log-format json")
        XCTAssertFalse(calls.contains(token))
        XCTAssertFalse(session.launch?.arguments.contains(where: { $0.contains(token) }) ?? true)
        let ps = try await ProcessRunner().run("/bin/ps", ["-axww", "-o", "args="])
        XCTAssertFalse(ps.stdout.contains(token), "the token must never be on a command line")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fakes.home.path), [], "nothing is written to the home folder")

        let pid = try XCTUnwrap(fakes.pid("ngrok.pid"))
        XCTAssertTrue(FakeShareTools.isAlive(pid))
        await manager.stop(web.host)
        XCTAssertNil(manager.session(for: web.host))
        try await fakes.waitUntilDead(pid)
        XCTAssertEqual(fakes.read("ngrok.exit"), "stopped\n", "ngrok got a clean TERM")
    }

    func testNgrokUsesTheSavedDomain() async throws {
        try fakes.installNgrok(mode: "ok")
        let manager = fakes.manager(settings: ["ngrok.domain": "https://Demo.ngrok.app/"])
        let session = try await manager.share(web, with: NgrokShareProvider(), publishedPort: nil)
        let state = await fakes.wait(session) { if case .live = $0 { return true } else { return false } }
        XCTAssertEqual(state, .live("https://demo.ngrok.app"))
        XCTAssertTrue(fakes.read("ngrok.calls")?.contains("--url https://demo.ngrok.app") == true)
        XCTAssertEqual(fakes.read("ngrok.token"), "<unset>", "no token saved, none passed")
        await manager.stop(web.host)
    }

    func testNgrokFailuresWithTheStandIn() async throws {
        let cases: [(mode: String, token: String?, code: String, kind: ShareFailure.Kind)] = [
            ("auth", nil, "ERR_NGROK_4018", .needsSetup),
            ("auth", "bad-token-value-1234567890", "ERR_NGROK_105", .needsSetup),
            ("auth", "2Xk9QpLmN3vB7cR1tY5uW8eZ0aS_wrongwrongwrong", "ERR_NGROK_107", .needsSetup),
            ("108", nil, "ERR_NGROK_108", .busy),
            ("334", nil, "ERR_NGROK_334", .busy),
            ("121", nil, "ERR_NGROK_121", .outdated),
        ]
        try fakes.write("ngrok.validtoken", "the-right-token-is-not-used-here")
        for item in cases {
            try fakes.installNgrok(mode: item.mode)
            let manager = fakes.manager(secrets: item.token.map { ["ngrok.authtoken": $0] } ?? [:])
            let session = try await manager.share(web, with: NgrokShareProvider(), publishedPort: nil)
            let state = await fakes.wait(session) { if case .failed = $0 { return true } else { return false } }
            guard case .failed(let failure) = state else { return XCTFail("\(item.mode): \(String(describing: state))") }
            XCTAssertEqual(failure.code, item.code, item.mode)
            XCTAssertEqual(failure.kind, item.kind, item.mode)
            if let token = item.token {
                XCTAssertFalse(failure.message.contains(token) || failure.fix.contains(token))
                XCTAssertFalse(session.outputTail.contains(token))
            }
            await session.waitUntilExit()
            XCTAssertFalse(session.isRunning, item.mode)
            await manager.stop(web.host)
        }
    }

    func testNgrokBlockedNetworkTimesOutAndStops() async throws {
        try fakes.installNgrok(mode: "offline")
        let manager = fakes.manager(linkTimeout: 2.5)
        let session = try await manager.share(web, with: NgrokShareProvider(), publishedPort: nil)
        let state = await fakes.wait(session, timeout: 10) { if case .failed = $0 { return true } else { return false } }
        guard case .failed(let failure) = state else { return XCTFail(String(describing: state)) }
        XCTAssertEqual(failure.kind, .offline)
        XCTAssertEqual(failure.message, "ngrok cannot reach its servers.")
        XCTAssertTrue(failure.otherProviderMayWork)
        await session.waitUntilExit()
        XCTAssertFalse(session.isRunning, "a share with no link is stopped")
        await manager.stop(web.host)
    }

    func testNgrokLinkFromTheAgentAPIWhenTheLogHasNone() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs /usr/bin/python3 for a tiny local server")
        let port = try await fakes.startAPIServer(json: #"{"tunnels":[{"name":"command_line","public_url":"https://from-api.ngrok-free.app","proto":"https"}],"uri":"/api/tunnels"}"#)
        try fakes.write("api.port", String(port))
        try fakes.installNgrok(mode: "api")
        let manager = fakes.manager()
        let session = try await manager.share(web, with: NgrokShareProvider(), publishedPort: nil)
        let state = await fakes.wait(session, timeout: 10) { if case .live = $0 { return true } else { return false } }
        XCTAssertEqual(state, .live("https://from-api.ngrok-free.app"))
        await manager.stop(web.host)
    }

    func testSecretsAreBlankedFromOutput() async throws {
        let token = "2Xk9QpLmN3vB7cR1tY5uW8eZ0aS_echoechoechoecho"
        try fakes.installNgrok(mode: "echo")
        let manager = fakes.manager(secrets: ["ngrok.authtoken": token])
        let session = try await manager.share(web, with: NgrokShareProvider(), publishedPort: nil)
        let state = await fakes.wait(session) { if case .failed = $0 { return true } else { return false } }
        guard case .failed(let failure) = state else { return XCTFail() }
        XCTAssertFalse(failure.message.contains(token))
        XCTAssertTrue(failure.message.contains("••••"))
        XCTAssertFalse(session.outputTail.contains(token))
        await manager.stop(web.host)
    }

    // MARK: - Full flow with the stand in tailscale

    func testTailscaleFunnelLeavesOtherFunnelsAlone() async throws {
        try fakes.installTailscale(mode: "ok")
        // The person's own funnel on 443, set up outside the app.
        try fakes.write("ts/bg-443", "http://127.0.0.1:3000")
        let manager = fakes.manager()
        let session = try await manager.share(web, with: TailscaleFunnelProvider(), publishedPort: 18090)
        XCTAssertEqual(session.launch?.arguments, ["funnel", "--https=8443", "http://127.0.0.1:18090"])
        let state = await fakes.wait(session) { if case .live = $0 { return true } else { return false } }
        XCTAssertEqual(state, .live("https://mac.tail1234.ts.net:8443/"))
        XCTAssertEqual(fakes.read("ts/fg-8443"), "http://127.0.0.1:18090\n")

        await manager.stop(web.host)
        try await fakes.waitUntilGone("ts/fg-8443")
        XCTAssertEqual(fakes.read("ts/bg-443"), "http://127.0.0.1:3000", "the other funnel is untouched")
        let calls = fakes.read("ts/calls") ?? ""
        XCTAssertFalse(calls.contains("reset"), "never resets everything")
        XCTAssertFalse(calls.contains("--https=443 off"))
        XCTAssertFalse(calls.contains("--https=8443 off"), "nothing of ours was left, so nothing to turn off")
    }

    func testTailscaleCleanupTurnsOffOnlyOurLeftover() async throws {
        // A client that also keeps the funnel in the background config after the command ends.
        try fakes.installTailscale(mode: "bgleak")
        try fakes.write("ts/bg-443", "http://127.0.0.1:3000")
        let manager = fakes.manager()
        let session = try await manager.share(web, with: TailscaleFunnelProvider(), publishedPort: 18090)
        _ = await fakes.wait(session) { if case .live = $0 { return true } else { return false } }
        XCTAssertNotNil(fakes.read("ts/bg-8443"))
        await manager.stop(web.host)
        XCTAssertNil(fakes.read("ts/bg-8443"), "our leftover is turned off")
        XCTAssertEqual(fakes.read("ts/bg-443"), "http://127.0.0.1:3000", "the person's funnel stays")
        let calls = fakes.read("ts/calls") ?? ""
        XCTAssertTrue(calls.contains("funnel --https=8443 off"))
        XCTAssertFalse(calls.contains("--https=443 off"))
        XCTAssertFalse(calls.contains("reset"))
    }

    func testTwoTailscaleSharesTakeDifferentPorts() async throws {
        try fakes.installTailscale(mode: "ok")
        let manager = fakes.manager()
        let api = ProxyRoute(host: "api.localhost", container: "api", targetHost: "192.168.64.6", targetPort: 3000, source: .published)
        let first = try await manager.share(web, with: TailscaleFunnelProvider(), publishedPort: 18090)
        _ = await fakes.wait(first) { if case .live = $0 { return true } else { return false } }
        let second = try await manager.share(api, with: TailscaleFunnelProvider(), publishedPort: 13000)
        let state = await fakes.wait(second) { if case .live = $0 { return true } else { return false } }
        XCTAssertEqual(first.launch?.reservedPort, 443)
        XCTAssertEqual(second.launch?.reservedPort, 8443)
        XCTAssertEqual(state, .live("https://mac.tail1234.ts.net:8443/"))
        await manager.stopAll()
        try await fakes.waitUntilGone("ts/fg-443")
        try await fakes.waitUntilGone("ts/fg-8443")
    }

    func testTailscaleFailuresWithTheStandIn() async throws {
        let provider = TailscaleFunnelProvider()
        // Failures found before anything runs.
        let before: [(mode: String, status: String, kind: ShareFailure.Kind)] = [
            ("down", TailscaleFakeOutput.statusRunning(), .notRunning),
            ("ok", TailscaleFakeOutput.statusLoggedOut, .needsSetup),
            ("ok", TailscaleFakeOutput.statusRunning(state: "Stopped"), .notRunning),
            ("ok", TailscaleFakeOutput.statusRunning(caps: ["funnel"]), .notAllowed),
            ("ok", TailscaleFakeOutput.statusRunning(version: "1.48.0"), .outdated),
        ]
        for item in before {
            try fakes.installTailscale(mode: item.mode, status: item.status)
            do {
                _ = try await fakes.manager().share(web, with: provider, publishedPort: 18090)
                XCTFail("\(item.mode) should fail")
            } catch let failure as ShareFailure {
                XCTAssertEqual(failure.kind, item.kind, item.status)
            }
            XCTAssertFalse((fakes.read("ts/calls") ?? "").contains("funnel --https"), "nothing started")
        }

        // Every port taken.
        try fakes.installTailscale(mode: "ok")
        for port in [443, 8443, 10000] { try fakes.write("ts/bg-\(port)", "http://127.0.0.1:\(port)") }
        do {
            _ = try await fakes.manager().share(web, with: provider, publishedPort: 18090)
            XCTFail("no free port")
        } catch let failure as ShareFailure {
            XCTAssertEqual(failure.kind, .busy)
        }
        for port in [443, 8443, 10000] { fakes.delete("ts/bg-\(port)") }

        // No published port.
        do {
            _ = try await fakes.manager().share(web, with: provider, publishedPort: nil)
            XCTFail("needs a published port")
        } catch let failure as ShareFailure {
            XCTAssertEqual(failure.kind, .needsPublishedPort)
        }

        // Failures the CLI reports once it runs.
        let after: [(mode: String, kind: ShareFailure.Kind, link: String?)] = [
            ("noattr", .notAllowed, "https://login.tailscale.com/admin/acls/file"),
            ("enable", .notAllowed, "https://login.tailscale.com/f/funnel?node=nFAKE7CNTRL"),
            ("busy", .busy, nil),
            ("portdenied", .notAllowed, "https://login.tailscale.com/admin/acls/file"),
            ("loggedout", .needsSetup, nil),
        ]
        for item in after {
            try fakes.installTailscale(mode: item.mode)
            let session = try await fakes.manager().share(web, with: provider, publishedPort: 18090)
            let state = await fakes.wait(session) { if case .failed = $0 { return true } else { return false } }
            guard case .failed(let failure) = state else { return XCTFail("\(item.mode): \(String(describing: state))") }
            XCTAssertEqual(failure.kind, item.kind, item.mode)
            XCTAssertEqual(failure.link?.absoluteString, item.link, item.mode)
            await session.waitUntilExit()
            XCTAssertFalse(session.isRunning, "\(item.mode): stopped, even when the CLI waits")
        }
    }

    // MARK: - Cloudflare through the same protocol

    func testCloudflareFlowWithTheStandIn() async throws {
        try fakes.installCloudflared(mode: "ok")
        let manager = fakes.manager()
        let session = try await manager.share(web, with: CloudflareShareProvider(), publishedPort: nil)
        let state = await fakes.wait(session) { if case .live = $0 { return true } else { return false } }
        XCTAssertEqual(state, .live(DomainsFixtures.cloudflaredQuickTunnelURL))
        XCTAssertEqual(fakes.read("cloudflared.calls"), "tunnel --no-autoupdate --url http://192.168.64.5:80\n")
        let pid = try XCTUnwrap(fakes.pid("cloudflared.pid"))
        await manager.stop(web.host)
        try await fakes.waitUntilDead(pid)

        try fakes.installCloudflared(mode: "blocked")
        let blocked = try await manager.share(web, with: CloudflareShareProvider(), publishedPort: nil)
        let failed = await fakes.wait(blocked) { if case .failed = $0 { return true } else { return false } }
        guard case .failed(let failure) = failed else { return XCTFail() }
        XCTAssertEqual(failure.kind, .offline)

        try fakes.installCloudflared(mode: "silent")
        let slow = try await fakes.manager(linkTimeout: 1.5).share(web, with: CloudflareShareProvider(), publishedPort: nil)
        let timedOut = await fakes.wait(slow, timeout: 8) { if case .failed = $0 { return true } else { return false } }
        guard case .failed(let noLink) = timedOut else { return XCTFail() }
        XCTAssertEqual(noLink.kind, .noLink)
        await slow.waitUntilExit()
        XCTAssertFalse(slow.isRunning)
    }

    func testReadinessForEveryProvider() async throws {
        let none = fakes.manager()
        for provider in ShareProviders.all {
            let readiness = await none.readiness(of: provider)
            XCTAssertEqual(readiness, .notInstalled, provider.id)
        }
        try fakes.installCloudflared(mode: "ok")
        try fakes.installNgrok(mode: "ok")
        try fakes.installTailscale(mode: "ok")
        let ready = await fakes.manager().readiness(of: CloudflareShareProvider())
        XCTAssertEqual(ready, .ready(detail: "Version 2026.3.0. No account needed."))
        guard case .needsSetup(let ngrokSetup) = await fakes.manager().readiness(of: NgrokShareProvider()) else { return XCTFail() }
        XCTAssertTrue(ngrokSetup.opensSetup)
        let ngrokWithToken = await fakes.manager(secrets: ["ngrok.authtoken": "2Xk9QpLmN3vB7cR1tY5uW8eZ0aS_x"]).readiness(of: NgrokShareProvider())
        XCTAssertEqual(ngrokWithToken, .ready(detail: "Version 3.39.13. Authtoken in your Keychain."))
        try FileManager.default.createDirectory(at: fakes.home.appendingPathComponent("Library/Application Support/ngrok"), withIntermediateDirectories: true)
        try "version: \"3\"\nagent:\n    authtoken: 2Xk9QpLmN3vB7cR1tY5uW8eZ0aS_x\n".write(
            to: fakes.home.appendingPathComponent("Library/Application Support/ngrok/ngrok.yml"), atomically: true, encoding: .utf8)
        let ngrokConfig = await fakes.manager().readiness(of: NgrokShareProvider())
        XCTAssertEqual(ngrokConfig, .ready(detail: "Version 3.39.13. Uses the authtoken in your ngrok config."))
        let tailscale = await fakes.manager().readiness(of: TailscaleFunnelProvider())
        XCTAssertEqual(tailscale, .ready(detail: "Shares as mac.tail1234.ts.net."))
        try fakes.installTailscale(mode: "down")
        guard case .needsSetup(let down) = await fakes.manager().readiness(of: TailscaleFunnelProvider()) else { return XCTFail() }
        XCTAssertEqual(down.message, "Tailscale is not running.")
        try fakes.installTailscale(mode: "ok", status: TailscaleFakeOutput.statusRunning(caps: ["https"]))
        guard case .needsSetup(let notAllowed) = await fakes.manager().readiness(of: TailscaleFunnelProvider()) else { return XCTFail() }
        XCTAssertEqual(notAllowed.kind, .notAllowed)
    }

    // MARK: - The guard: shares die with the app

    func testEverySharesStopsWhenTheAppGoesAway() async throws {
        try fakes.installNgrok(mode: "ok")
        try fakes.installTailscale(mode: "ok")
        try fakes.installCloudflared(mode: "ok")
        // Stand in for the app: a process that exits after four seconds.
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["4"]
        try parent.run()
        let manager = fakes.manager(parent: parent.processIdentifier)
        let api = ProxyRoute(host: "api.localhost", container: "api", targetHost: "192.168.64.6", targetPort: 3000, source: .published)
        let docs = ProxyRoute(host: "docs.localhost", container: "docs", targetHost: "192.168.64.7", targetPort: 8080, source: .published)
        let a = try await manager.share(web, with: NgrokShareProvider(), publishedPort: nil)
        let b = try await manager.share(api, with: TailscaleFunnelProvider(), publishedPort: 13000)
        let c = try await manager.share(docs, with: CloudflareShareProvider(), publishedPort: nil)
        for session in [a, b, c] {
            let state = await fakes.wait(session) { if case .live = $0 { return true } else { return false } }
            XCTAssertNotNil(state.flatMap { if case .live = $0 { return $0 } else { return nil } }, session.provider.id)
        }
        let pids = [fakes.pid("ngrok.pid"), fakes.pid("ts/pid"), fakes.pid("cloudflared.pid")].compactMap { $0 }
        XCTAssertEqual(pids.count, 3)
        parent.waitUntilExit()
        for pid in pids { try await fakes.waitUntilDead(pid, timeout: 10) }
        try await fakes.waitUntilGone("ts/fg-443")
        for session in [a, b, c] {
            await session.waitUntilExit()
            XCTAssertFalse(session.isRunning)
        }
    }

    // MARK: - The real ngrok, when one is given

    /// Runs the official ngrok agent with no authtoken through the whole share flow. Never signs in.
    /// `DECK_LIVE_NGROK_DIR=/folder/with/ngrok swift test --filter testRealNgrokWithoutAuthtoken`
    func testRealNgrokWithoutAuthtoken() async throws {
        let given = ProcessInfo.processInfo.environment["DECK_LIVE_NGROK_DIR"] ?? ""
        try XCTSkipIf(given.isEmpty, "set DECK_LIVE_NGROK_DIR to a folder with the official ngrok binary")
        let dir = given
        let context = ShareContext(secret: { _, _ in nil }, setting: { _, _ in nil }, homeDirectory: fakes.home.path)
        let manager = ShareManager(locator: .only(dir), context: context, linkTimeout: 30)
        guard case .needsSetup(let setup) = await manager.readiness(of: NgrokShareProvider()) else { return XCTFail("expected needs setup") }
        XCTAssertTrue(setup.opensSetup)
        let session = try await manager.share(ProxyRoute(host: "x.localhost", container: "x", targetHost: "127.0.0.1", targetPort: 9, source: .published),
                                              with: NgrokShareProvider(), publishedPort: nil)
        let state = await fakes.wait(session, timeout: 30) { if case .failed = $0 { return true } else { return false } }
        guard case .failed(let failure) = state else { return XCTFail(String(describing: state)) }
        print("DECK_REAL_NGROK_FAILURE \(failure.code ?? "-") | \(failure.message) | \(failure.fix)")
        print("DECK_REAL_NGROK_OUTPUT_BEGIN\n\(session.outputTail)\nDECK_REAL_NGROK_OUTPUT_END")
        XCTAssertEqual(failure.code, "ERR_NGROK_4018")
        XCTAssertEqual(failure.kind, .needsSetup)
        await session.waitUntilExit()
        XCTAssertFalse(session.isRunning)
    }

    // MARK: - Keychain and markers

    func testKeychainRoundTrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_LIVE_KEYCHAIN"] == "1", "set DECK_LIVE_KEYCHAIN=1 (adds and removes one login Keychain item)")
        let keychain = ShareKeychain(service: DomainsConfig.keychainService + ".tests-" + UUID().uuidString)
        defer { try? keychain.delete(provider: "ngrok", key: "authtoken") }
        XCTAssertNil(keychain.read(provider: "ngrok", key: "authtoken"))
        try keychain.save(" first-token-value \n", provider: "ngrok", key: "authtoken")
        XCTAssertEqual(keychain.read(provider: "ngrok", key: "authtoken"), "first-token-value")
        try keychain.save("second-token-value", provider: "ngrok", key: "authtoken")
        XCTAssertEqual(keychain.read(provider: "ngrok", key: "authtoken"), "second-token-value")
        try keychain.delete(provider: "ngrok", key: "authtoken")
        XCTAssertNil(keychain.read(provider: "ngrok", key: "authtoken"))
        XCTAssertNoThrow(try keychain.delete(provider: "ngrok", key: "authtoken"))
    }

    func testResolverMarkerStillMatchesFilesFromOlderBuilds() {
        XCTAssertEqual(DomainsConfig.resolverMarker, "# Added by Container Deck")
        let older = "# Added by Container Deck (" + "Old Company" + ")\nnameserver 127.0.0.1\nport 15353\n"
        XCTAssertTrue(AliasResolverFiles.isInstalled("api.test") { _ in older })
        XCTAssertFalse(AliasResolverFiles.isInstalled("api.test") { _ in "nameserver 1.1.1.1\n" })
        XCTAssertEqual(DomainsConfig.caCommonName, AppConfig.appName + " Local CA")
    }
}

// MARK: - Stand in tools

/// A temp folder with stand in `cloudflared`, `ngrok` and `tailscale` scripts and their state.
final class FakeShareTools: @unchecked Sendable {
    let dir: URL
    let home: URL
    private var servers: [Process] = []

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-share-fakes-\(UUID().uuidString)", isDirectory: true)
        home = dir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("ts"), withIntermediateDirectories: true)
        for (code, text) in NgrokFakeOutput.failures {
            try write("fail-\(code).out", text.stdout)
            try write("fail-\(code).err", text.stderr)
        }
        try write("cloudflared.out", DomainsFixtures.cloudflaredQuickTunnel + "\n")
    }

    func manager(secrets: [String: String] = [:], settings: [String: String] = [:],
                 parent: Int32 = ProcessInfo.processInfo.processIdentifier, linkTimeout: TimeInterval = 20) -> ShareManager {
        let context = ShareContext(runner: ProcessRunner(),
                                   secret: { secrets["\($0).\($1)"] },
                                   setting: { settings["\($0).\($1)"] },
                                   homeDirectory: home.path, callTimeout: 5)
        return ShareManager(locator: .only(dir.path), context: context, parent: parent, linkTimeout: linkTimeout, fallbackDelay: 1)
    }

    func installNgrok(mode: String) throws {
        try write("ngrok.mode", mode)
        for name in ["ngrok.calls", "ngrok.token", "ngrok.pid", "ngrok.exit"] { delete(name) }
        try script("ngrok", NgrokFakeOutput.script)
    }

    func installTailscale(mode: String, status: String = TailscaleFakeOutput.statusRunning()) throws {
        try write("ts/mode", mode)
        try write("ts/status.json", status)
        delete("ts/calls")
        try script("tailscale", TailscaleFakeOutput.script)
    }

    func installCloudflared(mode: String) throws {
        try write("cloudflared.mode", mode)
        for name in ["cloudflared.calls", "cloudflared.pid"] { delete(name) }
        try script("cloudflared", CloudflareFakeOutput.script)
    }

    /// Serves one JSON file at /api/tunnels on a free loopback port.
    func startAPIServer(json: String) async throws -> Int {
        let root = dir.appendingPathComponent("api-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("api"), withIntermediateDirectories: true)
        try json.write(to: root.appendingPathComponent("api/tunnels"), atomically: true, encoding: .utf8)
        for _ in 0..<5 {
            let port = Int.random(in: 41000...49000)
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = ["-I", "-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", root.path]
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            try server.run()
            servers.append(server)
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if await NgrokAgentAPI.fetchPublicURL(address: "127.0.0.1:\(port)") != nil { return port }
                if !server.isRunning { break }
            }
            server.terminate()
        }
        throw DeckError.commandFailed("could not start the test server")
    }

    func script(_ name: String, _ body: String) throws {
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    func pid(_ name: String) -> Int32? {
        read(name).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    func waitUntilDead(_ pid: Int32, timeout: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Self.isAlive(pid) && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(Self.isAlive(pid), "process \(pid) is still running")
    }

    func waitUntilGone(_ name: String, timeout: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while read(name) != nil && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(read(name), "\(name) is still there")
    }

    /// Waits until the session's state matches, and returns it (or the last state on timeout).
    func wait(_ session: TunnelSession, timeout: TimeInterval = 10, until match: (TunnelSession.State) -> Bool) async -> TunnelSession.State? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = session.state
            if match(state) { return state }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return session.state
    }

    func stopEverything() {
        for server in servers where server.isRunning { server.terminate() }
        for name in ["ngrok.pid", "ts/pid", "cloudflared.pid"] {
            if let pid = pid(name), Self.isAlive(pid) { kill(pid, SIGKILL) }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - What the stand ins print

enum NgrokFakeOutput {
    /// Same shape as the real JSON error lines, with the messages from ngrok's error pages.
    static func stdout(_ code: Int, _ message: String) -> String {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return #"{"t":"2026-11-06T10:31:07+0530","lvl":"eror","msg":"session closing","obj":"tunnels.session","err":"authentication failed: "# + escaped + #"\r\n\r\nERR_NGROK_\#(code)\r\n"}"# + "\n"
    }

    static func stderr(_ code: Int) -> String {
        failures.first { $0.code == code }?.text.stderr ?? ""
    }

    static let messages: [Int: String] = [
        108: "Your account is limited to 1 simultaneous ngrok agent sessions.\nRun multiple endpoints at the same time from a single agent by defining them in your agent configuration file and running `ngrok start --all`.",
        334: "The endpoint 'https://demo.ngrok.app' is already online. Either\n1. stop your existing endpoint first, or\n2. start both endpoints with `--pooling-enabled` to load balance between them.",
        121: "Your ngrok-agent version \"3.1.0\" is too old. The minimum supported agent version for your account is \"3.20.0\". Update to a newer version with 'ngrok update', by downloading from https://ngrok.com/download, or by updating your SDK version.",
    ]

    /// Recorded runs for 4018, 105 and 107. The others follow the same format.
    static var failures: [(code: Int, text: (stdout: String, stderr: String))] {
        var list: [(Int, (String, String))] = [
            (4018, (DomainsShareFixtures.ngrokNoAuthtokenStdout + "\n", DomainsShareFixtures.ngrokNoAuthtokenStderr + "\n")),
            (105, (DomainsShareFixtures.ngrokMalformedTokenStdoutErrors + "\n", DomainsShareFixtures.ngrokMalformedTokenStderr + "\n")),
            (107, ("", DomainsShareFixtures.ngrokRevokedTokenStderr + "\n")),
        ]
        for (code, message) in messages.sorted(by: { $0.key < $1.key }) {
            let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map { "ERROR:  \($0)" }
            let err = (["ERROR:  authentication failed: " + lines[0].dropFirst(8)] + lines.dropFirst()
                       + ["ERROR:  ", "ERROR:  ERR_NGROK_\(code)", "ERROR:  https://ngrok.com/docs/errors/err_ngrok_\(code)", "ERROR:  "]).joined(separator: "\n")
            list.append((code, (stdout(code, message), err + "\n")))
        }
        return list.map { (code: $0.0, text: (stdout: $0.1.0, stderr: $0.1.1)) }
    }

    static let offlineLine = #"{"t":"2026-11-06T10:31:07+0530","lvl":"eror","msg":"failed to reconnect session","obj":"tunnels.session","err":"failed to dial ngrok server with address \"connect.ngrok-agent.com:443\": dial tcp: lookup connect.ngrok-agent.com: no such host"}"#

    static let script = #"""
    #!/bin/sh
    # Stand in for the ngrok agent 3. Mode in ngrok.mode next to this file.
    D=$(cd "$(dirname "$0")" && pwd)
    MODE=$(cat "$D/ngrok.mode" 2>/dev/null || echo ok)
    printf '%s\n' "$*" >> "$D/ngrok.calls"
    if [ "$1" = "version" ]; then echo "ngrok version 3.39.13"; exit 0; fi
    printf '%s' "${NGROK_AUTHTOKEN-<unset>}" > "$D/ngrok.token"
    echo $$ > "$D/ngrok.pid"
    T='"t":"2026-11-06T10:31:06+0530"'
    fail() { cat "$D/fail-$1.out"; cat "$D/fail-$1.err" >&2; exit 1; }
    forever() { trap 'kill $sp 2>/dev/null; echo stopped > "$D/ngrok.exit"; exit 0' TERM INT; sleep 600 & sp=$!; wait $sp; }
    URL=https://ab12-34-56.ngrok-free.app
    prev=""; for a in "$@"; do [ "$prev" = "--url" ] && URL=$a; prev=$a; done
    WEB=127.0.0.1:4040
    [ "$MODE" = api ] && WEB=127.0.0.1:$(cat "$D/api.port")
    printf '{%s,"lvl":"info","msg":"no configuration paths supplied"}\n' "$T"
    printf '{%s,"lvl":"info","msg":"starting web service","obj":"web","addr":"%s","allow_hosts":null}\n' "$T" "$WEB"
    case "$MODE" in
      ok) ;;
      auth)
        tok=${NGROK_AUTHTOKEN-}
        if [ -z "$tok" ]; then fail 4018
        elif [ "$tok" = "$(cat "$D/ngrok.validtoken")" ]; then :
        else case "$tok" in *bad*) fail 105;; *) fail 107;; esac
        fi ;;
      108|334|121) fail "$MODE" ;;
      offline)
        trap 'exit 0' TERM INT
        while :; do
          printf '{%s,"lvl":"eror","msg":"failed to reconnect session","obj":"tunnels.session","err":"failed to dial ngrok server with address \\"connect.ngrok-agent.com:443\\": dial tcp: lookup connect.ngrok-agent.com: no such host"}\n' "$T"
          sleep 0.5
        done ;;
      api) forever ;;
      echo) echo "token is $NGROK_AUTHTOKEN"; exit 1 ;;
    esac
    printf '{%s,"lvl":"info","msg":"client session established","obj":"tunnels.session"}\n' "$T"
    printf '{%s,"lvl":"info","msg":"started tunnel","obj":"tunnels","name":"command_line","addr":"http://%s","url":"%s"}\n' "$T" "$2" "$URL"
    forever
    """#
}

enum TailscaleFakeOutput {
    static func statusRunning(state: String = "Running", version: String = "1.104.5-t2b7f3c1a4-g9e8d7c6b5",
                              caps: [String] = ["https", "funnel"], ports: String = "443,8443,10000") -> String {
        var capMap = caps.map { "\"\($0)\": null" }
        capMap.append("\"https://tailscale.com/cap/funnel-ports?ports=\(ports)\": null")
        capMap.append("\"https://tailscale.com/cap/file-sharing\": null")
        return """
        {
          "Version": "\(version)",
          "TUN": false,
          "BackendState": "\(state)",
          "HaveNodeKey": true,
          "AuthURL": "",
          "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1111:2222"],
          "Self": {
            "ID": "nFAKE7CNTRL",
            "PublicKey": "nodekey:0000000000000000000000000000000000000000000000000000000000000000",
            "HostName": "mac",
            "DNSName": "mac.tail1234.ts.net.",
            "OS": "macOS",
            "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1111:2222"],
            "Online": true,
            "Capabilities": [\(caps.map { "\"\($0)\"" }.joined(separator: ", "))],
            "CapMap": { \(capMap.joined(separator: ", ")) }
          },
          "Health": [],
          "MagicDNSSuffix": "tail1234.ts.net",
          "CurrentTailnet": { "Name": "person@example.com", "MagicDNSSuffix": "tail1234.ts.net", "MagicDNSEnabled": true },
          "CertDomains": ["mac.tail1234.ts.net"]
        }
        """
    }

    static let statusLoggedOut = """
    {
      "Version": "1.104.5-t2b7f3c1a4-g9e8d7c6b5",
      "BackendState": "NeedsLogin",
      "AuthURL": "https://login.tailscale.com/a/1a2b3c4d5e",
      "TailscaleIPs": null,
      "Self": { "ID": "", "HostName": "mac", "DNSName": "", "OS": "macOS", "Online": false },
      "CurrentTailnet": null
    }
    """

    // Messages as the Tailscale CLI prints them (cmd/tailscale/cli, client/local, ipn/serve.go).
    static let daemonDown = "Failed to connect to local Tailscale daemon for /localapi/v0/status; not running? Error: dial unix /var/run/tailscaled.socket: connect: no such file or directory"
    static let noHTTPS = "Funnel not available; HTTPS must be enabled. See https://tailscale.com/s/https."
    static let noAttribute = #"Funnel not available; "funnel" node attribute not set. See https://tailscale.com/s/no-funnel."#
    static let enableFunnel = "\nFunnel is not enabled on your tailnet.\nTo enable, visit:\n\n         https://login.tailscale.com/f/funnel?node=nFAKE7CNTRL\n\n"
    static let nodeNotInPolicy = "\nFunnel is enabled, but the list of allowed nodes in the tailnet policy file does not include the one you are using.\nTo give access to this node you can edit the tailnet policy file, or visit:\n\n         https://login.tailscale.com/f/funnel?node=nFAKE7CNTRL\n\n"

    static func started(url: String, target: String) -> String {
        "Available on the internet:\n\n\(url)\n|-- proxy \(target)\n\nPress Ctrl+C to exit.\n"
    }

    /// Keeps background funnels as ts/bg-<port> and foreground ones as ts/fg-<port>, each holding
    /// its proxy target. A foreground funnel file goes away when the command ends, as in tailscaled.
    static let script = #"""
    #!/bin/sh
    # Stand in for the tailscale CLI 1.104. State and mode in ts/ next to this file.
    D=$(cd "$(dirname "$0")" && pwd)
    S="$D/ts"
    MODE=$(cat "$S/mode" 2>/dev/null || echo ok)
    HOST=mac.tail1234.ts.net
    printf '%s\n' "$*" >> "$S/calls"
    if [ "$MODE" = down ]; then
      echo "Failed to connect to local Tailscale daemon for /localapi/v0/status; not running? Error: dial unix /var/run/tailscaled.socket: connect: no such file or directory" >&2
      exit 1
    fi
    obj() {
      tcp=""; web=""; allow=""
      for f in "$@"; do
        [ -e "$f" ] || continue
        p=${f##*-}; t=$(cat "$f")
        tcp="$tcp${tcp:+,}\"$p\":{\"HTTPS\":true}"
        web="$web${web:+,}\"$HOST:$p\":{\"Handlers\":{\"/\":{\"Proxy\":\"$t\"}}}"
        allow="$allow${allow:+,}\"$HOST:$p\":true"
      done
      out=""
      [ -n "$tcp" ] && out="\"TCP\":{$tcp},\"Web\":{$web},\"AllowFunnel\":{$allow}"
      printf '%s' "$out"
    }
    case "$1" in
      version) echo "1.104.5"; exit 0 ;;
      status) cat "$S/status.json"; exit 0 ;;
      funnel) shift ;;
      *) echo "unknown command" >&2; exit 2 ;;
    esac
    if [ "$1" = status ]; then
      bg=$(obj "$S"/bg-*)
      fg=""
      for f in "$S"/fg-*; do [ -e "$f" ] || continue; fg="$fg${fg:+,}\"sess${f##*-}\":{$(obj "$f")}"; done
      body="$bg"
      [ -n "$fg" ] && body="$body${body:+,}\"Foreground\":{$fg}"
      printf '{%s}\n' "$body"
      exit 0
    fi
    if [ "$1" = reset ]; then rm -f "$S"/bg-*; exit 0; fi
    port=443; target=""; off=0
    for a in "$@"; do
      case "$a" in
        --https=*) port=${a#--https=} ;;
        off) off=1 ;;
        --bg) ;;
        *) target=$a ;;
      esac
    done
    if [ $off = 1 ]; then rm -f "$S/bg-$port"; exit 0; fi
    case "$MODE" in
      loggedout) echo "Logged out." >&2; exit 1 ;;
      noattr) echo 'Funnel not available; "funnel" node attribute not set. See https://tailscale.com/s/no-funnel.' >&2; exit 1 ;;
      busy) echo "listener already exists for port $port" >&2; exit 1 ;;
      portdenied) echo "port $port is not allowed for funnel; allowed ports are: 8443" >&2; exit 1 ;;
      enable)
        trap 'kill $sp 2>/dev/null; exit 0' TERM INT
        printf '\nFunnel is not enabled on your tailnet.\nTo enable, visit:\n\n         https://login.tailscale.com/f/funnel?node=nFAKE7CNTRL\n\n'
        sleep 600 & sp=$!; wait $sp; exit 0 ;;
    esac
    if [ -e "$S/bg-$port" ] || [ -e "$S/fg-$port" ]; then echo "listener already exists for port $port" >&2; exit 1; fi
    echo "$target" > "$S/fg-$port"
    [ "$MODE" = bgleak ] && echo "$target" > "$S/bg-$port"
    echo $$ > "$S/pid"
    trap 'kill $sp 2>/dev/null; rm -f "$S/fg-$port"; exit 0' TERM INT
    if [ "$port" = 443 ]; then url="https://$HOST/"; else url="https://$HOST:$port/"; fi
    printf 'Available on the internet:\n\n%s\n|-- proxy %s\n\nPress Ctrl+C to exit.\n' "$url" "$target"
    sleep 600 & sp=$!; wait $sp
    """#
}

enum CloudflareFakeOutput {
    /// cloudflared 2026 wraps request errors as "failed to request quick Tunnel" (cmd/cloudflared/tunnel/quick_tunnel.go).
    static let blocked = #"2026-11-06T05:01:02Z ERR Error requesting new tunnel error="failed to request quick Tunnel: Post \"https://api.trycloudflare.com/tunnel\": dial tcp: lookup api.trycloudflare.com: no such host""#

    static let script = #"""
    #!/bin/sh
    # Stand in for cloudflared. Prints the recorded quick tunnel output.
    D=$(cd "$(dirname "$0")" && pwd)
    MODE=$(cat "$D/cloudflared.mode" 2>/dev/null || echo ok)
    if [ "$1" = "--version" ]; then echo "cloudflared version 2026.3.0 (built 2026-03-10-1200 UTC)"; exit 0; fi
    printf '%s\n' "$*" >> "$D/cloudflared.calls"
    echo $$ > "$D/cloudflared.pid"
    trap 'kill $sp 2>/dev/null; exit 0' TERM INT
    case "$MODE" in
      ok) cat "$D/cloudflared.out" >&2 ;;
      blocked)
        echo '2026-11-06T05:01:02Z INF Requesting new quick Tunnel on trycloudflare.com...' >&2
        echo '2026-11-06T05:01:02Z ERR Error requesting new tunnel error="failed to request quick Tunnel: Post \"https://api.trycloudflare.com/tunnel\": dial tcp: lookup api.trycloudflare.com: no such host"' >&2
        exit 1 ;;
      silent) ;;
    esac
    sleep 600 & sp=$!; wait $sp
    """#
}
