import XCTest
import DeckCore
@testable import ContainerDeck

final class AIModelsChatMarkdownTests: XCTestCase {
    func testParagraphsHeadingsListsAndCode() {
        let text = """
        Here is a function:

        ```python
        def f():
            return 1
        ```

        ## Explanation

        - **First** item
          wrapped line
        - Second
        1. One
        2) Two

        > A tip
        ---
        Last line
        """
        let blocks = ChatMarkdown.blocks(text)
        XCTAssertEqual(blocks, [
            .paragraph("Here is a function:"),
            .code(language: "python", code: "def f():\n    return 1"),
            .heading(level: 2, text: "Explanation"),
            .list([
                .init(marker: "•", text: "**First** item wrapped line", indent: 0),
                .init(marker: "•", text: "Second", indent: 0),
                .init(marker: "1.", text: "One", indent: 0),
                .init(marker: "2.", text: "Two", indent: 0)
            ]),
            .quote("A tip"),
            .rule,
            .paragraph("Last line")
        ])
    }

    func testOpenFenceWhileStreamingIsCode() {
        XCTAssertEqual(ChatMarkdown.blocks("Try this:\n```sh\ncontainer ls"), [
            .paragraph("Try this:"),
            .code(language: "sh", code: "container ls")
        ])
        XCTAssertEqual(ChatMarkdown.blocks("~~~\n```\nnot closed by backticks\n~~~"), [.code(language: "", code: "```\nnot closed by backticks")])
    }

    func testTablesAndNested() {
        let blocks = ChatMarkdown.blocks("| Flag | Use |\n| --- | :-: |\n| `-d` | Background |\n\n- top\n    - nested")
        XCTAssertEqual(blocks.first, .table([["Flag", "Use"], ["`-d`", "Background"]]))
        XCTAssertEqual(blocks.last, .list([.init(marker: "•", text: "top", indent: 0), .init(marker: "•", text: "nested", indent: 2)]))
        XCTAssertEqual(ChatMarkdown.blocks("| just a pipe line"), [.paragraph("| just a pipe line")], "no separator row, not a table")
        XCTAssertEqual(ChatMarkdown.blocks("#hashtag"), [.paragraph("#hashtag")])
        XCTAssertEqual(ChatMarkdown.blocks(""), [])
    }

    func testThinkTags() {
        XCTAssertEqual(ChatMarkdown.splitThinking("<think>\nplan\n</think>\n\nAnswer").thinking, "plan")
        XCTAssertEqual(ChatMarkdown.splitThinking("<think>\nplan\n</think>\n\nAnswer").answer, "Answer")
        let open = ChatMarkdown.splitThinking("<think>still going")
        XCTAssertEqual(open.thinking, "still going")
        XCTAssertEqual(open.answer, "")
        XCTAssertTrue(open.isThinking)
        XCTAssertEqual(ChatMarkdown.splitThinking("Plain answer").answer, "Plain answer")
        XCTAssertFalse(ChatMarkdown.splitThinking("Plain answer").isThinking)
    }

    func testInlineMarkdown() {
        let text = ChatMarkdown.inline("Use **bold** and `code`")
        XCTAssertEqual(String(text.characters), "Use bold and code")
        XCTAssertEqual(String(ChatMarkdown.inline("**unclosed").characters), "**unclosed")
    }

    func testReturnKey() {
        XCTAssertEqual(ChatComposerKey.action(shift: false, option: false, composing: false), .send)
        XCTAssertEqual(ChatComposerKey.action(shift: true, option: false, composing: false), .newline)
        XCTAssertEqual(ChatComposerKey.action(shift: false, option: true, composing: false), .newline)
        XCTAssertEqual(ChatComposerKey.action(shift: false, option: false, composing: true), .passThrough, "Return confirms an input method first")
    }
}

