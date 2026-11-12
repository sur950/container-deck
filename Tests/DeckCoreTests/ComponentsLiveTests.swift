import XCTest
@testable import DeckCore

/// Runs the real Settings, Components checks on this Mac, for raising the tested versions in
/// `AppConfig.componentTested` after a tool ships a new release. Reads only: versions, help
/// text and the read only HTTP answers of running servers. Nothing is installed or started.
///
///     DECK_LIVE_COMPONENTS=1 swift test --filter ComponentsLiveTests
///
/// `DECK_OLLAMA_URL` points the Ollama checks and the thinking model chat at another server.
/// The chat test needs `DECK_LIVE_CHAT_MODEL` (a thinking model, like qwen3:0.6b).
final class ComponentsLiveTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private var ollamaURL: URL {
        env["DECK_OLLAMA_URL"].flatMap(URL.init(string:)) ?? AIConfig.ollamaURL
    }

    func testInstalledToolsPassTheHealthChecks() async throws {
        try XCTSkipUnless(env["DECK_LIVE_COMPONENTS"] == "1", "Set DECK_LIVE_COMPONENTS=1")
        let rows = await ComponentChecker().checkAll(force: true)
        let probe = ComponentHealthProbe(ollamaURL: ollamaURL)
        var lines: [String] = []
        var failures: [String] = []
        for row in rows where row.installed != nil && row.kind != .mcp {
            let report = await probe.probe(row)
            let checks = report?.checks ?? []
            let counts = Dictionary(grouping: checks, by: \.outcome).mapValues(\.count)
            let tested = row.testedText.map { "tested \($0)\(row.matchesTested ? "" : " (other line)")" } ?? "no tested line"
            lines.append("\(row.id) \(row.installed ?? "-") latest \(row.latest ?? "-"), \(tested): "
                         + "\(counts[.passed] ?? 0) passed, \(counts[.skipped] ?? 0) skipped, \(counts[.failed] ?? 0) failed")
            for check in checks where check.outcome != .passed {
                lines.append("    \(check.outcome.rawValue) \(check.id): \(check.detail ?? "")")
                if check.outcome == .failed { failures.append("\(row.id) \(check.id): \(check.detail ?? "")") }
            }
        }
        print(lines.joined(separator: "\n"))
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// A thinking model answers when no length cap is sent, and a small cap is reported as one.
    func testThinkingModelAnswers() async throws {
        try XCTSkipUnless(env["DECK_LIVE_COMPONENTS"] == "1", "Set DECK_LIVE_COMPONENTS=1")
        let model = env["DECK_LIVE_CHAT_MODEL"] ?? ""
        try XCTSkipIf(model.isEmpty, "Set DECK_LIVE_CHAT_MODEL")
        let base = ollamaURL.appendingPathComponent("v1")
        let question = [ChatMessage(role: .user, content: "Which is larger, 9.11 or 9.9? Answer with the number.")]

        func run(_ maxTokens: Int?) async throws -> (answer: String, thoughts: String, lengthStop: Bool) {
            var answer = "", thoughts = "", lengthStop = false
            for try await event in ChatClient().stream(baseURL: base, model: model, messages: question,
                                                       apiKey: ModelServerKind.ollama.placeholderAPIKey, maxTokens: maxTokens) {
                switch event {
                case .content(let text): answer += text
                case .reasoning(let text): thoughts += text
                case .finished where event.isLengthStop: lengthStop = true
                default: break
                }
            }
            // Servers that put the thoughts in the text wrap them in <think> tags.
            if thoughts.isEmpty, let end = answer.range(of: "</think>") {
                thoughts = String(answer[..<end.lowerBound])
                answer = String(answer[end.upperBound...])
            } else if thoughts.isEmpty, answer.hasPrefix("<think>") {
                (thoughts, answer) = (answer, "")
            }
            return (answer, thoughts, lengthStop)
        }

        let full = try await run(ModelServerKind.ollama.chatMaxTokens)
        print("no cap: answer \(full.answer.count) chars, thoughts \(full.thoughts.count) chars, length stop \(full.lengthStop)")
        XCTAssertFalse(full.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "no answer after thinking")
        XCTAssertFalse(full.lengthStop)

        let capped = try await run(16)
        print("cap 16: answer \(capped.answer.count) chars, thoughts \(capped.thoughts.count) chars, length stop \(capped.lengthStop)")
        XCTAssertTrue(capped.lengthStop, "a 16 token cap should end at the length limit")
    }
}
