import XCTest
import CryptoKit
@testable import DeckCore

// MARK: - HTTP stub

/// Scripted HTTP server for the kernel download. Each session gets its own script,
/// keyed by a header, and every request is recorded.
final class KernelStubProtocol: URLProtocol {
    enum Reply {
        /// Serves `data` and honours "Range: bytes=N-" with a 206.
        case serve(Data)
        /// Like `serve`, but ignores Range and always sends the whole file with a 200.
        case serveIgnoringRange(Data)
        /// Sends the first `bytes` of what `serve` would send, then fails.
        case drop(Data, after: Int, error: URLError.Code)
        /// Fails before any response.
        case fail(URLError.Code)
        case status(Int)
        /// Sends part of the file, then never finishes (for Cancel).
        case stall(Data, after: Int)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var recorded: [String: [URLRequest]] = [:]

    /// A configuration whose requests get `replies` in order. The last reply repeats.
    static func configuration(_ replies: [Reply]) -> (URLSessionConfiguration, String) {
        let key = UUID().uuidString
        lock.lock(); scripts[key] = replies; recorded[key] = []; lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KernelStubProtocol.self]
        config.httpAdditionalHeaders = ["X-Stub-Key": key]
        return (config, key)
    }

    static func requests(_ key: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded[key] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "X-Stub-Key") ?? ""
        Self.lock.lock()
        let index = Self.recorded[key]?.count ?? 0
        Self.recorded[key, default: []].append(request)
        let script = Self.scripts[key] ?? []
        Self.lock.unlock()
        guard let reply = script.isEmpty ? nil : script[min(index, script.count - 1)] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch reply {
        case .serve(let data):
            send(data, honourRange: true, limit: nil)
            client?.urlProtocolDidFinishLoading(self)
        case .serveIgnoringRange(let data):
            send(data, honourRange: false, limit: nil)
            client?.urlProtocolDidFinishLoading(self)
        case .drop(let data, let after, let code):
            send(data, honourRange: true, limit: after)
            // Fail a moment later, like a real connection. URLSession drops data that a
            // protocol loads right before failing in the same turn.
            let client = self.client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let code):
            respond(code, headers: [:])
            client?.urlProtocolDidFinishLoading(self)
        case .stall(let data, let after):
            send(data, honourRange: true, limit: after)
        }
    }

    override func stopLoading() {}

    private func send(_ data: Data, honourRange: Bool, limit: Int?) {
        var start = 0
        if honourRange, let range = request.value(forHTTPHeaderField: "Range"),
           range.hasPrefix("bytes="), let from = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            start = min(from, data.count)
        }
        let body = data.subdata(in: start..<data.count)
        if start > 0 {
            respond(206, headers: ["Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)", "Content-Length": "\(body.count)"])
        } else {
            respond(200, headers: ["Content-Length": "\(data.count)"])
        }
        let sent = limit.map { body.prefix($0) } ?? body
        if !sent.isEmpty { client?.urlProtocol(self, didLoad: Data(sent)) }
    }

    private func respond(_ status: Int, headers: [String: String]) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }
}

/// Collects progress stages from the installer.
private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [KernelInstallStage] = []
    var stages: [KernelInstallStage] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ stage: KernelInstallStage) { lock.lock(); items.append(stage); lock.unlock() }
    var downloads: [KernelDownloadProgress] {
        stages.compactMap { if case .downloading(let p) = $0 { return p } else { return nil } }
    }
}

// MARK: - Tests

final class KernelInstallerTests: XCTestCase {
    private let cli = "/usr/local/bin/container"
    private let member = "opt/kata/share/kata-containers/vmlinux-6.18.56-208-debug"
    private let archiveURL = URL(string: "https://example.test/releases/download/4.3.1/kata-static-4.3.1-arm64.tar.zst")!
    private var folder: URL!

    /// The real error from the colleague's Mac (container 1.7.x, 9 Nov 2026).
    private let realMismatch = """
    Installing the recommended kernel from https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-arm64.tar.zst...
    Error: kernel archive digest mismatch: expected sha256:2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6, got sha256:bef140a1a96994029153dca8c00b1750b9a5a764fb9db2dc68d7bb40e8a29e8a
    """

