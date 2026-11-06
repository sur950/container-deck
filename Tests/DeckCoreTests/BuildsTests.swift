import XCTest
@testable import DeckCore

/// Streams canned lines per call. A script can fail at the end or wait until cancelled.
private final class BuildTestStreamer: CommandStreaming, @unchecked Sendable {
    enum Ending { case success, failure(String), hang }

    var lines: [String]
    var ending: Ending
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var terminated = 0

    init(lines: [String], ending: Ending = .success) {
        self.lines = lines
        self.ending = ending
    }

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    var terminations: Int { lock.lock(); defer { lock.unlock() }; return terminated }

    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        lock.lock(); recorded.append(arguments); lock.unlock()
        let lines = self.lines
        let ending = self.ending
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            switch ending {
            case .success: continuation.finish()
            case .failure(let message): continuation.finish(throwing: DeckError.commandFailed(message))
            case .hang: break
            }
            continuation.onTermination = { [weak self] reason in
                guard let self, case .cancelled = reason else { return }
                self.lock.lock(); self.terminated += 1; self.lock.unlock()
            }
        }
    }
}

private func client(_ streamer: BuildTestStreamer, runner: MockRunner = MockRunner()) -> ContainerClient {
    ContainerClient(cliPath: "/usr/local/bin/container", runner: runner, streamer: streamer)
}

private func lines(_ text: String) -> [String] {
    text.components(separatedBy: "\n")
}

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("deck-builds-\(UUID().uuidString)", isDirectory: true)
    return url
}

/// Waits until the condition is true or the time runs out.
private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private let options = BuildOptions(contextDir: "/tmp/app", tags: ["deck-v2-bld-test:1", "deck-v2-bld-test:latest"],
                                   buildArgs: [EnvVar(key: "GREETING", value: "hey")], platform: "linux/amd64")

final class BuildsParserTests: XCTestCase {
    func testStepsFromRecordedBuild() {
        let steps = lines(BuildsFixtures.buildOK).compactMap(BuildProgressParser.step(in:))
        XCTAssertEqual(steps.first, BuildProgressParser.Step(index: 1, count: 2, title: "RUN echo \"hey from $(uname -m)\" > /greeting.txt"))
        XCTAssertNil(BuildProgressParser.step(in: "#2 [internal] load build definition from Dockerfile"))
        XCTAssertNil(BuildProgressParser.step(in: "#1 [resolver] fetching image...docker.io/library/alpine:3.20"))
        XCTAssertEqual(BuildProgressParser.step(in: "#7 [build 3/5] COPY . .")?.index, 3)
        XCTAssertEqual(BuildProgressParser.step(in: "#7 [build 3/5] COPY . .")?.count, 5)
    }

    func testBuiltReference() {
        XCTAssertEqual(BuildProgressParser.builtReference(in: lines(BuildsFixtures.buildOK)), "docker.io/library/deck-v2-bld-ok:arm")
        XCTAssertNil(BuildProgressParser.builtReference(in: lines(BuildsFixtures.buildFailed)))
    }

