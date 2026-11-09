import XCTest
@testable import DeckCore

/// Output recorded from a real Mac (container CLI 1.6.1, macOS 27.2, Apple silicon).
/// The live tests at the bottom run only with DECK_LIVE_CLI=1 and a running service.
final class RealCLISystemTests: XCTestCase {

    // MARK: - Recorded output (container 1.6.1)

    static let versionOutput = "container CLI version 1.6.1 (build: release, commit: aa8d76b)\n"

    static let statusTable = """
    FIELD               VALUE
    status              running
    client.version      1.6.1
    client.build        release
    client.commit       aa8d76b44a834eee3ebf6a0bc577e376f65f6361
    host.os             Version 27.2 (Build 26B123)
    host.architecture   arm64
    host.cpus           10
    server.version      1.6.1
    server.build        release
    server.commit       aa8d76b44a834eee3ebf6a0bc577e376f65f6361
    server.appName      container-apiserver
    paths.appRoot       /Users/suresh/Library/Application Support/com.apple.container/
    paths.installRoot   /usr/local/
    paths.logRoot
    containers.total    2
    containers.running  2
    images.total        4

    """

    /// 1.6.1 prints this and exits 1 when the API server is not answering.
    static let statusNotRunning = "apiserver is not running\n"
    /// And this, also with exit 1, when it is not registered with launchd.
    static let statusUnregistered = "apiserver is not running and not registered with launchd\n"

    static let dnsListEmpty = "DOMAIN\n"

    static let systemDF = """
    {
      "containers" : {
        "active" : 3,
        "reclaimable" : 0,
        "sizeInBytes" : 760635392,
        "total" : 3
      },
      "images" : {
        "active" : 3,
        "reclaimable" : 278654976,
        "sizeInBytes" : 497217536,
        "total" : 4
      },
      "volumes" : {
        "active" : 2,
        "reclaimable" : 42213376,
        "sizeInBytes" : 84393984,
        "total" : 4
      }
    }
    """

    static let statsJSON = """
    [{"blockReadBytes":1679360,"blockWriteBytes":0,"cpuUsageUsec":1886,"id":"deck-test-ctr-b","memoryLimitBytes":1073741824,"memoryUsageBytes":1941504,"networkRxBytes":10006,"networkTxBytes":602,"numProcesses":1},{"blockReadBytes":10646528,"blockWriteBytes":147456,"cpuUsageUsec":30921,"id":"deck-test-ctr-web","memoryLimitBytes":536870912,"memoryUsageBytes":15151104,"networkRxBytes":61489,"networkTxBytes":2158,"numProcesses":4}]
    """

    /// Trimmed GitHub answer for apple/container releases/latest. Note the
    /// unsigned package name also contains "signed".
    static let platformReleaseJSON = """
    {"tag_name":"1.6.1","name":"1.6.1","prerelease":false,"draft":false,"assets":[
      {"name":"container-installer-unsigned.pkg","size":152680743,"browser_download_url":"https://github.com/apple/container/releases/download/1.6.1/container-installer-unsigned.pkg"},
      {"name":"container-dSYM.zip","size":159694938,"browser_download_url":"https://github.com/apple/container/releases/download/1.6.1/container-dSYM.zip"},
      {"name":"container-1.6.1-installer-signed.pkg","size":155965213,"browser_download_url":"https://github.com/apple/container/releases/download/1.6.1/container-1.6.1-installer-signed.pkg"}
    ]}
    """

    // MARK: - CLI wrapper

    private let cliPath = "/usr/local/bin/container"

    func testVersionParses161() async throws {
        let runner = MockRunner()
        runner.responses["--version"] = CommandResult(exitCode: 0, stdout: Self.versionOutput)
        let version = try await ContainerCLI(path: cliPath, runner: runner).version()
        XCTAssertEqual(version, SemanticVersion(1, 6, 1))
    }

