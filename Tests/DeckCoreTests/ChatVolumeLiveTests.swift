import XCTest
@testable import DeckCore

/// Chat history volumes with a real throwaway sandbox. Run with:
/// `DECK_LIVE_CHAT=1 swift test --filter ChatVolumeLiveTests`
/// Needs the container service and the alpine image (pulled if missing). Makes one
/// deck-chat-test-* sandbox, its network and its chat volume, and removes them all.
final class ChatVolumeLiveTests: XCTestCase {
    private let cli = "/usr/local/bin/container"
    private let boxName = "deck-chat-test-\(UUID().uuidString.prefix(6).lowercased())"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_LIVE_CHAT"] == "1", "set DECK_LIVE_CHAT=1")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli), "container CLI missing")
    }

    override func tearDown() async throws {
        let client = ContainerClient(cliPath: cli)
        _ = try? await client.run(["delete", "--force", boxName])
        _ = try? await client.run(["network", "delete", boxName + SandboxConfig.networkSuffix])
        _ = try? await client.run(["volume", "delete", ChatVolumeSync.sandboxVolume(boxName)])
    }

    func testSandboxChatVolumeEndToEnd() async throws {
        let client = ContainerClient(cliPath: cli)
        let volume = ChatVolumeSync.sandboxVolume(boxName)
        // A local model, so the sandbox Chat tab can be tried during DECK_LIVE_CHAT_PAUSE. Not used by the checks below.
        let model = SandboxModel(kind: .ollama, url: URL(string: "http://127.0.0.1:11434")!, name: "qwen3:0.6b")
        try await client.createSandbox(SandboxSpec(name: boxName, image: "docker.io/library/alpine:latest", egress: .isolated, model: model), apiKey: nil)

        let listed = try await client.listSandboxes()
        let sandbox = try XCTUnwrap(listed.first { $0.name == boxName })
        XCTAssertEqual(sandbox.chatVolume, volume)
        let made = try await client.listVolumes().first { $0.name == volume }
        XCTAssertNotNil(made, "made with the sandbox")
        XCTAssertEqual(made?.labels["deck.role"], "chat-history")
        XCTAssertEqual(made?.labels["deck.sandbox"], boxName)

        // Running: through exec into the mount.
        let conversation = Data(#"{"key":"sandbox-test","messages":[{"role":"user","text":"hello from the test"}]}"#.utf8)
        let file = "sandbox-test-0123456789ab.json"
        let first = try await client.syncChatVolume([ChatSyncOp(file: file, kind: .put(conversation))],
                                                    transport: .exec(containerID: sandbox.container.id, directory: SandboxConfig.chatPath))
        XCTAssertEqual(first[file], conversation)
        let seen = try await client.exec(sandbox.container.id, ["cat", "\(SandboxConfig.chatPath)/\(file)"])
        XCTAssertTrue(seen.stdout.contains("hello from the test"), "the agent inside can read the history")
        // DECK_LIVE_CHAT_PAUSE=<seconds> keeps the sandbox running for a look in the app.
        if let pause = ProcessInfo.processInfo.environment["DECK_LIVE_CHAT_PAUSE"].flatMap(Double.init), pause > 0 {
            try await Task.sleep(for: .seconds(min(pause, 300)))
        }

        // Stopped: through a helper container that mounts the volume.
        try await client.stopContainer(sandbox.container.id)
        let second = try await client.syncChatVolume([], transport: .helper(volume: volume, labels: ChatVolumeSync.sandboxVolumeLabels(boxName)))
        XCTAssertEqual(second[file], conversation, "the history lives in the volume")
        let leftovers = try await client.listContainers(all: true).filter { $0.labels[ChatVolumeSync.helperLabel] == ChatVolumeSync.helperLabelValue }
        XCTAssertEqual(leftovers.count, 0, "the helper removes itself")

        // Removing the sandbox removes its chat volume.
        let listedAgain = try await client.listSandboxes()
        let stopped = try XCTUnwrap(listedAgain.first { $0.name == boxName })
        try await client.removeSandbox(stopped)
        let afterVolumes = try await client.listVolumes().map(\.name)
        XCTAssertFalse(afterVolumes.contains(volume))
        let afterSandboxes = try await client.listSandboxes().map(\.name)
        XCTAssertFalse(afterSandboxes.contains(boxName))
    }
}
