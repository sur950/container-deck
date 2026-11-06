import XCTest
@testable import DeckCore

final class ChatHistoryTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-history-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveAndLoad() throws {
        let history = ChatHistory(directory: directory)
        let key = ChatHistory.key(server: .ollama, port: 11434, model: "qwen3:0.6b")
        let start = Date(timeIntervalSince1970: 1000.25)
        let messages = [
            SavedChatMessage(role: .user, text: "Hi"),
            SavedChatMessage(role: .assistant, text: "Hello **there**", reasoning: "greet", model: "qwen3:0.6b", server: "ollama",
                             started: start, firstToken: start.addingTimeInterval(0.181), finished: start.addingTimeInterval(1), tokens: 12)
        ]
        try history.save(key, messages: messages)
        XCTAssertEqual(history.load(key), messages, "dates keep milliseconds")
        XCTAssertEqual(history.load("model-other"), [])
        let attributes = try FileManager.default.attributesOfItem(atPath: history.url(for: key).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testClearAndEmptySaveDeleteTheFile() throws {
        let history = ChatHistory(directory: directory)
        let key = ChatHistory.sandboxKey("python")
        try history.save(key, messages: [SavedChatMessage(role: .user, text: "Hi")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.url(for: key).path))
        history.clear(key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.url(for: key).path))
        XCTAssertEqual(history.load(key), [])
        try history.save(key, messages: [SavedChatMessage(role: .user, text: "Hi")])
        try history.save(key, messages: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.url(for: key).path))
    }

    func testCapKeepsTheLastMessages() throws {
        let history = ChatHistory(directory: directory)
        let messages = (0..<250).map { SavedChatMessage(role: $0 % 2 == 0 ? .user : .assistant, text: "m\($0)") }
        try history.save("k", messages: messages)
        let loaded = history.load("k")
        XCTAssertEqual(loaded.count, ChatHistory.maxMessages)
        XCTAssertEqual(loaded.first?.text, "m50")
        XCTAssertEqual(loaded.last?.text, "m249")
    }

    func testFileNamesAreSafeAndDistinct() {
        let history = ChatHistory(directory: directory)
        let a = history.url(for: "model-ollama-11434-qwen3:0.6b")
        let b = history.url(for: "model-ollama-11434-qwen3_0.6b")
        XCTAssertNotEqual(a, b, "different keys never share a file")
        XCTAssertFalse(a.lastPathComponent.contains(":"))
        XCTAssertEqual(history.url(for: "../../etc/passwd").deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(history.url(for: "x"), history.url(for: "x"), "stable")
    }

    func testBadFileLoadsNothing() throws {
        let history = ChatHistory(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: history.url(for: "k"))
        XCTAssertEqual(history.load("k"), [])
    }

    func testSandboxRemovalDeletesOnlyThatChat() throws {
        let history = ChatHistory(directory: directory)
        try history.save(ChatHistory.sandboxKey("a"), messages: [SavedChatMessage(role: .user, text: "a")])
        try history.save(ChatHistory.sandboxKey("b"), messages: [SavedChatMessage(role: .user, text: "b")])
        history.clear(ChatHistory.sandboxKey("a"))
        XCTAssertEqual(history.load(ChatHistory.sandboxKey("a")), [])
        XCTAssertEqual(history.load(ChatHistory.sandboxKey("b")).map(\.text), ["b"])
    }
}