    func testServiceRunningFromStatusTable() async throws {
        let runner = MockRunner()
        runner.responses["system status"] = CommandResult(exitCode: 0, stdout: Self.statusTable)
        let running = try await ContainerCLI(path: cliPath, runner: runner).isServiceRunning()
        XCTAssertTrue(running)
    }

    func testServiceStoppedShapes() async throws {
        for text in [Self.statusNotRunning, Self.statusUnregistered] {
            let runner = MockRunner()
            runner.responses["system status"] = CommandResult(exitCode: 1, stdout: text)
            let running = try await ContainerCLI(path: cliPath, runner: runner).isServiceRunning()
            XCTAssertFalse(running, text)
        }
        // Same text with exit 0 must still read as stopped.
        let runner = MockRunner()
        runner.responses["system status"] = CommandResult(exitCode: 0, stdout: Self.statusNotRunning)
        let running = try await ContainerCLI(path: cliPath, runner: runner).isServiceRunning()
        XCTAssertFalse(running)
    }

    func testDNSListShapes() async throws {
        let empty = MockRunner()
        empty.responses["system dns list"] = CommandResult(exitCode: 0, stdout: Self.dnsListEmpty)
        let none = try await ContainerCLI(path: cliPath, runner: empty).dnsDomains()
        XCTAssertEqual(none, [])

        let one = MockRunner()
        one.responses["system dns list"] = CommandResult(exitCode: 0, stdout: "DOMAIN\ntest\n")
        let domains = try await ContainerCLI(path: cliPath, runner: one).dnsDomains()
        XCTAssertEqual(domains, ["test"])
    }

    // MARK: - Setup checks with the real shapes