    /// `container system property list --format json` from this Mac (container 1.6.1).
    private let properties161 = """
    {"build":{"cpus":2,"image":"ghcr.io/apple/container-builder-shim/builder:0.13.2","memory":"2048mb","rosetta":true},"container":{"cpus":4,"memory":"1gb"},"dns":{},"kernel":{"binaryPath":"opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug","digest":"sha256:8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5","url":"https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst"},"machine":{"cpus":5,"homeMount":"rw","memory":"16gb","virtualization":false},"network":{},"registry":{"domain":"docker.io"},"vminit":{"image":"ghcr.io/apple/containerization/vminit:0.53.0"}}
    """

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("deck-kernel-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Helpers

    /// A small fake archive. The real one is 676 MB and never downloaded in tests.
    private func fakeArchive(_ size: Int = 300_000, seed: UInt8 = 7) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    private func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func source(for data: Data, size: Int64? = nil) -> KernelSource {
        KernelSource(url: archiveURL, digest: digest(data), binaryPath: member, expectedSize: size ?? Int64(data.count), origin: .installedTool)
    }

    private let fastPolicy = KernelDownloadPolicy(retries: 3, baseDelay: 0, idleTimeout: 5, resourceTimeout: 60, progressCredit: 10_000, progressInterval: 0)

    private func installer(_ runner: MockRunner, _ config: URLSessionConfiguration) -> KernelInstaller {
        KernelInstaller(cli: ContainerCLI(path: cli, runner: runner), directory: folder, configuration: config, policy: fastPolicy)
    }

    private func setKey(_ source: KernelSource) -> String {
        KernelInstaller.setArguments(archive: folder.appendingPathComponent(source.fileName), binaryPath: source.binaryPath)
            .joined(separator: " ")
    }

    private func runningRunner(_ source: KernelSource, setResult: CommandResult = CommandResult(exitCode: 0, stdout: "")) -> MockRunner {
        let runner = MockRunner()
        runner.responses["system status"] = CommandResult(exitCode: 0, stdout: "apiserver is running")
        runner.responses[setKey(source)] = setResult
        return runner
    }

    private func folderContents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    // MARK: Command construction

    func testSetArgumentsInstallTheLocalArchive() {
        let archive = URL(fileURLWithPath: "/Users/me/Library/Application Support/io.github.sur950.containerdeck/Kernel/kata-static-4.3.1-arm64.tar.zst")
        XCTAssertEqual(
            KernelInstaller.setArguments(archive: archive, binaryPath: member),
            ["system", "kernel", "set", "--tar", archive.path, "--binary", member, "--force"]
        )
    }

    func testInstallRunsKernelSetWithTheDownloadedFile() async throws {
        let data = fakeArchive()
        let src = source(for: data)
        let (config, key) = KernelStubProtocol.configuration([.serve(data)])
        let runner = runningRunner(src)
        try await installer(runner, config).install(source: src) { _ in }

        let set = try XCTUnwrap(runner.calls.first { $0.contains("kernel") })
        XCTAssertEqual(set, [cli, "system", "kernel", "set", "--tar", folder.appendingPathComponent("kata-static-4.3.1-arm64.tar.zst").path,
                             "--binary", member, "--force"])
        XCTAssertFalse(set.contains("--recommended"))
        XCTAssertEqual(KernelStubProtocol.requests(key).count, 1)
        XCTAssertNil(KernelStubProtocol.requests(key).first?.value(forHTTPHeaderField: "Range"))
    }

    func testStartsTheServiceBeforeKernelSetWhenStopped() async throws {
        let data = fakeArchive()
        let src = source(for: data)
        let (config, _) = KernelStubProtocol.configuration([.serve(data)])
        let runner = runningRunner(src)
        runner.responses["system status"] = CommandResult(exitCode: 1, stdout: "apiserver is not running")
        runner.responses["system start --disable-kernel-install"] = CommandResult(exitCode: 0, stdout: "")
        try await installer(runner, config).install(source: src) { _ in }
        let args = runner.calls.map { $0.dropFirst().joined(separator: " ") }
        let start = try XCTUnwrap(args.firstIndex(of: "system start --disable-kernel-install"))
        let set = try XCTUnwrap(args.firstIndex(of: setKey(src)))
        XCTAssertLessThan(start, set)
    }

    // MARK: Recommended values

    func testRecommendedSourceComesFromTheInstalledTool() async {
        let runner = MockRunner()
        runner.responses["system property list --format json"] = CommandResult(exitCode: 0, stdout: properties161)
        let src = await installer(runner, .ephemeral).recommendedSource()
        XCTAssertEqual(src.origin, .installedTool)
        XCTAssertEqual(src.url.absoluteString, "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst")
        XCTAssertEqual(src.binaryPath, "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug")
        XCTAssertEqual(src.sha256Hex, "8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5")
        XCTAssertEqual(src.expectedSize, 696_573_576, "Known archives get their size from AppConfig")
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testRecommendedSourceFallsBackToAppConfigByVersion() async {
        let runner = MockRunner()
        runner.responses["system property list --format json"] = CommandResult(exitCode: 1, stdout: "", stderr: "Error: XPC connection error")
        runner.responses["--version"] = CommandResult(exitCode: 0, stdout: "container CLI version 1.7.1 (build: release, commit: abc)")
        let newer = await installer(runner, .ephemeral).recommendedSource()
        XCTAssertEqual(newer.origin, .builtIn)
        XCTAssertEqual(newer.digest, "sha256:2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6")
        XCTAssertEqual(newer.binaryPath, "opt/kata/share/kata-containers/vmlinux-6.18.56-208-debug")
        XCTAssertEqual(newer.expectedSize, 676_287_269)

        XCTAssertEqual(KernelSource.builtIn(for: SemanticVersion(1, 6, 1)).digest,
                       "sha256:8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5")
        XCTAssertEqual(KernelSource.builtIn(for: nil).url.absoluteString,
                       "https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-arm64.tar.zst")
    }

    func testPropertiesWithoutDigestAreNotUsed() {
        let props = [SystemProperty(key: "kernel.url", value: "https://example.test/k.tar.zst"),
                     SystemProperty(key: "kernel.binaryPath", value: "opt/kata/vmlinux")]
        XCTAssertNil(KernelSource.from(properties: props))
        let bad = props + [SystemProperty(key: "kernel.digest", value: "sha256:abc")]
        XCTAssertNil(KernelSource.from(properties: bad))
    }

    // MARK: Resume

    func testResumesAfterADroppedConnection() async throws {
        let data = fakeArchive()
        let src = source(for: data)
        let (config, key) = KernelStubProtocol.configuration([
            .drop(data, after: 120_000, error: .networkConnectionLost),
            .serve(data)
        ])
        let runner = runningRunner(src)
        let log = StageLog()
        try await installer(runner, config).install(source: src) { log.add($0) }

        let requests = KernelStubProtocol.requests(key)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Range"), "bytes=120000-")
        XCTAssertTrue(log.downloads.contains { $0.attempt == 2 }, "Progress says it resumed")
        XCTAssertEqual(log.downloads.last?.receivedBytes, Int64(data.count))
        XCTAssertEqual(log.downloads.last?.totalBytes, Int64(data.count))
        XCTAssertTrue(runner.calls.contains { $0.contains("kernel") }, "Installed after the resumed download passed its check")
    }

    func testStartsOverWhenTheServerIgnoresRange() async throws {
        let data = fakeArchive()
        let src = source(for: data)
        let (config, key) = KernelStubProtocol.configuration([
            .drop(data, after: 50_000, error: .networkConnectionLost),
            .serveIgnoringRange(data)
        ])
        try await installer(runningRunner(src), config).install(source: src) { _ in }
        XCTAssertEqual(KernelStubProtocol.requests(key).count, 2)
    }

    func testResumesAPartialFileFromAnEarlierTry() async throws {
        let data = fakeArchive()
        let src = source(for: data)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.prefix(200_000).write(to: folder.appendingPathComponent(src.fileName + ".part"))
        let (config, key) = KernelStubProtocol.configuration([.serve(data)])
        try await installer(runningRunner(src), config).install(source: src) { _ in }
        XCTAssertEqual(KernelStubProtocol.requests(key).first?.value(forHTTPHeaderField: "Range"), "bytes=200000-")
    }

    // MARK: Digest mismatch

    func testDamagedDownloadIsFetchedAgainFromScratch() async throws {
        let data = fakeArchive()
        var damaged = data
        damaged[1234] ^= 0xFF
        let src = source(for: data)
        let (config, key) = KernelStubProtocol.configuration([.serve(damaged), .serve(data)])
        let log = StageLog()
        try await installer(runningRunner(src), config).install(source: src) { log.add($0) }
        let requests = KernelStubProtocol.requests(key)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Range"), "The retry starts from byte 0")
        XCTAssertTrue(log.downloads.contains { $0.isFreshRetry })
    }

    func testDamagedTwiceGivesThePlainErrorAndCleansUp() async throws {
        let data = fakeArchive()
        var damaged = data
        damaged[99] ^= 0x01
        let src = source(for: data)
        let (config, key) = KernelStubProtocol.configuration([.serve(damaged)])
        let runner = runningRunner(src)
        do {
            try await installer(runner, config).install(source: src) { _ in }
            XCTFail("Expected a damaged download")
        } catch let error as KernelInstallError {
            guard case .damaged(let details) = error else { return XCTFail("Got \(error)") }
            XCTAssertEqual(error.localizedDescription,
                           "The kernel download was damaged on the way, often by a VPN or proxy. Try again, or use another network.")
            XCTAssertTrue(details.contains("expected \(src.digest)"))
            XCTAssertTrue(details.contains("got \(digest(damaged))"))
        }
        XCTAssertEqual(KernelStubProtocol.requests(key).count, 2, "One retry from scratch, then stop")
        XCTAssertFalse(runner.calls.contains { $0.contains("kernel") }, "A damaged archive is never installed")
        XCTAssertTrue(folderContents().isEmpty, "Damaged files are deleted")
    }

    // MARK: Network errors

    func testOfflineAfterRetries() async throws {
        let data = fakeArchive()
        let src = source(for: data)
        let (config, key) = KernelStubProtocol.configuration([.fail(.notConnectedToInternet)])
        do {
            try await installer(runningRunner(src), config).install(source: src) { _ in }
            XCTFail("Expected offline")
        } catch let error as KernelInstallError {
            guard case .offline(let details) = error else { return XCTFail("Got \(error)") }
            XCTAssertTrue(details.contains("-1009"))
        }
        XCTAssertEqual(KernelStubProtocol.requests(key).count, 4, "First try and 3 retries")
    }

    func testTimeoutIsItsOwnMessage() async {
        let data = fakeArchive()
        let src = source(for: data)
        let (config, _) = KernelStubProtocol.configuration([.fail(.timedOut)])
        do {
            try await installer(runningRunner(src), config).install(source: src) { _ in }
            XCTFail("Expected a timeout")
        } catch let error as KernelInstallError {
            guard case .timedOut = error else { return XCTFail("Got \(error)") }
            XCTAssertFalse(error.message.contains(";"))
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testRetriesThatBringDataDoNotUseUpTheBudget() async throws {
        let data = fakeArchive(300_000)
        let src = source(for: data)
        // Five drops in a row, each after 50 KB of new data, then the rest.
        let drop = KernelStubProtocol.Reply.drop(data, after: 50_000, error: .networkConnectionLost)
        let (config, key) = KernelStubProtocol.configuration([drop, drop, drop, drop, drop, .serve(data)])
        try await installer(runningRunner(src), config).install(source: src) { _ in }
        XCTAssertEqual(KernelStubProtocol.requests(key).count, 6)
    }

    func testNotFoundIsNotRetried() async {
        let data = fakeArchive()
        let src = source(for: data)
        let (config, key) = KernelStubProtocol.configuration([.status(404)])
        do {
            try await installer(runningRunner(src), config).install(source: src) { _ in }
            XCTFail("Expected an HTTP error")
        } catch let error as KernelInstallError {
            XCTAssertEqual(error, .server(status: 404, details: error.details))
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertEqual(KernelStubProtocol.requests(key).count, 1)
    }

    // MARK: Cleanup

    func testArchiveIsDeletedAfterSuccess() async throws {
        let data = fakeArchive()
        let src = source(for: data)
        let (config, _) = KernelStubProtocol.configuration([.serve(data)])
        try await installer(runningRunner(src), config).install(source: src) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "The download folder is removed after install")
    }

    func testFailedInstallKeepsTheCheckedArchiveForTryAgain() async throws {
        let data = fakeArchive()
        let src = source(for: data)
        let (config, key) = KernelStubProtocol.configuration([.serve(data)])
        let runner = runningRunner(src, setResult: CommandResult(exitCode: 1, stdout: "", stderr: "Error: failed to install kernel: permission denied"))
        do {
            try await installer(runner, config).install(source: src) { _ in }
            XCTFail("Expected the install step to fail")
        } catch let error as KernelInstallError {
            guard case .installFailed(let details) = error else { return XCTFail("Got \(error)") }
            XCTAssertTrue(details.hasPrefix("$ container system kernel set --tar "))
            XCTAssertTrue(details.contains("permission denied"))
        }
        XCTAssertEqual(folderContents(), [src.fileName])

        // Try Again: no second download, the archive is checked and installed, then removed.
        runner.responses[setKey(src)] = CommandResult(exitCode: 0, stdout: "")
        try await installer(runner, config).install(source: src) { _ in }
        XCTAssertEqual(KernelStubProtocol.requests(key).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testNetworkFailureKeepsThePartialFileForResume() async {
        let data = fakeArchive()
        let src = source(for: data)
        // The first try brings data, then three tries in a row bring none.
        let (config, _) = KernelStubProtocol.configuration([
            .drop(data, after: 80_000, error: .networkConnectionLost),
            .fail(.notConnectedToInternet)
        ])
        do {
            try await installer(runningRunner(src), config).install(source: src) { _ in }
            XCTFail("Expected offline")
        } catch {}
        XCTAssertEqual(folderContents(), [src.fileName + ".part"])
        XCTAssertEqual(KernelDownloader.fileSize(folder.appendingPathComponent(src.fileName + ".part")), 80_000)
    }

    func testCancelStopsTheDownloadAndDeletesIt() async throws {
        let data = fakeArchive()
        let src = source(for: data)
        let (config, _) = KernelStubProtocol.configuration([.stall(data, after: 40_000)])
        let runner = runningRunner(src)
        let installer = installer(runner, config)
        let gotBytes = expectation(description: "bytes arrived")
        gotBytes.assertForOverFulfill = false
        let task = Task {
            try await installer.install(source: src) { stage in
                if case .downloading(let p) = stage, p.receivedBytes > 0 { gotBytes.fulfill() }
            }
        }
        await fulfillment(of: [gotBytes], timeout: 10)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(runner.calls.contains { $0.contains("kernel") })
    }

    func testLeftoverDownloadsAreRemoved() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("old.tar.zst.part"))
        KernelInstaller.removeLeftoverDownloads(directory: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Reading the CLI's errors

    func testParsesTheRealDigestMismatchMessage() {
        let mismatch = KernelDigestMismatch.parse(realMismatch)
        XCTAssertEqual(mismatch?.expected, "sha256:2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6")
        XCTAssertEqual(mismatch?.actual, "sha256:bef140a1a96994029153dca8c00b1750b9a5a764fb9db2dc68d7bb40e8a29e8a")

        let error = KernelInstallError.fromCLI(CommandResult(exitCode: 1, stdout: "", stderr: realMismatch),
                                               command: "container system kernel set --recommended")
        guard case .damaged(let details) = error else { return XCTFail("Got \(error)") }
        XCTAssertEqual(error.message, KernelInstallError.damagedMessage)
        XCTAssertTrue(details.hasPrefix("$ container system kernel set --recommended\n"))
        XCTAssertTrue(details.contains("got sha256:bef140a1"))
        XCTAssertNil(KernelDigestMismatch.parse("Error: kernel not found"))
    }

    func testCLINetworkErrorsMapToPlainMessages() {
        let offline = KernelInstallError.fromCLI(
            CommandResult(exitCode: 1, stdout: "", stderr: "Error: The Internet connection appears to be offline."), command: "x")
        guard case .offline = offline else { return XCTFail("Got \(offline)") }
        let slow = KernelInstallError.fromCLI(
            CommandResult(exitCode: 1, stdout: "", stderr: "Error: The request timed out."), command: "x")
        guard case .timedOut = slow else { return XCTFail("Got \(slow)") }
        let other = KernelInstallError.fromCLI(CommandResult(exitCode: 1, stdout: "", stderr: "Error: unsupported architecture"), command: "x")
        guard case .installFailed = other else { return XCTFail("Got \(other)") }
    }

    func testMessagesUsePlainCopy() {
        let errors: [KernelInstallError] = [
            .damaged(details: ""), .offline(details: ""), .timedOut(details: ""), .server(status: 503, details: ""),
            .diskFull(neededBytes: 976_000_000), .installFailed(details: "")
        ]
        for error in errors {
            XCTAssertFalse(error.message.contains(";"), error.message)
            XCTAssertFalse(error.message.contains("\u{2014}"), error.message)
            XCTAssertFalse(error.message.contains("\u{2013}"), error.message)
        }
    }

    // MARK: Progress text

    func testProgressText() {
        let p = KernelDownloadProgress(receivedBytes: 312_400_000, totalBytes: 676_287_269, bytesPerSecond: 8_400_000)
        XCTAssertEqual(p.sizeText, "312 MB of 676 MB")
        XCTAssertEqual(p.speedText, "8.4 MB/s")
        XCTAssertEqual(p.fraction ?? 0, 0.4619, accuracy: 0.001)
        XCTAssertEqual(KernelDownloadProgress(receivedBytes: 0, totalBytes: 0, bytesPerSecond: 640_000).speedText, "640 KB/s")
        XCTAssertEqual(KernelDownloadProgress(receivedBytes: 0, totalBytes: 0, bytesPerSecond: 23_500_000).speedText, "23 MB/s")
        XCTAssertNil(KernelDownloadProgress(receivedBytes: 5_000_000, totalBytes: 0, bytesPerSecond: 0).speedText)
        XCTAssertEqual(KernelDownloadProgress(receivedBytes: 5_000_000, totalBytes: 0, bytesPerSecond: 0).sizeText, "5 MB")
    }

    func testContentRangeParsing() {
        XCTAssertEqual(KernelHTTPFetch.contentRange("bytes 100-199/1000")?.start, 100)
        XCTAssertEqual(KernelHTTPFetch.contentRange("bytes 100-199/1000")?.total, 1000)
        XCTAssertNil(KernelHTTPFetch.contentRange("bytes 5-9/*")?.total)
        XCTAssertNil(KernelHTTPFetch.contentRange("items 1-2/3"))
        XCTAssertNil(KernelHTTPFetch.contentRange(nil))
    }

    func testSpeedMeter() {
        let meter = SpeedMeter()
        XCTAssertEqual(meter.add(0, at: 10), 0)
        XCTAssertEqual(meter.add(2_000_000, at: 11), 2_000_000, accuracy: 1)
        XCTAssertEqual(meter.add(6_000_000, at: 12), 3_000_000, accuracy: 1)
    }
}

// MARK: - Live (DECK_LIVE_KERNEL=1)

/// Off unless DECK_LIVE_KERNEL=1. Downloads the real 676 MB archive and REPLACES this
/// Mac's default kernel with `container system kernel set`. Run it only on a test Mac.
final class KernelInstallerLiveTests: XCTestCase {
    func testLiveDownloadAndInstall() async throws {
        guard ProcessInfo.processInfo.environment["DECK_LIVE_KERNEL"] == "1" else {
            throw XCTSkip("Set DECK_LIVE_KERNEL=1 to download the real kernel and replace this Mac's default kernel.")
        }
        let path = "/usr/local/bin/container"
        guard FileManager.default.isExecutableFile(atPath: path) else { throw XCTSkip("No container CLI at \(path).") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deck-kernel-live", isDirectory: true)
        let installer = KernelInstaller(cli: ContainerCLI(path: path, runner: ProcessRunner()), directory: folder)
        let source = await installer.recommendedSource()
        XCTAssertNotNil(source.sha256Hex)
        try await installer.install(source: source) { stage in
            if case .downloading(let p) = stage, p.receivedBytes % 50_000_000 < 2_000_000 {
                print("kernel:", p.sizeText, p.speedText ?? "")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