    func testFailureMessage() {
        let message = BuildProgressParser.failureMessage(in: lines(BuildsFixtures.buildFailed))
        XCTAssertEqual(message, #"process "/bin/sh -c echo \"about to fail\" && exit 3" did not complete successfully: exit code: 3"#)
        XCTAssertEqual(BuildProgressParser.failureMessage(in: [#"Error: interrupted: "exiting on signal 15""#]), "exiting on signal 15")
        XCTAssertEqual(BuildProgressParser.failureMessage(in: ["#5 ERROR: failed to read dockerfile"]), "failed to read dockerfile")
        XCTAssertNil(BuildProgressParser.failureMessage(in: ["#5 DONE 0.1s"]))
    }

    func testBuilderStatusRecorded() throws {
        let status = try BuildsOutputParser.builderStatus(BuildsFixtures.builderStatus)
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.id, "buildkit")
        XCTAssertEqual(status.image, "ghcr.io/apple/container-builder-shim/builder:0.13.2")
        XCTAssertEqual(status.shortImage, "builder:0.13.2")
        XCTAssertEqual(status.cpus, 2)
        XCTAssertEqual(status.memoryBytes, 2_147_483_648)
        XCTAssertEqual(status.rosetta, true)
        XCTAssertNotNil(status.address)
        XCTAssertFalse(status.address?.contains("/") ?? true, "Prefix length is cut off")
        XCTAssertNotNil(status.startedAt)
    }

    func testBuilderStatusShapes() throws {
        XCTAssertEqual(try BuildsOutputParser.builderStatus("[]").state, .notCreated)
        XCTAssertEqual(try BuildsOutputParser.builderStatus("").state, .notCreated)
        let old = #"[{"id":"buildkit","status":"stopped","configuration":{"resources":{"cpus":4}}}]"#
        let status = try BuildsOutputParser.builderStatus(old)
        XCTAssertEqual(status.state, .stopped)
        XCTAssertEqual(status.cpus, 4)
        XCTAssertEqual(try BuildsOutputParser.builderStatus(#"[{"status":{"state":"booting"}}]"#).state, .unknown)
        XCTAssertThrowsError(try BuildsOutputParser.builderStatus("builder is not running"))
    }

    func testCacheUsageRecorded() throws {
        let usage = try BuildsOutputParser.cacheUsage(BuildsFixtures.cacheUsage)
        XCTAssertEqual(usage.entries, 9)
        XCTAssertEqual(usage.totalBytes, 39_254_474)
        XCTAssertEqual(usage.reclaimableBytes, 39_254_474)
        XCTAssertEqual(usage.inUseEntries, 0)
        XCTAssertNotNil(usage.lastUsedAt)
    }

    func testCacheUsageEdgeCases() throws {
        XCTAssertEqual(try BuildsOutputParser.cacheUsage("null"), BuildCacheUsage())
        XCTAssertEqual(try BuildsOutputParser.cacheUsage(""), BuildCacheUsage())
        let mixed = #"[{"size":100,"inUse":true},{"size":50,"inUse":false},{"size":-1}]"#
        let usage = try BuildsOutputParser.cacheUsage(mixed)
        XCTAssertEqual(usage.totalBytes, 150)
        XCTAssertEqual(usage.reclaimableBytes, 50)
        XCTAssertEqual(usage.inUseEntries, 1)
        XCTAssertEqual(usage.entries, 3)
        XCTAssertThrowsError(try BuildsOutputParser.cacheUsage("Error: container not found"))
    }

    func testBuilderArguments() {
        let c = client(BuildTestStreamer(lines: []))
        XCTAssertEqual(c.builderStatusArguments(), ["builder", "status", "--format", "json"])
        XCTAssertEqual(c.builderStartArguments(), ["builder", "start"])
        XCTAssertEqual(c.builderStartArguments(cpus: 4, memory: "4G"), ["builder", "start", "--cpus", "4", "--memory", "4G"])
        XCTAssertEqual(c.builderCacheArguments(), ["exec", "buildkit", "buildctl", "du", "--format", "{{json .}}"])
        XCTAssertEqual(c.pruneCacheArguments(), ["exec", "buildkit", "buildctl", "prune"])
        XCTAssertEqual(c.pruneCacheArguments(all: true), ["exec", "buildkit", "buildctl", "prune", "--all"])
    }

    func testBuilderCallsUseTheRunner() async throws {
        let runner = MockRunner()
        runner.responses["builder status --format json"] = CommandResult(exitCode: 0, stdout: BuildsFixtures.builderStatus)
        runner.responses["exec buildkit buildctl du --format {{json .}}"] = CommandResult(exitCode: 0, stdout: BuildsFixtures.cacheUsage)
        runner.responses["exec buildkit buildctl prune"] = CommandResult(exitCode: 0, stdout: "")
        let c = client(BuildTestStreamer(lines: []), runner: runner)
        let status = try await c.builderStatus()
        let usage = try await c.builderCacheUsage()
        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(usage.entries, 9)
        try await c.pruneBuilderCache()
        XCTAssertEqual(runner.calls.last, ["/usr/local/bin/container", "exec", "buildkit", "buildctl", "prune"])
    }

    func testSpecRoundTripAndDisplay() {
        let spec = BuildSpec(BuildOptions(contextDir: "/src/app", dockerfile: "/src/app/docker/Dockerfile.dev", tags: ["a:1"], platform: "linux/amd64"))
        XCTAssertEqual(spec.options.dockerfile, "/src/app/docker/Dockerfile.dev")
        XCTAssertEqual(spec.dockerfileDisplay, "docker/Dockerfile.dev")
        XCTAssertEqual(spec.shortPlatform, "amd64")
        XCTAssertEqual(BuildSpec(BuildOptions(contextDir: "/x")).dockerfileDisplay, "Dockerfile")
        XCTAssertEqual(BuildSpec(options).options, options)
    }
}

final class BuildHistoryTests: XCTestCase {
    private func record(_ status: BuildStatus, minutesAgo: Double) -> BuildRecord {
        BuildRecord(spec: BuildSpec(options), status: status, origin: .buildsScreen,
                    startedAt: Date().addingTimeInterval(-minutesAgo * 60))
    }

    func testTrimKeepsRunningAndNewest() {
        let records = [
            record(.succeeded, minutesAgo: 1),
            record(.running, minutesAgo: 50),
            record(.failed, minutesAgo: 2),
            record(.cancelled, minutesAgo: 3),
            record(.succeeded, minutesAgo: 4)
        ]
        let result = BuildHistoryStore.trim(records, limit: 3)
        XCTAssertEqual(result.kept.count, 3)
        XCTAssertTrue(result.kept.contains { $0.status == .running }, "Running builds never go")
        XCTAssertEqual(result.kept.first?.id, records[0].id, "Newest first")
        XCTAssertEqual(Set(result.removed.map(\.id)), Set([records[3].id, records[4].id]))
        XCTAssertEqual(BuildHistoryStore.trim(records, limit: 0).kept.count, 1, "Limit below one keeps the running build")
    }

    func testRunningBuildsComeBackInterrupted() throws {
        let running = record(.running, minutesAgo: 5)
        let done = record(.succeeded, minutesAgo: 10)
        let data = try BuildHistoryStore.encode([done, running])
        let loaded = BuildHistoryStore.decode(data)
        XCTAssertEqual(loaded.map(\.id), [running.id, done.id])
        XCTAssertEqual(loaded[0].status, .interrupted)
        XCTAssertNotNil(loaded[0].finishedAt)
        XCTAssertNotNil(loaded[0].message)
        XCTAssertEqual(loaded[1].status, .succeeded)
        XCTAssertEqual(loaded[1].startedAt.timeIntervalSince1970, done.startedAt.timeIntervalSince1970, accuracy: 0.002,
                       "Milliseconds survive, so durations read the same after a restart")
    }

    func testBrokenOrNewerFilesDoNotCrash() {
        XCTAssertEqual(BuildHistoryStore.decode(Data("not json".utf8)), [])
        let newer = #"{"version":9,"builds":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","spec":{"contextDir":"/x"},"status":"queued","origin":"cloud","startedAt":"2026-11-05T10:00:00Z","extra":1}]}"#
        let loaded = BuildHistoryStore.decode(Data(newer.utf8))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.status, .interrupted)
        XCTAssertEqual(loaded.first?.origin, .other)
        XCTAssertEqual(loaded.first?.spec.platform, "linux/arm64")
    }

    func testSaveLoadAndLogsOnDisk() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BuildHistoryStore(directory: dir)
        XCTAssertEqual(store.load(), [])
        let one = record(.succeeded, minutesAgo: 1)
        try store.save([one])
        try store.saveLog(["#1 DONE", "deck-v2-bld-test:1"], for: one.id)
        XCTAssertEqual(store.load().map(\.id), [one.id])
        XCTAssertEqual(store.loadLog(for: one.id), ["#1 DONE", "deck-v2-bld-test:1"])
        store.deleteLog(for: one.id)
        XCTAssertEqual(store.loadLog(for: one.id), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path))
    }

    func testDefaultDirectoryUsesBundleID() {
        let path = BuildsConfig.defaultDirectory.path
        if ProcessInfo.processInfo.environment[BuildsConfig.directoryOverrideVariable] == nil {
            XCTAssertTrue(path.contains("Application Support/\(AppConfig.bundleID)/Builds"), path)
        }
    }

    func testHistoryLimitPreference() {
        let defaults = UserDefaults(suiteName: "deck-builds-\(UUID().uuidString)")!
        XCTAssertEqual(BuildsConfig.historyLimit(defaults), BuildsConfig.defaultHistoryLimit)
        defaults.set(10, forKey: BuildsConfig.historyLimitKey)
        XCTAssertEqual(BuildsConfig.historyLimit(defaults), 10)
    }
}

final class BuildCenterTests: XCTestCase {
    func testSharedCenterIsMemoryOnlyInTests() {
        if ProcessInfo.processInfo.environment[BuildsConfig.directoryOverrideVariable] == nil {
            XCTAssertNil(BuildCenter.defaultStore().directory)
        }
    }

    func testStartRecordsLogStepsAndSaves() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = BuildCenter(store: BuildHistoryStore(directory: dir), historyLimit: { 50 })
        let streamer = BuildTestStreamer(lines: lines(BuildsFixtures.buildOK))
        let events = EventLog()
        center.addObserver { events.add($0) }

        let id = center.start(options, client: client(streamer), origin: .buildsScreen)
        XCTAssertEqual(center.record(id)?.status, .running)
        await waitUntil { center.record(id)?.status == .succeeded }

        let record = try XCTUnwrap(center.record(id))
        XCTAssertEqual(record.status, .succeeded)
        XCTAssertNotNil(record.finishedAt)
        XCTAssertEqual(record.stepIndex, 1)
        XCTAssertEqual(record.stepCount, 2)
        XCTAssertEqual(record.spec.tags, options.tags)
        XCTAssertEqual(streamer.calls.first, client(streamer).buildArguments(options))
        let log = center.log(id)
        XCTAssertFalse(log.contains(""), "Blank lines are dropped")
        XCTAssertEqual(log.last, "docker.io/library/deck-v2-bld-ok:arm")
        XCTAssertEqual(record.logLineCount, log.count)
        XCTAssertTrue(events.all.contains(.changed(id)))
        XCTAssertTrue(events.all.contains(.log(id)))

        // A new center (app restart) reads the same history and log.
        let again = BuildCenter(store: BuildHistoryStore(directory: dir))
        XCTAssertEqual(again.allRecords().map(\.id), [id])
        XCTAssertEqual(again.record(id)?.status, .succeeded)
        XCTAssertEqual(again.log(id), log)
    }

    func testFailedBuildKeepsTheReason() async throws {
        let center = BuildCenter(store: .memoryOnly)
        let streamer = BuildTestStreamer(lines: lines(BuildsFixtures.buildFailed), ending: .failure("exit 1"))
        let id = center.start(options, client: client(streamer), origin: .imageSheet)
        await waitUntil { center.record(id)?.status.isFinished == true }
        let record = try XCTUnwrap(center.record(id))
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.message, #"process "/bin/sh -c echo \"about to fail\" && exit 3" did not complete successfully: exit code: 3"#)
    }

    func testCancelStopsTheProcess() async throws {
        let center = BuildCenter(store: .memoryOnly)
        let streamer = BuildTestStreamer(lines: ["#5 [linux/arm64 1/2] RUN sleep 60"], ending: .hang)
        let id = center.start(options, client: client(streamer), origin: .buildsScreen)
        await waitUntil { center.record(id)?.lastStep != nil }
        XCTAssertEqual(center.runningCount, 1)
        center.cancel(id)
        await waitUntil { center.record(id)?.status.isFinished == true }
        XCTAssertEqual(center.record(id)?.status, .cancelled)
        XCTAssertEqual(streamer.terminations, 1, "The build process is ended")
        XCTAssertEqual(center.runningCount, 0)
    }

    func testTrackStreamsLinesLikeBuild() async throws {
        let center = BuildCenter(store: .memoryOnly)
        let streamer = BuildTestStreamer(lines: lines(BuildsFixtures.buildOK))
        var seen: [String] = []
        for try await line in client(streamer).trackedBuild(options, origin: .compose, detail: "web", center: center) {
            seen.append(line)
        }
        XCTAssertFalse(seen.isEmpty)
        let record = try XCTUnwrap(center.allRecords().first)
        XCTAssertEqual(record.origin, .compose)
        XCTAssertEqual(record.originDetail, "web")
        await waitUntil { center.record(record.id)?.status == .succeeded }
        XCTAssertEqual(center.record(record.id)?.status, .succeeded)
    }

    func testTrackFailureThrows() async {
        let center = BuildCenter(store: .memoryOnly)
        let streamer = BuildTestStreamer(lines: lines(BuildsFixtures.buildFailed), ending: .failure("exit 1"))
        do {
            for try await _ in center.track(options, client: client(streamer), origin: .compose) {}
            XCTFail("Should throw")
        } catch {
            XCTAssertEqual(center.allRecords().first?.status, .failed)
        }
    }

    func testCancelFromBuildsScreenEndsTheCallerStream() async {
        let center = BuildCenter(store: .memoryOnly)
        let streamer = BuildTestStreamer(lines: ["#5 [1/1] RUN sleep 60"], ending: .hang)
        let stream = center.track(options, client: client(streamer), origin: .compose)
        let consumer = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        await waitUntil { center.allRecords().first?.lastStep != nil }
        if let id = center.allRecords().first?.id { center.cancel(id) }
        let error = await consumer.value
        XCTAssertTrue(error is CancellationError, "Compose sees the cancel as an error")
        XCTAssertEqual(center.allRecords().first?.status, .cancelled)
    }

    func testCallerEndingTheStreamCancelsTheBuild() async {
        let center = BuildCenter(store: .memoryOnly)
        let streamer = BuildTestStreamer(lines: ["#5 [1/1] RUN sleep 60"], ending: .hang)
        let consumer = Task {
            for try await _ in center.track(options, client: client(streamer), origin: .compose) {}
        }
        await waitUntil { center.allRecords().first?.lastStep != nil }
        consumer.cancel()
        await waitUntil { center.allRecords().first?.status.isFinished == true }
        XCTAssertEqual(center.allRecords().first?.status, .cancelled)
        XCTAssertEqual(streamer.terminations, 1)
    }

    func testHistoryLimitRemovesOldBuildsAndLogs() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let limit = LimitBox(3)
        let center = BuildCenter(store: BuildHistoryStore(directory: dir), historyLimit: { limit.value })
        let streamer = BuildTestStreamer(lines: ["#1 [1/1] RUN true", "done"])
        var ids: [UUID] = []
        for _ in 0..<5 {
            let id = center.start(options, client: client(streamer), origin: .buildsScreen)
            await waitUntil { center.record(id)?.status == .succeeded }
            ids.append(id)
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(center.allRecords().map(\.id), Array(ids.suffix(3).reversed()))
        let logs = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("logs").path)
        XCTAssertEqual(logs.count, 3, "Logs of removed builds are deleted")

        limit.value = 1
        center.applyHistoryLimit()
        XCTAssertEqual(center.allRecords().map(\.id), [ids[4]])

        center.clearFinished()
        XCTAssertEqual(center.allRecords(), [])
        XCTAssertEqual(BuildCenter(store: BuildHistoryStore(directory: dir)).allRecords(), [])
    }

