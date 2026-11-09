import XCTest
@testable import DeckCore

/// Ollama API stand in: answers /api/version when running, records DELETE bodies.
private final class OllamaStandIn: AIHTTPFetching, @unchecked Sendable {
    var running = true
    var deleted: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard running else { throw URLError(.cannotConnectToHost) }
        let path = request.url?.path ?? ""
        if path.hasSuffix("/api/version") { return (Data(#"{"version":"0.16.2"}"#.utf8), 200) }
        if path.hasSuffix("/api/delete"), request.httpMethod == "DELETE",
           let body = request.httpBody, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let model = object["model"] as? String {
            deleted.append(model)
            return (Data(), 200)
        }
        return (Data(#"{"error":"not found"}"#.utf8), 404)
    }
}

final class AIModelsInventoryTests: XCTestCase {
    private var temp: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("deck-inventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func lmFolder() -> URL { temp.appendingPathComponent("lms-models", isDirectory: true) }

    private func makeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    private func merged(usage: [String: Date] = [:], servingMLX: String? = nil) throws -> [InstalledModel] {
        let ollama = try XCTUnwrap(ModelDiscoveryParser.parseOllamaTags(Data(AIFixtures.ollamaTags.utf8)))
        let loaded = ModelDiscoveryParser.markLoaded(ollama, loaded: ["qwen3:0.6b"])
        let lms = LMStudioRuntime.parseModels(LibraryFixtures.lmsList) + [
            LMStudioModel(id: "qwen/qwen3-4b", displayName: "Qwen3 4B", format: "mlx", sizeBytes: 2_280_000_000, parameters: "4B",
                          path: "lmstudio-community/Qwen3-4B-MLX-4bit")
        ]
        let mlxFolder = temp.appendingPathComponent("ai/models/mlx-community/SmolLM-135M-Instruct-4bit")
        let mlx = [LocalModel(repo: "mlx-community/SmolLM-135M-Instruct-4bit", folder: mlxFolder, modelPath: mlxFolder.path, sizeBytes: 75_000_000,
                              isComplete: true, modified: now.addingTimeInterval(-40 * day), source: .library)]
        let downloaded = now.addingTimeInterval(-60 * day)
        return ModelInventory.merge(
            ollama: loaded, ollamaFolder: temp.appendingPathComponent("ollama"),
            lmStudio: lms, lmStudioFolder: lmFolder(), mlx: mlx, servingMLXPath: servingMLX, usage: usage,
            fileDate: { url in url.path.contains("Qwen3-4B-MLX-4bit") ? downloaded : nil })
    }

    func testMergedListHasEverySource() throws {
        let models = try merged(usage: ["ollama:mistral:latest": now.addingTimeInterval(-2 * day)])
        XCTAssertEqual(models.count, 6)
        XCTAssertEqual(Set(models.map(\.source)), [.ollama, .lmStudio, .mlx])
        XCTAssertEqual(models.first?.key, "mistral:latest", "largest first")
        let mistral = try XCTUnwrap(models.first { $0.key == "mistral:latest" })
        XCTAssertEqual(mistral.detail, "7.2B, Q4_K_M")
        XCTAssertEqual(mistral.lastUsed, now.addingTimeInterval(-2 * day))
        XCTAssertNotNil(mistral.downloaded, "Ollama's modified_at")
        XCTAssertEqual(mistral.location?.path.hasSuffix("manifests/registry.ollama.ai/library/mistral/latest"), true)
        XCTAssertTrue(models.first { $0.key == "qwen3:0.6b" }?.isLoaded ?? false)

        let nomic = try XCTUnwrap(models.first { $0.key == "text-embedding-nomic-embed-text-v1.5" })
        XCTAssertTrue(nomic.isBuiltIn, "its file is not in LM Studio's models folder")
        XCTAssertFalse(nomic.isDeletable)
        XCTAssertEqual(nomic.whereText, "LM Studio, built in")
        let qwenLM = try XCTUnwrap(models.first { $0.key == "qwen/qwen3-4b" })
        XCTAssertFalse(qwenLM.isBuiltIn)
        XCTAssertEqual(qwenLM.name, "Qwen3 4B")
        XCTAssertEqual(qwenLM.detail, "4B, MLX")
        let smol = try XCTUnwrap(models.first { $0.source == .mlx })
        XCTAssertEqual(smol.whereText, AppConfig.appName)
        XCTAssertTrue(smol.id.hasPrefix("mlx:/"))
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
    }

    func testLMStudioBuiltInAndMissingFiles() {
        let bundled = temp.appendingPathComponent("bundled")
        let lms = [
            LMStudioModel(id: "nomic", path: "nomic-ai/n-GGUF/n.gguf"),
            LMStudioModel(id: "gone", path: "lmstudio-community/Gone-MLX")
        ]
        let models = ModelInventory.merge(ollama: [], lmStudio: lms, lmStudioFolder: lmFolder(), lmStudioBundledFolder: bundled,
                                          mlx: [], servingMLXPath: nil, usage: [:],
                                          fileDate: { $0.path.hasPrefix(bundled.path) && $0.path.hasSuffix("n.gguf") ? Date() : nil })
        let nomic = models.first { $0.key == "nomic" }
        XCTAssertEqual(nomic?.isBuiltIn, true)
        XCTAssertEqual(nomic?.filesMissing, false)
        let gone = models.first { $0.key == "gone" }
        XCTAssertEqual(gone?.isBuiltIn, false)
        XCTAssertEqual(gone?.filesMissing, true)
        XCTAssertEqual(gone?.isDeletable, false)
        XCTAssertEqual(gone?.whereText, "LM Studio, files missing")
        XCTAssertFalse(ModelInventory.isUnused(gone!), "nothing to free")
        let remover = ModelRemover(runner: MockRunner(), ollamaCLI: nil, lmStudioFolder: lmFolder(), mlxStore: LocalModelStore(paths: AIPaths(base: temp)))
        XCTAssertThrowsError(try remover.plan(gone!))
    }

    func testWhereShowsTheRealFolder() {
        let home = NSHomeDirectory()
        let ollama = InstalledModel(source: .ollama, key: "qwen3:0.6b", sizeBytes: 1,
                                    location: URL(fileURLWithPath: home + "/.ollama/models/manifests/registry.ollama.ai/library/qwen3/0.6b"))
        XCTAssertEqual(ollama.folderText, "~/.ollama/models")
        let gguf = InstalledModel(source: .lmStudio, key: "q", sizeBytes: 1,
                                  location: URL(fileURLWithPath: home + "/.lmstudio/models/lmstudio-community/Qwen3-4B-GGUF/Qwen3-4B-Q4_K_M.gguf"))
        XCTAssertEqual(gguf.folderText, "~/.lmstudio/models/lmstudio-community/Qwen3-4B-GGUF")
        let mlx = InstalledModel(source: .lmStudio, key: "m", sizeBytes: 1,
                                 location: URL(fileURLWithPath: home + "/.lmstudio/models/lmstudio-community/Qwen3-4B-MLX-4bit"))
        XCTAssertEqual(mlx.folderText, "~/.lmstudio/models/lmstudio-community/Qwen3-4B-MLX-4bit")
        XCTAssertNil(InstalledModel(source: .lmStudio, key: "gone", sizeBytes: 1).folderText)
        XCTAssertEqual(InstalledModel(source: .mlx, key: "x", sizeBytes: 1, location: URL(fileURLWithPath: "/tmp/ai/models/x")).folderText, "/tmp/ai/models/x")
    }

    func testServedMLXModelCountsAsLoaded() throws {
        let path = temp.appendingPathComponent("ai/models/mlx-community/SmolLM-135M-Instruct-4bit").path
        XCTAssertTrue(try merged(servingMLX: path).first { $0.source == .mlx }?.isLoaded ?? false)
    }

    func testUnusedRule() throws {
        let fresh = now.addingTimeInterval(-3 * day)
        let old = now.addingTimeInterval(-45 * day)
        func model(_ key: String, used: Date? = nil, downloaded: Date? = nil, loaded: Bool = false, builtIn: Bool = false) -> InstalledModel {
            InstalledModel(source: .ollama, key: key, sizeBytes: 1, downloaded: downloaded, lastUsed: used, isLoaded: loaded, isBuiltIn: builtIn)
        }
        XCTAssertTrue(ModelInventory.isUnused(model("old", used: old, downloaded: old), now: now))
        XCTAssertFalse(ModelInventory.isUnused(model("recent", used: fresh, downloaded: old), now: now))
        XCTAssertTrue(ModelInventory.isUnused(model("never-used-old", downloaded: old), now: now), "never used, downloaded long ago")
        XCTAssertFalse(ModelInventory.isUnused(model("never-used-new", downloaded: fresh), now: now), "just downloaded is not a suggestion")
        XCTAssertTrue(ModelInventory.isUnused(model("no-dates"), now: now))
        XCTAssertFalse(ModelInventory.isUnused(model("loaded", used: old, loaded: true), now: now), "loaded models are never suggested")
        XCTAssertFalse(ModelInventory.isUnused(model("built-in", builtIn: true), now: now))
        XCTAssertTrue(ModelInventory.isUnused(model("edge", used: now.addingTimeInterval(-30 * day)), now: now), "30 days counts")

        let models = try merged(usage: ["ollama:mistral:latest": fresh])
        let suggested = ModelInventory.suggested(models, now: now)
        XCTAssertFalse(suggested.contains("ollama:mistral:latest"), "used 3 days ago")
        XCTAssertFalse(suggested.contains("ollama:qwen3:0.6b"), "loaded")
        XCTAssertFalse(suggested.contains("lmStudio:text-embedding-nomic-embed-text-v1.5"), "built in")
        XCTAssertTrue(suggested.contains("lmStudio:qwen/qwen3-4b"), "downloaded 60 days ago, never used")
        XCTAssertTrue(suggested.contains { $0.hasPrefix("mlx:") }, "downloaded 40 days ago")
    }

    func testTotalsForTheDashboard() throws {
        let models = try merged()
        let totals = ModelInventory.totals(models)
        XCTAssertEqual(totals.count, 6)
        XCTAssertEqual(totals.bySource[.ollama], 4_372_824_384 + 637_700_138 + 522_653_767)
        XCTAssertEqual(totals.bySource[.lmStudio], 84_106_624 + 2_280_000_000)
        XCTAssertEqual(totals.bySource[.mlx], 75_000_000)
        XCTAssertEqual(totals.total, models.reduce(0) { $0 + $1.sizeBytes })
        XCTAssertEqual(totals.breakdown { "\($0 / 1_000_000) MB" }, "Ollama 5533 MB, LM Studio 2364 MB, MLX 75 MB")
        XCTAssertEqual(ModelDiskTotals().breakdown { "\($0)" }, "")
        let picked: Set<String> = ["ollama:mistral:latest", "lmStudio:qwen/qwen3-4b"]
        XCTAssertEqual(ModelInventory.size(of: picked, in: models), 4_372_824_384 + 2_280_000_000)
    }

    func testUsageLogRecordsAndKeepsNewest() {
        let log = ModelUsageLog(url: temp.appendingPathComponent("ai/model-usage.json"))
        XCTAssertEqual(log.load(), [:])
        log.record(.ollama, key: "qwen3:0.6b", at: now)
        log.record(.ollama, key: "qwen3:0.6b", at: now.addingTimeInterval(-day))
        log.record([(.lmStudio, "qwen/qwen3-4b"), (.mlx, "")], at: now)
        let saved = log.load()
        XCTAssertEqual(saved["ollama:qwen3:0.6b"]?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(saved["lmStudio:qwen/qwen3-4b"])
        XCTAssertEqual(saved.count, 2, "empty keys are skipped")
        log.forget(.lmStudio, key: "qwen/qwen3-4b")
        XCTAssertNil(log.load()["lmStudio:qwen/qwen3-4b"])
    }

    func testOllamaManifestReaderWorksWithoutTheServer() throws {
        let root = temp.appendingPathComponent("ollama-models")
        let manifest = root.appendingPathComponent("manifests/registry.ollama.ai/library/qwen3/latest")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(LibraryFixtures.ollamaManifest.utf8).write(to: manifest)
        let other = root.appendingPathComponent("manifests/registry.ollama.ai/someone/tool/v1")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(LibraryFixtures.ollamaManifest.utf8).write(to: other)
        let models = OllamaManifestReader(root: root).list()
        XCTAssertEqual(models.map(\.id), ["qwen3:latest", "someone/tool:v1"])
        XCTAssertEqual(models.first?.sizeBytes, 5_225_388_164)
        XCTAssertNotNil(models.first?.modifiedAt)
        XCTAssertEqual(OllamaManifestReader(root: temp.appendingPathComponent("none")).list(), [])
    }

    // MARK: Delete

    func testOllamaDeleteUsesTheAPIWhenRunning() async throws {
        let http = OllamaStandIn()
        let runner = MockRunner()
        let remover = ModelRemover(runner: runner, ollama: OllamaClient(baseURL: URL(string: "http://127.0.0.1:1")!, http: http),
                                   ollamaCLI: "/stand-in/ollama", lmStudioFolder: lmFolder(), mlxStore: LocalModelStore(paths: AIPaths(base: temp)))
        let model = InstalledModel(source: .ollama, key: "tinyllama:latest", sizeBytes: 637_700_138)
        let plan = try remover.plan(model)
        XCTAssertEqual(plan.target, "ollama rm tinyllama:latest")
        XCTAssertFalse(plan.deletesFiles)
        let freed = try await remover.remove(plan)
        XCTAssertEqual(freed, 637_700_138)
        XCTAssertEqual(http.deleted, ["tinyllama:latest"])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testOllamaDeleteFallsBackToTheCommand() async throws {
        let http = OllamaStandIn()
        http.running = false
        let runner = MockRunner()
        runner.responses["rm tinyllama:latest"] = CommandResult(exitCode: 0, stdout: "deleted 'tinyllama:latest'")
        let remover = ModelRemover(runner: runner, ollama: OllamaClient(baseURL: URL(string: "http://127.0.0.1:1")!, http: http),
                                   ollamaCLI: "/stand-in/ollama", lmStudioFolder: lmFolder(), mlxStore: LocalModelStore(paths: AIPaths(base: temp)))
        let plan = try remover.plan(InstalledModel(source: .ollama, key: "tinyllama:latest", sizeBytes: 10))
        try await remover.remove(plan)
        XCTAssertEqual(runner.calls, [["/stand-in/ollama", "rm", "tinyllama:latest"]])

        runner.responses["rm mistral:latest"] = CommandResult(exitCode: 1, stdout: "", stderr: "Error: could not connect to ollama app, is it running?")
        let failing = try remover.plan(InstalledModel(source: .ollama, key: "mistral:latest", sizeBytes: 10))
        do {
            try await remover.remove(failing)
            XCTFail("a stopped server is reported")
        } catch let error as ModelRemovalError {
            XCTAssertEqual(error, .ollamaNotRunning)
        }
        let noCLI = ModelRemover(runner: runner, ollama: OllamaClient(baseURL: URL(string: "http://127.0.0.1:1")!, http: http),
                                 ollamaCLI: nil, lmStudioFolder: lmFolder(), mlxStore: LocalModelStore(paths: AIPaths(base: temp)))
        do {
            try await noCLI.remove(failing)
            XCTFail("no server and no command")
        } catch let error as ModelRemovalError {
            XCTAssertEqual(error.errorDescription, "Start Ollama to delete its models.")
        }
    }

    func testLoadedAndBuiltInModelsAreRefused() {
        let remover = ModelRemover(runner: MockRunner(), ollamaCLI: nil, lmStudioFolder: lmFolder(), mlxStore: LocalModelStore(paths: AIPaths(base: temp)))
        XCTAssertThrowsError(try remover.plan(InstalledModel(source: .ollama, key: "qwen3:0.6b", sizeBytes: 1, isLoaded: true))) { error in
            XCTAssertEqual(error as? ModelRemovalError, .loaded("qwen3:0.6b"))
        }
        XCTAssertThrowsError(try remover.plan(InstalledModel(source: .lmStudio, key: "nomic", sizeBytes: 1, isBuiltIn: true,
                                                             lmStudioPath: "nomic-ai/x/y.gguf")))
        XCTAssertThrowsError(try remover.plan(InstalledModel(source: .lmStudio, key: "evil", sizeBytes: 1, lmStudioPath: "../../Documents")))
        XCTAssertThrowsError(try remover.plan(InstalledModel(source: .lmStudio, key: "flat", sizeBytes: 1, lmStudioPath: "model.gguf")),
                             "a file right in the models folder is not a model folder")
    }

    func testLMStudioDeleteRemovesTheModelFolder() async throws {
        let folder = lmFolder().appendingPathComponent("lmstudio-community/Qwen3-4B-MLX-4bit")
        try makeFile(folder.appendingPathComponent("model.safetensors"), bytes: 4096)
        try makeFile(folder.appendingPathComponent("config.json"), bytes: 10)
        let keep = lmFolder().appendingPathComponent("bartowski/Other-GGUF/other.gguf")
        try makeFile(keep, bytes: 100)
        let remover = ModelRemover(runner: MockRunner(), ollamaCLI: nil, lmStudioFolder: lmFolder(), mlxStore: LocalModelStore(paths: AIPaths(base: temp)))
        let model = InstalledModel(source: .lmStudio, key: "qwen/qwen3-4b", sizeBytes: 4106, lmStudioPath: "lmstudio-community/Qwen3-4B-MLX-4bit")
        let plan = try remover.plan(model)
        XCTAssertEqual(plan.target, folder.path)
        XCTAssertTrue(plan.deletesFiles)
        let freed = try await remover.remove(plan)
        XCTAssertGreaterThan(freed, 4000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path), "empty publisher folder removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path), "other models stay")
    }

    func testLMStudioSharedFolderRemovesOnlyTheFile() async throws {
        let q4 = lmFolder().appendingPathComponent("lmstudio-community/Qwen3-4B-GGUF/Qwen3-4B-Q4_K_M.gguf")
        let q8 = lmFolder().appendingPathComponent("lmstudio-community/Qwen3-4B-GGUF/Qwen3-4B-Q8_0.gguf")
        try makeFile(q4, bytes: 200)
        try makeFile(q8, bytes: 400)
        let a = InstalledModel(source: .lmStudio, key: "qwen3-4b@q4_k_m", sizeBytes: 200, lmStudioPath: "lmstudio-community/Qwen3-4B-GGUF/Qwen3-4B-Q4_K_M.gguf")
        let b = InstalledModel(source: .lmStudio, key: "qwen3-4b@q8_0", sizeBytes: 400, lmStudioPath: "lmstudio-community/Qwen3-4B-GGUF/Qwen3-4B-Q8_0.gguf")
        let remover = ModelRemover(runner: MockRunner(), ollamaCLI: nil, lmStudioFolder: lmFolder(), mlxStore: LocalModelStore(paths: AIPaths(base: temp)))
        let plan = try remover.plan(a, among: [a, b])
        XCTAssertEqual(plan.action, .lmStudioFile(q4))
        try await remover.remove(plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: q4.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: q8.path))
    }

    func testLMStudioDeleteChecksTheFolderAgain() async throws {
        let remover = ModelRemover(runner: MockRunner(), ollamaCLI: nil, lmStudioFolder: lmFolder(), mlxStore: LocalModelStore(paths: AIPaths(base: temp)))
        let outside = InstalledModel(source: .lmStudio, key: "x", sizeBytes: 1)
        let forged = ModelRemovalPlan(model: outside, action: .lmStudioFolder(temp.appendingPathComponent("Documents/notes")), bytes: 1)
        do {
            try await remover.remove(forged)
            XCTFail("folders outside LM Studio's models folder are never deleted")
        } catch let error as ModelRemovalError {
            if case .unsafePath = error {} else { XCTFail("\(error)") }
        }
    }

    func testMLXDeleteUsesTheLibraryFolder() async throws {
        let paths = AIPaths(base: temp.appendingPathComponent("ai"))
        let folder = paths.modelFolder("mlx-community/SmolLM-135M-Instruct-4bit")
        try makeFile(folder.appendingPathComponent("model.safetensors"), bytes: 2048)
        let local = LocalModel(repo: "mlx-community/SmolLM-135M-Instruct-4bit", folder: folder, modelPath: folder.path, sizeBytes: 2048,
                               isComplete: true, modified: nil, source: .library)
        let remover = ModelRemover(runner: MockRunner(), ollamaCLI: nil, lmStudioFolder: lmFolder(), mlxStore: LocalModelStore(paths: paths, huggingFaceCache: temp.appendingPathComponent("hf")))
        let model = InstalledModel(source: .mlx, key: local.repo, sizeBytes: 2048, location: folder, local: local)
        let plan = try remover.plan(model)
        XCTAssertEqual(plan.target, folder.path)
        let freed = try await remover.remove(plan)
        XCTAssertGreaterThan(freed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testSafeRelativePaths() {
        XCTAssertTrue(ModelRemover.isSafeRelativePath("a/b/c.gguf"))
        XCTAssertFalse(ModelRemover.isSafeRelativePath("/etc/passwd"))
        XCTAssertFalse(ModelRemover.isSafeRelativePath("a/../b"))
        XCTAssertFalse(ModelRemover.isSafeRelativePath("a//b"))
        XCTAssertFalse(ModelRemover.isSafeRelativePath("~/x"))
        XCTAssertFalse(ModelRemover.isSafeRelativePath(""))
    }
}
