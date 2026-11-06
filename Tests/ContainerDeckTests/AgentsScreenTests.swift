import XCTest
import DeckCore
@testable import ContainerDeck

/// App side logic of the Agents and MCP screen.
final class AgentsScreenTests: XCTestCase {
    func testShellWordsSplitsLikeAShell() {
        XCTAssertEqual(MCPCommandWords.split("node dist/index.js --transport http"), ["node", "dist/index.js", "--transport", "http"])
        XCTAssertEqual(MCPCommandWords.split(#"npx -y "@scope/server name" 'a b' c\ d"#), ["npx", "-y", "@scope/server name", "a b", "c d"])
        XCTAssertEqual(MCPCommandWords.split(#"run "" x"#), ["run", "", "x"])
        XCTAssertEqual(MCPCommandWords.split("   "), [])
    }

    func testCatalogArgumentsRoundTripThroughTheForm() {
        // The install sheet shows catalog arguments as text and splits them again on install.
        for item in MCPCatalog.items {
            let text = item.command.map(MCPLaunch.shellQuote).joined(separator: " ")
            XCTAssertEqual(MCPCommandWords.split(text), item.command, item.id)
        }
    }

    func testCatalogItemsAreComplete() {
        XCTAssertEqual(Set(MCPCatalog.items.map(\.id)).count, MCPCatalog.items.count)
        for item in MCPCatalog.items {
            XCTAssertTrue(MCPLaunch.isValidName(MCPLaunch.suggestedName(item.id)), item.id)
            if item.transport != .stdio {
                XCTAssertNotNil(item.containerPort, item.id)
                XCTAssertNotNil(item.path, item.id)
            }
            XCTAssertFalse(item.summary.contains(";"), item.id)
            XCTAssertFalse(item.summary.contains("—"), item.id)
        }
    }

    func testScopeLabelsAndTabs() {
        XCTAssertEqual(AgentConfigScope.user.label, "User")
        XCTAssertEqual(AgentConfigScope.project("/Users/me/code/app").label, "Project app")
        XCTAssertEqual(AgentConfigScope.local("/Users/me/code/app").label, "Local app")
        XCTAssertEqual(AgentsTab.allCases.map(\.title), ["Servers", "Catalog", "Agents", "API Keys"])
    }
}
