import XCTest
@testable import DeckCore

/// Real builds against Apple's `container` on this Mac.
/// Run: `DECK_LIVE_BUILDS=1 swift test --filter BuildsLiveTests`.
/// Makes deck-v2-bld-live-* images and removes them at the end.
final class BuildsLiveTests: XCTestCase {
    private let cliPath = "/usr/local/bin/container"
    private var work: URL!
    private var history: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_LIVE_BUILDS"] == "1", "Set DECK_LIVE_BUILDS=1")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cliPath), "container is not installed")
        work = FileManager.default.temporaryDirectory.appendingPathComponent("deck-v2-bld-live-\(UUID().uuidString)")
        history = work.appendingPathComponent("history")
        for (name, text) in [
            ("ok", "FROM alpine:3.20\nARG GREETING=hello\nRUN echo \"$GREETING from $(uname -m)\" > /greeting.txt\nCMD [\"cat\", \"/greeting.txt\"]\n"),
            ("fail", "FROM alpine:3.20\nRUN echo about to fail && exit 3\n"),
            ("slow", "FROM alpine:3.20\nRUN for i in $(seq 1 120); do echo tick $i; sleep 1; done\n")
        ] {
            let dir = work.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() async throws {
        let client = ContainerClient(cliPath: cliPath)
        for tag in ["deck-v2-bld-live-ok:arm64", "deck-v2-bld-live-ok:amd64", "deck-v2-bld-live-slow:1", "deck-v2-bld-live-fail:1"] {
            try? await client.deleteImage(tag)
        }
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private func wait(_ center: BuildCenter, _ id: UUID, timeout: TimeInterval = 300) async {
        let end = Date().addingTimeInterval(timeout)
        while center.record(id)?.status == .running && Date() < end {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func testRealBuildsCancelFailAndRestart() async throws {
        let client = ContainerClient(cliPath: cliPath)
        let center = BuildCenter(store: BuildHistoryStore(directory: history), historyLimit: { 50 })

        // arm64 and amd64 at the same time, plus one that fails and one we stop.
        let arm = center.start(BuildOptions(contextDir: work.appendingPathComponent("ok").path, tags: ["deck-v2-bld-live-ok:arm64"],
                                            buildArgs: [EnvVar(key: "GREETING", value: "hey")], platform: "linux/arm64"),
                               client: client, origin: .buildsScreen)
        let amd = center.start(BuildOptions(contextDir: work.appendingPathComponent("ok").path, tags: ["deck-v2-bld-live-ok:amd64"],
                                            platform: "linux/amd64"),
                               client: client, origin: .buildsScreen)
        let fail = center.start(BuildOptions(contextDir: work.appendingPathComponent("fail").path, tags: ["deck-v2-bld-live-fail:1"]),
                                client: client, origin: .imageSheet)
        let slow = center.start(BuildOptions(contextDir: work.appendingPathComponent("slow").path, tags: ["deck-v2-bld-live-slow:1"], noCache: true),
                                client: client, origin: .buildsScreen)

        // Cancel once the slow build is in its RUN step.
        let end = Date().addingTimeInterval(120)
        while !center.log(slow).contains(where: { $0.contains("tick 3") }) && Date() < end {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(center.record(slow)?.status, .running)
        center.cancel(slow)

        for id in [arm, amd, fail, slow] { await wait(center, id) }

        XCTAssertEqual(center.record(arm)?.status, .succeeded, center.log(arm).suffix(5).joined(separator: "\n"))
        XCTAssertEqual(center.record(amd)?.status, .succeeded, center.log(amd).suffix(5).joined(separator: "\n"))
        XCTAssertTrue(center.log(amd).contains { $0.contains("[linux/amd64") })
        XCTAssertEqual(center.record(fail)?.status, .failed)
        XCTAssertTrue(center.record(fail)?.message?.contains("exit code: 3") ?? false, center.record(fail)?.message ?? "")
        XCTAssertEqual(center.record(slow)?.status, .cancelled)
        XCTAssertLessThan(center.record(slow)?.duration() ?? 999, 60, "Stopped well before the 120 s step")

        // BuildKit really stopped: the image was not made.
        let images = try await client.listImages().map(\.reference)
        XCTAssertTrue(images.contains { $0.contains("deck-v2-bld-live-ok:arm64") })
        XCTAssertTrue(images.contains { $0.contains("deck-v2-bld-live-ok:amd64") })
        XCTAssertFalse(images.contains { $0.contains("deck-v2-bld-live-slow") })

        // Restart: a new center reads the same folder.
        let restarted = BuildCenter(store: BuildHistoryStore(directory: history))
        let statuses = Dictionary(uniqueKeysWithValues: restarted.allRecords().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses[arm], .succeeded)
        XCTAssertEqual(statuses[amd], .succeeded)
        XCTAssertEqual(statuses[fail], .failed)
        XCTAssertEqual(statuses[slow], .cancelled)
        XCTAssertEqual(restarted.log(arm), center.log(arm))

        // Builder status and cache read for real.
        let builder = try await client.builderStatus()
        XCTAssertTrue(builder.isRunning)
        let cache = try await client.builderCacheUsage(builderID: builder.id)
        XCTAssertGreaterThan(cache.entries, 0)
        XCTAssertGreaterThan(cache.totalBytes, 0)
    }
}