/// Answers volume list, create and delete, and runs the chat sync script against an in memory volume.
final class ChatTestVolumeRunner: CommandRunning, @unchecked Sendable {
    var volumes: [String: [String: Data]] = [:]
    var failing = false
    var calls: [[String]] = []

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        calls.append(arguments)
        if failing { return CommandResult(exitCode: 1, stdout: "", stderr: "XPC connection error: the container service is not running") }
        if arguments.starts(with: ["volume", "list"]) {
            let list = volumes.keys.sorted().map { #"{"configuration":{"labels":{},"name":"\#($0)","options":{}},"id":"\#($0)"}"# }
            return CommandResult(exitCode: 0, stdout: "[" + list.joined(separator: ",") + "]")
        }
        if arguments.starts(with: ["volume", "create"]), let name = arguments.last {
            volumes[name] = volumes[name] ?? [:]
            return CommandResult(exitCode: 0, stdout: name)
        }
        if arguments.first == "run" || arguments.first == "exec" {
            let volume: String
            if arguments.first == "run", let index = arguments.firstIndex(of: "--volume") {
                volume = String(arguments[index + 1].split(separator: ":").first ?? "")
            } else {
                volume = "exec:" + arguments[2]
            }
            var files = volumes[volume] ?? [:]
            for line in String(decoding: stdin ?? Data(), as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                if parts[0] == "PUT" { files[parts[1]] = Data(base64Encoded: parts[2]) }
                if parts[0] == "DEL" { files[parts[1]] = nil }
            }
            volumes[volume] = files
            let out = files.sorted { $0.key < $1.key }.map { "FILE \($0.key) \($0.value.base64EncodedString())" } + ["DONE"]
            return CommandResult(exitCode: 0, stdout: out.joined(separator: "\n") + "\n")
        }
        return CommandResult(exitCode: 1, stdout: "", stderr: "not mocked")
    }
}

