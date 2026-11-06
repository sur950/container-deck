import XCTest
@testable import DeckCore

/// Answers volume list, create and delete, container and network delete, and runs the chat
/// sync script against an in memory volume, so whole round trips can be checked.
final class ChatVolumeFakeRunner: CommandRunning, @unchecked Sendable {
    var volumes: Set<String> = []
    var files: [String: Data] = [:]
    var failing = false
    var calls: [[String]] = []

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        calls.append(arguments)
        if failing { return CommandResult(exitCode: 1, stdout: "", stderr: "XPC connection error: the container service is not running") }
        if arguments.starts(with: ["volume", "list"]) {
            let list = volumes.sorted().map { #"{"configuration":{"labels":{},"name":"\#($0)","options":{}},"id":"\#($0)"}"# }
            return CommandResult(exitCode: 0, stdout: "[" + list.joined(separator: ",") + "]")
        }
        if arguments.starts(with: ["volume", "create"]), let name = arguments.last {
            volumes.insert(name)
            return CommandResult(exitCode: 0, stdout: name)
        }
        if arguments.starts(with: ["volume", "delete"]), let name = arguments.last {
            volumes.remove(name)
            return CommandResult(exitCode: 0, stdout: name)
        }
        if arguments.first == "delete" || arguments.starts(with: ["network", "delete"]) {
            return CommandResult(exitCode: 0, stdout: "")
        }
        if arguments.first == "run" || arguments.first == "exec" {
            for line in String(decoding: stdin ?? Data(), as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                if parts[0] == "PUT" { files[parts[1]] = Data(base64Encoded: parts[2]) }
                if parts[0] == "DEL" { files[parts[1]] = nil }
            }
            let out = files.sorted { $0.key < $1.key }.map { "FILE \($0.key) \($0.value.base64EncodedString())" } + ["DONE"]
            return CommandResult(exitCode: 0, stdout: out.joined(separator: "\n") + "\n")
        }
        return CommandResult(exitCode: 1, stdout: "", stderr: "not mocked")
    }
}

