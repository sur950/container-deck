import XCTest
import DeckCore
@testable import ContainerDeck

/// The AI models row on the Dashboard, the AI part of Free Up Space and the Model Library store.
@MainActor
final class DashboardModelsTests: XCTestCase {
    private let old = Date(timeIntervalSinceNow: -60 * 86_400)

    private var library: ModelLibraryStore { ModelLibraryStore.shared }
    private var ai: AIModelsStore { AIModelsStore.shared }

    override func tearDown() async throws {
        library.installed = []
        library.ollamaResults = []
        library.lmResults = []
        library.filter = .all
        ai.results = []
        ai.ollamaLoaded = false
        ai.ollamaRunning = false
        ai.ollamaInstalled = false
        ai.lmLoaded = false
        ai.lmStatus = nil
    }

    func testModelsSummaryForTheDiskCard() {
        XCTAssertEqual(DashboardCounts.modelsSummary(ModelDiskTotals()), "None downloaded")
        XCTAssertEqual(DashboardCounts.modelsSummary(ModelDiskTotals(bySource: [.ollama: 5], count: 1)), "1 model from Ollama")
        XCTAssertEqual(DashboardCounts.modelsSummary(ModelDiskTotals(bySource: [.ollama: 5, .mlx: 9, .lmStudio: 1], count: 6)),
                       "6 models from MLX, Ollama and LM Studio", "largest first")
    }

    func testFreeUpSuggestionsSkipOllamaWhileItIsStopped() {
        library.installed = [
            InstalledModel(source: .ollama, key: "mistral:latest", sizeBytes: 4_000, downloaded: old),
            InstalledModel(source: .lmStudio, key: "qwen/qwen3-4b", sizeBytes: 2_000, downloaded: old, lmStudioPath: "a/b"),
            InstalledModel(source: .ollama, key: "qwen3:0.6b", sizeBytes: 500, downloaded: old, isLoaded: true),
            InstalledModel(source: .mlx, key: "mlx-community/x", sizeBytes: 100, downloaded: Date(), lastUsed: Date())
        ]
        ai.ollamaRunning = false
        XCTAssertEqual(library.cleanupSuggestions, ["lmStudio:qwen/qwen3-4b"], "Ollama deletes need its server")
        ai.ollamaRunning = true
        XCTAssertEqual(library.cleanupSuggestions, ["lmStudio:qwen/qwen3-4b", "ollama:mistral:latest"], "loaded and recent ones stay")
        XCTAssertEqual(ModelInventory.size(of: library.cleanupSuggestions, in: library.installed), 6_000)
        XCTAssertEqual(library.totals.total, 6_600)
        XCTAssertEqual(library.totals.breakdown { "\($0)" }, "Ollama 4500, LM Studio 2000, MLX 100")
    }

    func testRowsFollowTheSourceFilter() {
        ai.results = [HFModel(id: "mlx-community/Qwen3-4B-4bit")]
        library.ollamaResults = [OllamaLibraryModel(name: "qwen3", sizes: ["4b"])]
        library.lmResults = [LMStudioCatalogModel(identifier: "qwen/qwen3-4b", isStaffPick: true)]
        library.filter = .all
        XCTAssertEqual(library.rows.map(\.source), [.mlx, .ollama, .lmStudio])
        library.filter = .ollama
        XCTAssertEqual(library.rows.map(\.id), ["ollama:qwen3"])
        library.filter = .lmStudio
        XCTAssertEqual(library.rows.map(\.key), ["qwen/qwen3-4b"])
        XCTAssertTrue(LibrarySourceFilter.all.includes(.mlx))
        XCTAssertFalse(LibrarySourceFilter.mlx.includes(.ollama))
        XCTAssertEqual(LibrarySourceFilter.allCases.map(\.title), ["All", "MLX", "Ollama", "LM Studio"])
    }

    func testDownloadBlockersPointToTheRightTab() {
        ai.ollamaLoaded = true
        ai.ollamaInstalled = false
        XCTAssertEqual(library.blocker(.ollama)?.tab, .ollama)
        XCTAssertEqual(library.blocker(.ollama)?.reason, "Ollama is not installed.")
        ai.ollamaInstalled = true
        ai.ollamaRunning = false
        XCTAssertEqual(library.blocker(.ollama)?.reason, "Start Ollama to download.")
        ai.ollamaRunning = true
        XCTAssertNil(library.blocker(.ollama))

        ai.lmLoaded = true
        ai.lmStatus = LMStudioStatus()
        XCTAssertEqual(library.blocker(.lmStudio)?.tab, .lmStudio)
        XCTAssertEqual(library.blocker(.lmStudio)?.reason, "LM Studio is not installed.")
        ai.lmStatus = LMStudioStatus(cliPath: "/stand-in/lms")
        XCTAssertNil(library.blocker(.lmStudio))
        XCTAssertNil(library.blocker(.mlx), "MLX downloads need nothing installed")
    }

    func testOllamaPullNameUsesThePickedTag() {
        library.ollamaPickedTag["qwen3"] = "0.6b"
        XCTAssertEqual(library.ollamaPullName("qwen3"), "qwen3:0.6b")
        library.ollamaPickedTag["qwen3"] = "latest"
        XCTAssertEqual(library.ollamaPullName("qwen3"), "qwen3")
        library.ollamaPickedTag["qwen3"] = nil
    }

    func testLastUsedText() {
        XCTAssertEqual(AILibraryView.lastUsedText(InstalledModel(source: .ollama, key: "a", sizeBytes: 1, isLoaded: true)), "Now")
        XCTAssertEqual(AILibraryView.lastUsedText(InstalledModel(source: .ollama, key: "a", sizeBytes: 1)), "Not yet")
    }
}