@MainActor
final class AIModelsChatStoreTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var runner: ChatTestVolumeRunner!
    private var center: ChatSyncCenter!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-store-\(UUID().uuidString)", isDirectory: true)
        suite = "chat-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        runner = ChatTestVolumeRunner()
        center = ChatSyncCenter()
        center.debounce = .seconds(60)
        center.retry = .seconds(60)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private var client: ContainerClient { ContainerClient(cliPath: "/usr/local/bin/container", runner: runner) }

    private func makeStore(online: Bool = true) -> AIModelsStore {
        let store = AIModelsStore()
        store.chatHistory = ChatHistory(directory: directory.appendingPathComponent("models"))
        store.chatDefaults = defaults
        store.chatSync = center
        store.endpoints = [ModelEndpoint(id: "ollama", kind: .ollama, host: "127.0.0.1", port: 11434,
                                         baseURL: URL(string: "http://127.0.0.1:11434/v1")!, status: .running,
                                         models: [ModelEndpointModel(id: "qwen3:0.6b"), ModelEndpointModel(id: "mistral")])]
        store.chatEndpointID = "ollama"
        store.chatModel = "qwen3:0.6b"
        // Registers the chat. The client comes after, so no first sync runs in the background.
        store.ensureChatLoaded()
        if online { center.client = client }
        return store
    }

    private func say(_ store: AIModelsStore, _ texts: String...) {
        store.chat += texts.map { AIModelsStore.ChatEntry(role: .user, text: $0) }
        store.saveChat(store.chatKey!)
    }

    private var modelVolume: [String: Data] { runner.volumes[ChatVolumeSync.volumeName] ?? [:] }

    func testNoticeText() {
        XCTAssertNil(ChatSaveStatus.saving.notice)
        XCTAssertNil(ChatSaveStatus.unknown.notice)
        XCTAssertEqual(ChatSaveStatus.off.notice?.text, "Chat history is off. This conversation won't be saved.")
        XCTAssertEqual(ChatSaveStatus.off.notice?.action, "Turn On")
        XCTAssertEqual(ChatSaveStatus.volumeMissing.notice?.text, "The chat history volume was removed. This conversation won't be saved.")
        XCTAssertEqual(ChatSaveStatus.volumeMissing.notice?.action, "Create Volume")
        XCTAssertEqual(ChatSaveStatus.notAttached.notice?.action, "Attach Volume")
        XCTAssertEqual(ChatSaveStatus.serviceStopped.notice?.text,
                       "The container service is stopped. New messages won't be saved until it runs, and are lost if you quit first.")
        for status in [ChatSaveStatus.off, .volumeMissing, .notAttached, .serviceStopped] {
            XCTAssertFalse(status.notice!.text.contains(";"))
            XCTAssertFalse(status.canWrite)
        }
    }

    func testConversationPerModelSurvivesSwitchingAndRelaunch() throws {
        let store = makeStore(online: false)
        store.ensureChatLoaded()
        var stats = ChatStats(started: Date(timeIntervalSince1970: 100))
        stats.firstToken = Date(timeIntervalSince1970: 100.2)
        stats.finished = Date(timeIntervalSince1970: 101)
        stats.chunks = 20
        store.chat = [
            .init(role: .user, text: "Hi"),
            .init(role: .assistant, text: "Hello", reasoning: "think", stats: stats, model: "qwen3:0.6b", serverKind: .ollama)
        ]
        store.saveChat(try XCTUnwrap(store.chatKey))
        store.chatModel = "mistral"
        store.ensureChatLoaded()
        XCTAssertEqual(store.chat, [])
        store.chatModel = "qwen3:0.6b"
        XCTAssertEqual(store.chat.map(\.text), ["Hi", "Hello"], "coming back shows it in full")

        center = ChatSyncCenter()
        let relaunched = makeStore(online: false)
        relaunched.ensureChatLoaded()
        XCTAssertEqual(relaunched.chat.map(\.id), store.chat.map(\.id))
        XCTAssertEqual(relaunched.chat.last?.stats?.tokens, 20)
        relaunched.clearChat()
        XCTAssertEqual(relaunched.chat, [])
    }

    func testFirstUseMakesTheVolumeAndSavesThere() async throws {
        let store = makeStore()
        say(store, "Hi")
        await center.syncNow(ChatSyncCenter.modelsTarget)
        XCTAssertEqual(store.chatSaveStatus, .saving)
        XCTAssertEqual(modelVolume.count, 1, "the conversation is in the volume")
        XCTAssertTrue(runner.calls.contains(["volume", "create", "--label", "deck.role=chat-history", ChatVolumeSync.volumeName]))
        XCTAssertTrue(defaults.bool(forKey: PrefKey.chatVolumeCreated))
        // Clear removes it from the volume too.
        store.clearChat()
        await center.syncNow(ChatSyncCenter.modelsTarget)
        XCTAssertEqual(modelVolume, [:])
    }

    func testMigratesFilesFromBeforeVolumes() async throws {
        let cache = ChatHistory(directory: directory.appendingPathComponent("models"))
        try cache.save("model-ollama-11434-old", messages: [SavedChatMessage(role: .user, text: "old chat")])
        var state = cache.syncState()
        state.pending = [:]              // like a file written before volumes: nothing queued
        cache.saveSyncState(state)
        let store = makeStore()
        store.ensureChatLoaded()
        await center.syncNow(ChatSyncCenter.modelsTarget)
        XCTAssertEqual(modelVolume.keys.sorted(), [cache.url(for: "model-ollama-11434-old").lastPathComponent])
    }

    func testRemovedVolumeIsMadeAgainWhileHistoryIsOn() async throws {
        let store = makeStore()
        say(store, "Saved before")
        await center.syncNow(ChatSyncCenter.modelsTarget)
        XCTAssertTrue(defaults.bool(forKey: PrefKey.chatVolumeCreated))
        runner.volumes[ChatVolumeSync.volumeName] = nil              // a cleanup or the CLI removed it
        say(store, "Typed after")
        await center.syncNow(ChatSyncCenter.modelsTarget)
        XCTAssertEqual(store.chatSaveStatus, .saving, "the switch is on, so saving goes on")
        XCTAssertNotNil(runner.volumes[ChatVolumeSync.volumeName], "made again")
        let saved = try XCTUnwrap(modelVolume.values.first)
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("Typed after"))
    }

    func testTurnedOffMeansNothingSavedAndTurnOnSavesTheSession() async throws {
        let store = makeStore()
        say(store, "Saved")
        await center.syncNow(ChatSyncCenter.modelsTarget)
        XCTAssertTrue(store.chatHistoryEnabled, "on by default")

        defaults.set(false, forKey: PrefKey.saveChatHistory)           // Settings switch
        await center.applyHistorySetting(ChatSyncCenter.modelsTarget)
        XCTAssertEqual(store.chatSaveStatus, .off)
        XCTAssertEqual(store.chatHistory.localFiles(), [:])
        XCTAssertEqual(store.chat, [], "history from the cache is not shown")
        say(store, "Private")
        XCTAssertEqual(store.chatHistory.localFiles(), [:])
        let before = modelVolume

        await store.chatNoticeAction()                                 // Turn On
        XCTAssertTrue(defaults.bool(forKey: PrefKey.saveChatHistory))
        XCTAssertEqual(store.chatSaveStatus, .saving)
        XCTAssertEqual(store.chat.map(\.text), ["Saved", "Private"], "merged with the volume's copy")
        await center.syncNow(ChatSyncCenter.modelsTarget)
        XCTAssertNotEqual(modelVolume, before)
    }

    func testServiceStoppedKeepsMessagesInMemoryUntilItRuns() async throws {
        let store = makeStore()
        say(store, "Before")
        await center.syncNow(ChatSyncCenter.modelsTarget)
        runner.failing = true
        await center.syncNow(ChatSyncCenter.modelsTarget)
        XCTAssertEqual(store.chatSaveStatus, .serviceStopped)
        let cacheBefore = store.chatHistory.localFiles()
        say(store, "While stopped")
        XCTAssertEqual(store.chatHistory.localFiles(), cacheBefore, "memory only")
        XCTAssertEqual(store.chat.map(\.text), ["Before", "While stopped"])
        XCTAssertTrue(store.unsavedChats.contains(store.chatKey!))
        runner.failing = false
        await center.syncNow(ChatSyncCenter.modelsTarget)               // the service is back
        XCTAssertEqual(store.chatSaveStatus, .saving)
        await center.syncNow(ChatSyncCenter.modelsTarget)
        XCTAssertTrue(String(decoding: try XCTUnwrap(modelVolume.values.first), as: UTF8.self).contains("While stopped"))
        XCTAssertTrue(store.unsavedChats.isEmpty)
    }

    // MARK: Sandboxes

    private func sandbox(_ name: String, running: Bool, mounted: Bool, historyOff: Bool = false) -> Sandbox {
        var labels = ["deck.sandbox": "1"]
        if mounted { labels["deck.sandbox.chat-volume"] = "\(name)-chat" }
        if historyOff { labels["deck.sandbox.chat-history"] = "off" }
        return Sandbox(container: ContainerSummary(id: name, name: name, image: "alpine", state: running ? .running : .stopped, labels: labels))!
    }

    private func makeChats(_ boxes: [Sandbox]) -> SandboxChatStore {
        center.client = client
        let chats = SandboxChatStore(root: directory, defaults: defaults, sync: center)
        chats.sandboxes = { boxes }
        return chats
    }

    func testSandboxTransport() {
        let boxes = [sandbox("new", running: true, mounted: true), sandbox("stopped", running: false, mounted: true), sandbox("old", running: true, mounted: false)]
        XCTAssertEqual(SandboxChatStore.transport(for: "new", in: boxes), .exec(containerID: "new", directory: "/deck/chat"))
        XCTAssertEqual(SandboxChatStore.transport(for: "stopped", in: boxes), .helper(volume: "stopped-chat", labels: ChatVolumeSync.sandboxVolumeLabels("stopped")))
        XCTAssertEqual(SandboxChatStore.transport(for: "old", in: boxes), .helper(volume: "old-chat", labels: ChatVolumeSync.sandboxVolumeLabels("old")))
        XCTAssertNil(SandboxChatStore.transport(for: "gone", in: boxes))
    }

    func testRunningSandboxSavesThroughExec() async throws {
        let chats = makeChats([sandbox("box", running: true, mounted: true)])
        chats.ensureLoaded("box")
        chats.append(SandboxChatMessage(role: .user, content: "Hi"), to: "box")
        chats.save("box")
        await center.syncNow(ChatSyncCenter.sandboxTarget("box"))
        XCTAssertEqual(chats.saveStatus("box"), .saving)
        XCTAssertEqual(runner.volumes["exec:box"]?.count, 1)
        XCTAssertFalse(runner.calls.contains { $0.starts(with: ["volume", "create"]) }, "a mounted volume is never made by sync")
    }

    func testOlderSandboxGetsItsVolumeOnDemandThenAttachAfterRemoval() async throws {
        let chats = makeChats([sandbox("old", running: true, mounted: false)])
        chats.ensureLoaded("old")
        await center.syncNow(ChatSyncCenter.sandboxTarget("old"))
        XCTAssertNotNil(runner.volumes["old-chat"], "made on demand")
        XCTAssertEqual(defaults.stringArray(forKey: PrefKey.sandboxChatVolumesMade), ["old"])
        runner.volumes["old-chat"] = nil
        await center.syncNow(ChatSyncCenter.sandboxTarget("old"))
        XCTAssertEqual(chats.saveStatus("old"), .notAttached)
        await chats.noticeAction("old")                                // Attach Volume
        XCTAssertNotNil(runner.volumes["old-chat"])
        XCTAssertEqual(chats.saveStatus("old"), .saving)
    }

    func testStoppedSandboxWithRemovedVolume() async throws {
        let chats = makeChats([sandbox("box", running: false, mounted: true)])
        chats.ensureLoaded("box")
        await center.syncNow(ChatSyncCenter.sandboxTarget("box"))
        XCTAssertEqual(chats.saveStatus("box"), .volumeMissing)
        XCTAssertNil(runner.volumes["box-chat"])
    }

    func testSandboxSwitches() async throws {
        let chats = makeChats([sandbox("quiet", running: true, mounted: false, historyOff: true), sandbox("box", running: true, mounted: true)])
        XCTAssertFalse(chats.historyEnabled("quiet"), "made with Save chat history off")
        XCTAssertTrue(chats.historyEnabled("box"))
        chats.ensureLoaded("quiet")
        await center.syncNow(ChatSyncCenter.sandboxTarget("quiet"))
        XCTAssertEqual(chats.saveStatus("quiet"), .off)
        XCTAssertNil(runner.volumes["quiet-chat"], "no volume while off")
        await chats.noticeAction("quiet")                              // Turn On, from the notice or the Chat tab menu
        XCTAssertTrue(chats.historyEnabled("quiet"))
        XCTAssertNotNil(runner.volumes["quiet-chat"], "made on demand once turned on")
        XCTAssertEqual(chats.saveStatus("quiet"), .saving)
    }

    func testSandboxRemovalForgetsCacheAndSwitches() throws {
        let chats = makeChats([sandbox("box", running: true, mounted: true)])
        let cache = chats.history(for: "box")
        try cache.save(ChatHistory.sandboxKey("box"), messages: [SavedChatMessage(role: .user, text: "Hi")])
        chats.ensureLoaded("box")
        XCTAssertEqual(chats.messages["box"]?.map(\.content), ["Hi"], "the cache shows instantly")
        defaults.set(["box": false], forKey: PrefKey.sandboxChatHistory)
        chats.remove("box")
        XCTAssertNil(chats.messages["box"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.directory.path))
        XCTAssertNil((defaults.dictionary(forKey: PrefKey.sandboxChatHistory) as? [String: Bool])?["box"])
    }
}