final class ChatVolumeSyncTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-volume-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testOperationsFromQueueAndMigration() {
        var state = ChatSyncState()
        let local = ["a.json": data("A"), "b.json": data("B")]
        XCTAssertEqual(ChatVolumeSync.operations(state: state, local: local),
                       [ChatSyncOp(file: "a.json", kind: .put(data("A"))), ChatSyncOp(file: "b.json", kind: .put(data("B")))],
                       "first sync sends every cached file once (migration)")
        state.migrated = true
        XCTAssertEqual(ChatVolumeSync.operations(state: state, local: local), [])
        state.mark("a.json", .put)
        state.mark("gone.json", .delete)
        state.mark("../evil.json", .put)
        XCTAssertEqual(ChatVolumeSync.operations(state: state, local: local),
                       [ChatSyncOp(file: "a.json", kind: .put(data("A"))), ChatSyncOp(file: "gone.json", kind: .delete)],
                       "unsafe names are never sent")
    }

    func testMergeVolumeWinsExceptNewerLocalChanges() {
        var sent = ChatSyncState(migrated: true)
        sent.mark("mine.json", .put)
        var now = sent
        now.mark("typing.json", .put)
        let remote = ["mine.json": data("M"), "other.json": data("volume copy"), "typing.json": data("old")]
        let local = ["mine.json": data("M"), "other.json": data("stale"), "typing.json": data("new"), "removed.json": data("x")]
        let plan = ChatVolumeSync.merge(remote: remote, local: local, sentState: sent, currentState: now)
        XCTAssertEqual(plan.writeLocal, ["other.json": data("volume copy")])
        XCTAssertEqual(plan.deleteLocal, ["removed.json"])
        XCTAssertEqual(plan.sent, ["mine.json"])
        XCTAssertEqual(plan.changedFiles, ["other.json", "removed.json"])
        now.mark("mine.json", .put)
        XCTAssertEqual(ChatVolumeSync.merge(remote: remote, local: local, sentState: sent, currentState: now).sent, [],
                       "changed again during the sync, so it stays queued")
    }

    func testScriptInputAndListing() throws {
        let input = String(decoding: ChatVolumeSync.input([
            ChatSyncOp(file: "a.json", kind: .put(data("{\"x\":1}"))),
            ChatSyncOp(file: "b.json", kind: .delete),
            ChatSyncOp(file: "bad name.json", kind: .delete)
        ]), as: UTF8.self)
        XCTAssertEqual(input, "PUT a.json eyJ4IjoxfQ==\nDEL b.json -\nEND - -\n")
        let files = try ChatVolumeSync.parseListing("noise\nFILE a.json eyJ4IjoxfQ==\nFILE .hidden.json eA==\nFILE c.json \nDONE\n")
        XCTAssertEqual(files, ["a.json": data("{\"x\":1}"), "c.json": Data()])
        XCTAssertThrowsError(try ChatVolumeSync.parseListing("FILE a.json eA=="), "a cut off listing never counts")
        XCTAssertTrue(ChatVolumeSync.script.contains("base64 -d"))
        XCTAssertTrue(ChatVolumeSync.script.contains("echo DONE"))
    }

    func testCommandArguments() {
        let helper = ChatVolumeSync.helperArguments(volume: "deck-chat-history", name: "deck-chat-sync-1")
        XCTAssertEqual(Array(helper.prefix(11)), ["run", "--rm", "--interactive", "--name", "deck-chat-sync-1",
                                                  "--label", "deck.helper=chat-sync", "--label", "deck.volume=deck-chat-history",
                                                  "--volume", "deck-chat-history:/data"])
        XCTAssertEqual(Array(helper.suffix(6)), ["docker.io/library/alpine:latest", "/bin/sh", "-c", ChatVolumeSync.script, "deck-chat", "/data"])
        XCTAssertEqual(ChatVolumeSync.execArguments(containerID: "box", directory: "/deck/chat"),
                       ["exec", "--interactive", "box", "/bin/sh", "-c", ChatVolumeSync.script, "deck-chat", "/deck/chat"])
        XCTAssertEqual(ChatVolumeSync.sandboxVolume("box"), "box-chat")
        XCTAssertEqual(ChatVolumeSync.sandboxVolumeLabels("box"), ["deck.sandbox": "box", "deck.role": "chat-history"])
        XCTAssertEqual(ChatVolumeSync.modelVolumeLabels, ["deck.role": "chat-history"])
        XCTAssertTrue(ChatVolumeSync.helperName().hasPrefix("deck-chat-sync-"))
    }

    func testRoundTripNeverMakesAVolume() async throws {
        let runner = ChatVolumeFakeRunner()
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: runner)
        let existsBefore = try await client.chatVolumeExists("deck-chat-history")
        XCTAssertFalse(existsBefore)
        try await client.ensureVolume("deck-chat-history", labels: ChatVolumeSync.modelVolumeLabels)
        try await client.ensureVolume("deck-chat-history", labels: ChatVolumeSync.modelVolumeLabels)
        XCTAssertEqual(runner.calls.filter { $0.starts(with: ["volume", "create"]) },
                       [["volume", "create", "--label", "deck.role=chat-history", "deck-chat-history"]], "made once")
        runner.calls = []
        let transport = ChatSyncTransport.helper(volume: "deck-chat-history", labels: ChatVolumeSync.modelVolumeLabels)
        let remote = try await client.syncChatVolume([ChatSyncOp(file: "a.json", kind: .put(data("A")))], transport: transport)
        XCTAssertEqual(remote, ["a.json": data("A")])
        XCTAssertEqual(runner.calls.map(\.first), ["run"], "one helper per sync, no volume calls")
        runner.calls = []
        _ = try await client.syncChatVolume([], transport: .exec(containerID: "box", directory: "/deck/chat"))
        XCTAssertEqual(runner.calls.map(\.first), ["exec"])
        runner.failing = true
        do {
            _ = try await client.chatVolumeExists("deck-chat-history")
            XCTFail("a stopped service throws, so it is not taken for a removed volume")
        } catch {}
    }

    func testHistoryQueuesChangesAndApplyClearsOnlyWhatWasSent() throws {
        let history = ChatHistory(directory: directory)
        try history.save("k", messages: [SavedChatMessage(role: .user, text: "Hi")])
        let file = history.url(for: "k").lastPathComponent
        XCTAssertEqual(history.syncState().pending[file]?.op, .put)
        let sent = history.syncState()
        try history.save("k", messages: [SavedChatMessage(role: .user, text: "Hi again")])
        let plan = ChatVolumeSync.merge(remote: [file: Data()], local: history.localFiles(), sentState: sent, currentState: history.syncState())
        history.apply(plan, sentState: sent)
        XCTAssertNotNil(history.syncState().pending[file], "the newer copy was not sent yet")
        XCTAssertEqual(history.load("k").first?.text, "Hi again")
        XCTAssertTrue(history.syncState().migrated)
        XCTAssertFalse(history.localFiles().keys.contains(".sync-state.json"))
        history.clear("k")
        XCTAssertEqual(history.syncState().pending[file]?.op, .delete, "clear is queued for the volume too")
        history.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testOfflineQueueThenSyncThenClear() async throws {
        let runner = ChatVolumeFakeRunner()
        runner.volumes = ["deck-chat-history"]
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: runner)
        let history = ChatHistory(directory: directory)
        let transport = ChatSyncTransport.helper(volume: "deck-chat-history", labels: [:])
        func sync() async throws {
            let sent = history.syncState()
            let remote = try await client.syncChatVolume(ChatVolumeSync.operations(state: sent, local: history.localFiles()), transport: transport)
            history.apply(ChatVolumeSync.merge(remote: remote, local: history.localFiles(), sentState: sent, currentState: history.syncState()), sentState: sent)
        }
        try history.save("k", messages: [SavedChatMessage(role: .user, text: "Hi")])
        runner.failing = true
        do { try await sync(); XCTFail("service is stopped") } catch {}
        XCTAssertFalse(history.syncState().pending.isEmpty, "the queued change waits")
        runner.failing = false
        try await sync()
        XCTAssertTrue(history.syncState().pending.isEmpty)
        XCTAssertEqual(runner.files.count, 1)
        runner.files["model-x-1-y-aaaaaaaaaaaa.json"] = data("{}")
        try await sync()
        XCTAssertEqual(history.localFiles().count, 2, "the volume is the source of truth")
        history.clear("k")
        try await sync()
        XCTAssertEqual(runner.files.keys.sorted(), ["model-x-1-y-aaaaaaaaaaaa.json"])
    }

    func testSandboxRunOptionsMountTheChatVolume() {
        let options = SandboxPlanner.runOptions(SandboxSpec(name: "box", image: "alpine", egress: .isolated), gateway: "192.168.128.1", subnet: nil, hasKey: false)
        let mount = options.mounts.first { $0.destination == "/deck/chat" }
        XCTAssertEqual(mount?.source, "box-chat")
        XCTAssertEqual(mount?.kind, .volume)
        XCTAssertEqual(mount?.readOnly, false)
        XCTAssertEqual(options.labels["deck.sandbox.chat-volume"], "box-chat")
        let sandbox = Sandbox(container: ContainerSummary(id: "box", name: "box", image: "alpine", state: .running, labels: options.labels))
        XCTAssertEqual(sandbox?.chatVolume, "box-chat")
        XCTAssertEqual(sandbox?.savesChatHistoryByDefault, true)

        var quiet = SandboxSpec(name: "quiet", image: "alpine", egress: .isolated)
        quiet.saveChatHistory = false
        let off = SandboxPlanner.runOptions(quiet, gateway: "192.168.128.1", subnet: nil, hasKey: false)
        XCTAssertNil(off.mounts.first { $0.destination == "/deck/chat" })
        XCTAssertEqual(off.labels["deck.sandbox.chat-history"], "off")
        XCTAssertEqual(Sandbox(container: ContainerSummary(id: "q", name: "q", image: "alpine", state: .running, labels: off.labels))?.savesChatHistoryByDefault, false)
        XCTAssertNil(Sandbox(container: ContainerSummary(id: "old", name: "old", image: "alpine", state: .running, labels: ["deck.sandbox": "1"]))?.chatVolume)
    }

    func testRemovingASandboxRemovesItsChatVolumeUnlessKept() async throws {
        let runner = ChatVolumeFakeRunner()
        runner.volumes = ["box-chat", "other-chat"]
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: runner)
        let sandbox = try XCTUnwrap(Sandbox(container: ContainerSummary(id: "box", name: "box", image: "alpine", state: .stopped,
                                                                        labels: ["deck.sandbox": "1", "deck.sandbox.chat-volume": "box-chat"])))
        try await client.removeSandbox(sandbox, keepChatHistory: true)
        XCTAssertEqual(runner.volumes, ["box-chat", "other-chat"], "kept when asked")
        try await client.removeSandbox(sandbox)
        XCTAssertEqual(runner.volumes, ["other-chat"], "removed by default, others untouched")
        let old = try XCTUnwrap(Sandbox(container: ContainerSummary(id: "old", name: "old", image: "alpine", state: .stopped, labels: ["deck.sandbox": "1"])))
        try await client.removeSandbox(old)
        XCTAssertFalse(runner.calls.contains(["volume", "delete", "old-chat"]))
    }
}