    func testRemoveKeepsRunningBuilds() async {
        let center = BuildCenter(store: .memoryOnly)
        let streamer = BuildTestStreamer(lines: [], ending: .hang)
        let id = center.start(options, client: client(streamer), origin: .buildsScreen)
        center.remove([id])
        XCTAssertEqual(center.record(id)?.status, .running)
        center.cancel(id)
        await waitUntil { center.record(id)?.status.isFinished == true }
        center.remove([id])
        XCTAssertNil(center.record(id))
    }

    func testManyBuildsAtOnce() async {
        let center = BuildCenter(store: .memoryOnly)
        let streamer = BuildTestStreamer(lines: lines(BuildsFixtures.buildOK))
        let ids = (0..<6).map { _ in center.start(options, client: client(streamer), origin: .buildsScreen) }
        await waitUntil { ids.allSatisfy { center.record($0)?.status == .succeeded } }
        XCTAssertTrue(ids.allSatisfy { center.record($0)?.status == .succeeded })
        XCTAssertEqual(Set(ids.map { center.log($0).count }).count, 1, "Each build has its own full log")
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BuildCenterEvent] = []
    func add(_ event: BuildCenterEvent) { lock.lock(); events.append(event); lock.unlock() }
    var all: [BuildCenterEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

private final class LimitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int
    init(_ value: Int) { stored = value }
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
