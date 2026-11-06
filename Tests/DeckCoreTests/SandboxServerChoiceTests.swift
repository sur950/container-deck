import XCTest
@testable import DeckCore

final class SandboxServerChoiceTests: XCTestCase {
    private func source(_ title: String, _ url: String, kind: SandboxModelKind = .openAI, model: String? = nil) -> ManualModelSource {
        ManualModelSource(title: title, kind: kind, baseURL: URL(string: url)!, defaultModel: model)
    }

    func testRunningOllamaReplacesThePresetInsteadOfShowingTwice() {
        let choices = SandboxServerChoice.merge(sources: [source("Ollama", "http://localhost:11434", kind: .ollama, model: "qwen3:0.6b")])
        XCTAssertEqual(choices.map(\.title), ["Ollama", "LM Studio", "MLX server"])
        XCTAssertTrue(choices[0].isRunning)
        XCTAssertEqual(choices[0].source?.defaultModel, "qwen3:0.6b")
        XCTAssertFalse(choices[1].isRunning)
        XCTAssertFalse(choices[2].isRunning)
    }

    func testOtherServersAreAddedAfterThePresets() {
        let choices = SandboxServerChoice.merge(sources: [
            source("vLLM", "http://192.168.1.20:8000/v1"),
            source("LM Studio", "http://127.0.0.1:1234/v1"),
        ])
        XCTAssertEqual(choices.map(\.title), ["Ollama", "LM Studio", "MLX server", "vLLM"])
        XCTAssertTrue(choices[1].isRunning)
        XCTAssertTrue(choices[3].isRunning)
    }

    func testSameServerIgnoresPathAndTreatsLocalHostsAlike() {
        XCTAssertTrue(SandboxServerChoice.sameServer("http://127.0.0.1:1234/v1", "http://localhost:1234"))
        XCTAssertTrue(SandboxServerChoice.sameServer("http://[::1]:8080/v1", "http://127.0.0.1:8080/v1"))
        XCTAssertFalse(SandboxServerChoice.sameServer("http://127.0.0.1:1234/v1", "http://127.0.0.1:8080/v1"))
        XCTAssertFalse(SandboxServerChoice.sameServer("http://10.0.0.2:11434", "http://127.0.0.1:11434"))
        XCTAssertFalse(SandboxServerChoice.sameServer("not a url", "http://127.0.0.1:11434"))
    }

    func testDuplicateDiscoveredServersShowOnce() {
        let choices = SandboxServerChoice.merge(sources: [
            source("Ollama", "http://127.0.0.1:11434", kind: .ollama),
            source("Ollama", "http://localhost:11434", kind: .ollama),
        ])
        XCTAssertEqual(choices.filter { $0.title == "Ollama" }.count, 1)
    }
}