    func testSetupReportOnThisMacShape() async {
        let appRoot = "/Users/me/Library/Application Support/com.apple.container"
        let files = FileSystem(
            fileExists: { path in
                path == "/usr/local/bin/container" || SetupService.rosettaPaths.contains(path)
            },
            isExecutable: { $0 == "/usr/local/bin/container" },
            contentsOfDirectory: { path in
                // Real listing: a symlink plus the versioned kernel.
                path == appRoot + "/kernels" ? ["default.kernel-arm64", "vmlinux-6.18.35-197-debug"] : []
            }
        )
        let runner = MockRunner()
        runner.responses["--version"] = CommandResult(exitCode: 0, stdout: Self.versionOutput)
        runner.responses["system status"] = CommandResult(exitCode: 0, stdout: Self.statusTable)
        runner.responses["system dns list"] = CommandResult(exitCode: 0, stdout: Self.dnsListEmpty)
        let env = SetupEnvironment(
            system: SystemInfo(isAppleSilicon: true, osMajor: 27, osMinor: 2),
            files: files, pathEnv: "/usr/bin:/bin", customCLIPath: nil, appRoot: appRoot
        )
        let report = await SetupService(runner: runner, environment: env).runChecks()
        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.cliVersion, SemanticVersion(1, 6, 1))
        XCTAssertTrue(report.serviceRunning)
        XCTAssertEqual(report.check(.kernel)?.state, .ok("Installed"))
        XCTAssertEqual(report.check(.rosetta)?.state, .ok("Installed"))
        XCTAssertEqual(report.check(.dns)?.fix, .createDNSDomain)
        XCTAssertEqual(report.check(.terminalCommand)?.state.isPassing, true)
    }

    // MARK: - Dashboard data

    func testSystemDFParses() throws {
        let usage = try ContainerOutputParser.diskUsage(Self.systemDF)
        XCTAssertEqual(usage.images.total, 4)
        XCTAssertEqual(usage.images.active, 3)
        XCTAssertEqual(usage.images.sizeBytes, 497_217_536)
        XCTAssertEqual(usage.images.reclaimableBytes, 278_654_976)
        XCTAssertEqual(usage.containers.sizeBytes, 760_635_392)
        XCTAssertEqual(usage.containers.reclaimableBytes, 0)
        XCTAssertEqual(usage.volumes.total, 4)
        XCTAssertEqual(usage.totalBytes, 497_217_536 + 760_635_392 + 84_393_984)
        XCTAssertEqual(usage.reclaimableBytes, 278_654_976 + 42_213_376)
    }

    func testStatsParsesCPUTimeOnlyShape() throws {
        let cache = CPUSampleCache()
        let first = try ContainerOutputParser.stats(Self.statsJSON, cache: cache, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(first.count, 2)
        let web = try XCTUnwrap(first.first { $0.id == "deck-test-ctr-web" })
        XCTAssertEqual(web.memoryUsageBytes, 15_151_104)
        XCTAssertEqual(web.memoryLimitBytes, 536_870_912)
        XCTAssertEqual(web.pids, 4)
        XCTAssertEqual(web.netRxBytes, 61_489)
        XCTAssertEqual(web.cpuPercent, 0, accuracy: 0.001)

        // One second later the web container used 0.5 s of CPU, so 50 percent.
        let later = Self.statsJSON.replacingOccurrences(of: "\"cpuUsageUsec\":30921", with: "\"cpuUsageUsec\":530921")
        let second = try ContainerOutputParser.stats(later, cache: cache, now: Date(timeIntervalSince1970: 1001))
        let web2 = try XCTUnwrap(second.first { $0.id == "deck-test-ctr-web" })
        XCTAssertEqual(web2.cpuPercent, 50, accuracy: 0.5)
    }

    // MARK: - Platform installer

    func testInstallerPicksSignedPackageNotUnsigned() throws {
        let release = try PlatformInstaller.parseRelease(Data(Self.platformReleaseJSON.utf8))
        XCTAssertEqual(release.version, "1.6.1")
        XCTAssertEqual(release.packageName, "container-1.6.1-installer-signed.pkg")
    }

    func testSetupPicksNewestTestedReleaseNotLatest() throws {
        func entry(_ tag: String, prerelease: Bool = false) -> String {
            #"{"tag_name":"\#(tag)","draft":false,"prerelease":\#(prerelease),"assets":[{"name":"container-\#(tag)-installer-signed.pkg","browser_download_url":"https://example.com/\#(tag).pkg"}]}"#
        }
        let list = "[" + [entry("1.7.1"), entry("1.7.0"), entry("1.6.2-rc1", prerelease: true), entry("1.6.1"), entry("1.6.0")].joined(separator: ",") + "]"
        let release = try XCTUnwrap(PlatformInstaller.newestTested(Data(list.utf8), range: SemanticVersion(1, 4, 0)..<SemanticVersion(1, 7, 0)))
        XCTAssertEqual(release.version, "1.6.1", "1.7 is past the tested range, the release candidate is skipped")
        XCTAssertEqual(release.packageName, "container-1.6.1-installer-signed.pkg")
        XCTAssertNil(PlatformInstaller.newestTested(Data("[\(entry("1.7.1"))]".utf8), range: SemanticVersion(1, 4, 0)..<SemanticVersion(1, 7, 0)))
    }

    func testInstallerRejectsOnlyUnsigned() {
        let json = """
        {"tag_name":"1.6.1","assets":[{"name":"container-installer-unsigned.pkg","browser_download_url":"https://example.com/u.pkg"}]}
        """
        XCTAssertThrowsError(try PlatformInstaller.parseRelease(Data(json.utf8)))
    }

    // MARK: - Engines on a Mac where Rancher Desktop is installed but closed

    func testNerdctlHiddenWhenRancherIsClosed() async {
        let home = "/Users/me"
        let nerdctl = home + "/.rd/bin/nerdctl"
        let runner = MockRunner()
        for namespace in EngineDetector.nerdctlNamespaces {
            runner.responses[NerdctlEngine.imagesArguments(namespace: namespace).joined(separator: " ")] = CommandResult(
                exitCode: 1,
                stdout: "Rancher Desktop is not running. Please start Rancher Desktop to use nerdctl\n"
            )
        }
        let env = EngineEnvironment(
            home: home, dockerHost: nil,
            files: FileSystem(
                fileExists: { $0 == "/Applications/Rancher Desktop.app" || $0 == nerdctl },
                isExecutable: { $0 == nerdctl },
                contentsOfDirectory: { _ in [] }
            ),
            readFile: { _ in nil },
            resolvePath: { $0 }
        )
        let engines = await EngineDetector(environment: env, runner: runner).detect()
        XCTAssertFalse(engines.contains { $0.kind == .rancherContainerd })
        let rancher = engines.filter { $0.kind == .rancherDesktop }
        XCTAssertEqual(rancher.count, 1)
        XCTAssertEqual(rancher.first?.state, .stopped)
        XCTAssertFalse(engines.contains { $0.isRunning })
    }

    func testDanglingDockerSocketSymlinkIsNotRunning() async {
        // /var/run/docker.sock points at OrbStack's socket, which is gone while OrbStack is closed.
        // fileExists follows the link, so nothing is probed and OrbStack shows as installed but stopped.
        let home = "/Users/me"
        let env = EngineEnvironment(
            home: home, dockerHost: nil,
            files: FileSystem(
                fileExists: { $0 == "/Applications/OrbStack.app" },
                isExecutable: { _ in false },
                contentsOfDirectory: { _ in [] }
            ),
            readFile: { _ in nil },
            resolvePath: { $0 == "/var/run/docker.sock" ? home + "/.orbstack/run/docker.sock" : $0 }
        )
        let engines = await EngineDetector(environment: env, runner: MockRunner()).detect()
        XCTAssertEqual(engines.first { $0.kind == .orbStack }?.state, .stopped)
        XCTAssertEqual(engines.first { $0.kind == .dockerDesktop }?.state, .notFound)
        XCTAssertEqual(engines.filter { $0.kind == .orbStack }.count, 1)
    }

    func testImageLoadArguments() async throws {
        let runner = MockRunner()
        runner.responses["image load --input /tmp/x/oci-image.tar"] = CommandResult(exitCode: 0, stdout: "docker.io/library/a:1\n")
        let client = ContainerClient(cliPath: cliPath, runner: runner)
        try await client.loadImage(from: URL(fileURLWithPath: "/tmp/x/oci-image.tar"))
        XCTAssertEqual(runner.calls.last?.dropFirst().joined(separator: " "), "image load --input /tmp/x/oci-image.tar")
    }

    // MARK: - Update checker

    func testUpdateChecker404IsNoRelease() async {
        let checker = UpdateChecker(repository: "example/none", session: StubURLProtocol.session(status: 404, body: #"{"message":"Not Found"}"#))
        do {
            _ = try await checker.latestRelease()
            XCTFail("Expected an error")
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, .noRelease)
            XCTAssertEqual(error.errorDescription, UpdateCheckError.noRelease.errorDescription)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testUpdateCheckerRateLimit() async {
        for code in [403, 429] {
            let checker = UpdateChecker(repository: "example/limited", session: StubURLProtocol.session(status: code, body: "{}"))
            do {
                _ = try await checker.latestRelease()
                XCTFail("Expected an error")
            } catch let error as UpdateCheckError {
                XCTAssertEqual(error.errorDescription, "GitHub is limiting requests right now. Try again later.")
            } catch {
                XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testUpdateCheckerToleratesNullsAndMissingAssets() throws {
        let json = """
        {"tag_name":"v0.2.0","name":null,"body":null,"html_url":"https://github.com/o/r/releases/tag/v0.2.0","published_at":null,"prerelease":false}
        """
        let release = try UpdateChecker.parseRelease(Data(json.utf8))
        XCTAssertEqual(release.version, ReleaseVersion(0, 2, 0))
        XCTAssertEqual(release.title, "Container Deck 0.2.0")
        XCTAssertNil(release.diskImage)
        XCTAssertEqual(release.downloadURL.absoluteString, "https://github.com/o/r/releases/tag/v0.2.0")
    }

    // MARK: - Live (DECK_LIVE_CLI=1)

    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["DECK_LIVE_CLI"] == "1" else {
            throw XCTSkip("Set DECK_LIVE_CLI=1 to run against the real container CLI.")
        }
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            throw XCTSkip("No container CLI at \(cliPath).")
        }
    }

    func testLiveSetupChecks() async throws {
        try requireLive()
        let report = await SetupService(runner: ProcessRunner(), environment: .live(customCLIPath: nil)).runChecks()
        for check in report.checks {
            print("LIVE setup \(check.id.rawValue): \(check.state)")
        }
        XCTAssertEqual(report.cliPath, cliPath)
        XCTAssertNotNil(report.cliVersion)
        XCTAssertTrue(report.serviceRunning)
        XCTAssertEqual(report.check(.kernel)?.state.isPassing, true)
    }

    func testLiveDiskUsageAndStatus() async throws {
        try requireLive()
        let client = ContainerClient(cliPath: cliPath)
        let usage = try await client.diskUsage()
        print("LIVE df images=\(usage.images) containers=\(usage.containers) volumes=\(usage.volumes)")
        XCTAssertGreaterThan(usage.totalBytes, 0)
    }

    func testLiveEngineDetection() async throws {
        try requireLive()
        let engines = await EngineDetector().detect()
        for engine in engines {
            print("LIVE engine \(engine.kind.rawValue) \(engine.name) \(engine.state.rawValue) \(engine.note ?? "")")
        }
        XCTAssertFalse(engines.isEmpty)
        for engine in engines where engine.isRunning {
            let images = try await EngineCatalog().images(in: engine)
            print("LIVE \(engine.name) has \(images.count) images")
        }
    }

    /// Saves busybox, strips the names like a podman OCI archive, then runs our
    /// normalize, pack and `image load` path and checks the image gets our name.
    func testLiveOCIArchiveLoadGetsName() async throws {
        try requireLive()
        let client = ContainerClient(cliPath: cliPath)
        let source = "docker.io/library/busybox:latest"
        guard try await client.listImages().contains(where: { $0.reference == source }) else {
            throw XCTSkip("busybox:latest is not pulled.")
        }
        let work = try Self.makeWork()
        defer { try? FileManager.default.removeItem(at: work) }

        let archive = work.appendingPathComponent("bb.tar")
        try await client.saveImage(source, to: archive)
        let layout = work.appendingPathComponent("layout", isDirectory: true)
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        try await ProcessRunner().run("/usr/bin/tar", ["-xf", archive.path, "-C", layout.path]).orThrow()

        // Podman style: only a bare tag in org.opencontainers.image.ref.name.
        let indexURL = layout.appendingPathComponent("index.json")
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        var manifests = try XCTUnwrap(root["manifests"] as? [[String: Any]])
        for i in manifests.indices { manifests[i]["annotations"] = [OCIArchive.ociRefNameKey: "latest"] }
        root["manifests"] = manifests
        try JSONSerialization.data(withJSONObject: root).write(to: indexURL)

        let target = "deck-import-probe:oci"
        XCTAssertTrue(try OCIArchive.normalizeOCILayout(at: layout, reference: target))
        let packed = work.appendingPathComponent("oci-image.tar")
        try await ProcessRunner().run("/usr/bin/env", EngineImporter.packArguments(layout: layout.path, output: packed.path)).orThrow()

        try await client.loadImage(from: packed)
        let full = ImageReference.normalize(target)
        let loaded = try await client.listImages().map(\.reference)
        XCTAssertTrue(loaded.contains(full), "Loaded: \(loaded)")
        try? await client.deleteImage(full)
    }

    /// Builds a classic docker-archive (manifest.json, uncompressed layer.tar)
    /// from busybox and runs our converter and `image load` on it.
    func testLiveDockerArchiveLoad() async throws {
        try requireLive()
        let client = ContainerClient(cliPath: cliPath)
        let source = "docker.io/library/busybox:latest"
        guard try await client.listImages().contains(where: { $0.reference == source }) else {
            throw XCTSkip("busybox:latest is not pulled.")
        }
        let fm = FileManager.default
        let work = try Self.makeWork()
        defer { try? fm.removeItem(at: work) }

        let archive = work.appendingPathComponent("bb.tar")
        try await client.saveImage(source, to: archive)
        let layout = work.appendingPathComponent("layout", isDirectory: true)
        try fm.createDirectory(at: layout, withIntermediateDirectories: true)
        try await ProcessRunner().run("/usr/bin/tar", ["-xf", archive.path, "-C", layout.path]).orThrow()
        let blobs = layout.appendingPathComponent("blobs/sha256")
        func json(_ digest: String) throws -> [String: Any] {
            let data = try Data(contentsOf: blobs.appendingPathComponent(OCIArchive.encoded(digest)))
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        // index.json -> image index -> arm64 manifest present in the archive.
        let indexRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: layout.appendingPathComponent("index.json"))) as? [String: Any])
        let outer = try XCTUnwrap((indexRoot["manifests"] as? [[String: Any]])?.first?["digest"] as? String)
        let nested = try json(outer)
        let arm = try XCTUnwrap((nested["manifests"] as? [[String: Any]])?.first { entry in
            let platform = entry["platform"] as? [String: Any]
            let digest = entry["digest"] as? String ?? ""
            return platform?["architecture"] as? String == "arm64"
                && fm.fileExists(atPath: blobs.appendingPathComponent(OCIArchive.encoded(digest)).path)
        })
        let manifest = try json(try XCTUnwrap(arm["digest"] as? String))
        let configDigest = try XCTUnwrap((manifest["config"] as? [String: Any])?["digest"] as? String)
        let layerDigests = try XCTUnwrap(manifest["layers"] as? [[String: Any]]).compactMap { $0["digest"] as? String }

        let docker = work.appendingPathComponent("docker", isDirectory: true)
        try fm.createDirectory(at: docker, withIntermediateDirectories: true)
        try fm.copyItem(at: blobs.appendingPathComponent(OCIArchive.encoded(configDigest)), to: docker.appendingPathComponent("config.json"))
        var layerPaths: [String] = []
        for (n, digest) in layerDigests.enumerated() {
            let folder = docker.appendingPathComponent("layer\(n)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let out = folder.appendingPathComponent("layer.tar")
            let gz = blobs.appendingPathComponent(OCIArchive.encoded(digest)).path
            let result = try await ProcessRunner().run("/bin/sh", ["-c", "/usr/bin/gunzip -c \"$1\" > \"$2\"", "sh", gz, out.path])
            try result.orThrow()
            layerPaths.append("layer\(n)/layer.tar")
        }
        let target = "deck-import-probe:docker"
        let entry: [String: Any] = ["Config": "config.json", "RepoTags": [target], "Layers": layerPaths]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: docker.appendingPathComponent("manifest.json"))
        XCTAssertEqual(OCIArchive.kind(ofExtracted: docker), .dockerArchive)

        let oci = work.appendingPathComponent("oci", isDirectory: true)
        try OCIArchive.convertDockerArchive(at: docker, to: oci, fallbackReference: target)
        let packed = work.appendingPathComponent("oci-image.tar")
        try await ProcessRunner().run("/usr/bin/env", EngineImporter.packArguments(layout: oci.path, output: packed.path)).orThrow()

        try await client.loadImage(from: packed)
        let full = ImageReference.normalize(target)
        let loaded = try await client.listImages().map(\.reference)
        XCTAssertTrue(loaded.contains(full), "Loaded: \(loaded)")
        try? await client.deleteImage(full)
    }

    private static func makeWork() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deck-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Answers every request with a fixed status and body.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
    private static let lock = NSLock()

    static func session(status: Int, body: String) -> URLSession {
        let key = UUID().uuidString
        lock.lock()
        responses[key] = (status, Data(body.utf8))
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Stub-Key": key]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "X-Stub-Key") ?? ""
        Self.lock.lock()
        let stub = Self.responses[key] ?? (500, Data())
        Self.lock.unlock()
        let url = request.url ?? URL(fileURLWithPath: "/")
        if let response = HTTPURLResponse(url: url, statusCode: stub.0, httpVersion: "HTTP/1.1", headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: stub.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