final class AIModelsChatModelFailureTests: XCTestCase {
    /// A failed MLX answer shows the short model name, the plain message, Details and Pick another model.
    func testFailedMLXAnswerItem() {
        let path = "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/models/mlx-community/Qwen3.8-27B-MTP-4bit"
        var entry = AIModelsStore.ChatEntry(role: .assistant, text: "mlx-lm doesn't support model type qwen3_5_mtp yet. Pick another model.",
                                            failed: true, model: path, serverKind: .mlxLM)
        entry.details = "Server answer: generation thread died"
        entry.modelLoadFailed = true
        let item = AIChatView.items([entry], fallbackKind: nil)[0]
        XCTAssertEqual(item.author, "Qwen3.8-27B-MTP-4bit")
        XCTAssertEqual(item.authorHelp, path, "the full path stays as a tooltip")
        XCTAssertEqual(item.actionTitle, "Pick another model")
        XCTAssertEqual(item.details, "Server answer: generation thread died")
        let plain = AIChatView.items([AIModelsStore.ChatEntry(role: .assistant, text: "Could not connect.", failed: true, model: "qwen3:0.6b")], fallbackKind: .ollama)[0]
        XCTAssertNil(plain.actionTitle)
        XCTAssertEqual(plain.author, "qwen3:0.6b")
    }
}
