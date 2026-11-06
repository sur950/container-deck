import XCTest
import DeckCore
@testable import ContainerDeck

final class AIModelsViewTests: XCTestCase {
    func testChatCaption() {
        let start = Date(timeIntervalSince1970: 0)
        var stats = ChatStats(started: start)
        stats.record(.content("a"), at: start.addingTimeInterval(0.1))
        stats.record(.done, at: start.addingTimeInterval(0.11))
        XCTAssertEqual(AIChatBubble.caption(stats), "1 token, first token in 100 ms", "no speed for one token")
        for i in 1...20 { stats.record(.content("b"), at: start.addingTimeInterval(0.1 + Double(i) * 0.05)) }
        stats.finished = start.addingTimeInterval(1.1)
        XCTAssertEqual(AIChatBubble.caption(stats), "20.0 tok/s, 21 tokens, first token in 100 ms")
    }

    func testFormats() {
        XCTAssertEqual(AIFormat.tokensPerSecond(nil), "-")
        XCTAssertEqual(AIFormat.tokensPerSecond(361.4), "361 tok/s")
        XCTAssertEqual(AIFormat.seconds(1.5), "1.5 s")
        let loopback = ModelEndpoint(id: "a", kind: .ollama, host: "127.0.0.1", port: 11434, baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                                     status: .running, bindAddress: "127.0.0.1")
        XCTAssertEqual(AIFormat.bindText(loopback), "This Mac only")
        var gateway = loopback
        gateway.bindAddress = "192.168.64.1"
        XCTAssertEqual(AIFormat.bindText(gateway), "Containers on 192.168.64.1")
        gateway.bindAddress = "*"
        XCTAssertEqual(AIFormat.bindText(gateway), "All addresses")
    }

    func testTabsHaveTitles() {
        XCTAssertEqual(AITab.allCases.map(\.title), ["Servers", "MLX", "Ollama", "Model Library", "Chat"])
        XCTAssertEqual(ModelServerKind.mlxLM.deckIcon, .cpu)
    }
}
