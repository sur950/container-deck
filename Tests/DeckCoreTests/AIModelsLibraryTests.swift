import XCTest
@testable import DeckCore

final class AIModelsLibraryTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("deck-ai-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: Hugging Face

    func testParseSearch() throws {
        let models = try XCTUnwrap(HuggingFaceClient.parseSearch(Data(AIFixtures.hfSearch.utf8)))
        XCTAssertEqual(models.map(\.id), ["mlx-community/SmolLM-135M-Instruct-4bit", "mlx-community/SmolLM2-135M-Instruct", "mlx-community/SmolLM3-3B-4bit"])
        let first = models[0]
        XCTAssertEqual(first.name, "SmolLM-135M-Instruct-4bit")
        XCTAssertEqual(first.author, "mlx-community")
        XCTAssertEqual(first.downloads, 8305)
        XCTAssertEqual(first.parameters, 134_515_008)
        XCTAssertEqual(first.parameterText, "135M")
        XCTAssertEqual(first.quantization, "4bit")
        XCTAssertEqual(first.pipelineTag, "text-generation")
        XCTAssertNotNil(first.lastModified)
        XCTAssertEqual(models[2].parameterText, "3.1B")
        XCTAssertNil(models[1].quantization)
        XCTAssertNil(HuggingFaceClient.parseSearch(Data(#"{"error":"bad"}"#.utf8)))
    }

    func testParseTreeAndNeededFiles() throws {
        let files = try XCTUnwrap(HuggingFaceClient.parseTree(Data(AIFixtures.hfTree.utf8)))
        XCTAssertEqual(files.count, 10)
        let needed = files.filter { HuggingFaceClient.isNeeded($0.path) }
        XCTAssertEqual(needed.map(\.path), ["config.json", "merges.txt", "model.safetensors", "model.safetensors.index.json",
                                            "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "vocab.json"])
        XCTAssertEqual(needed.first { $0.path == "model.safetensors" }?.size, 75_789_919)
        XCTAssertEqual(needed.reduce(0) { $0 + $1.size }, 79_215_554)
        XCTAssertFalse(HuggingFaceClient.isNeeded("../escape.json"))
        XCTAssertFalse(HuggingFaceClient.isNeeded("pytorch_model.bin"))
        XCTAssertTrue(HuggingFaceClient.isNeeded("chat_template.jinja"))
    }

    func testURLs() {
        let search = HuggingFaceClient.searchURL("qwen 3", author: "mlx-community", limit: 30).absoluteString
        XCTAssertTrue(search.hasPrefix("https://huggingface.co/api/models?author=mlx-community&pipeline_tag=text-generation&sort=downloads&direction=-1&limit=30&search=qwen%203"))
        XCTAssertTrue(search.contains("expand%5B%5D=safetensors") || search.contains("expand[]=safetensors"))
        XCTAssertFalse(HuggingFaceClient.searchURL("", author: "mlx-community", limit: 5).absoluteString.contains("search="))
        XCTAssertEqual(HuggingFaceClient.treeURL("mlx-community/SmolLM-135M-Instruct-4bit")?.absoluteString,
                       "https://huggingface.co/api/models/mlx-community/SmolLM-135M-Instruct-4bit/tree/main?recursive=true")
        XCTAssertEqual(HuggingFaceClient.resolveURL("mlx-community/X", path: "sub dir/model.safetensors")?.absoluteString,
                       "https://huggingface.co/mlx-community/X/resolve/main/sub%20dir/model.safetensors")
        XCTAssertNil(HuggingFaceClient.treeURL("../etc"))
        XCTAssertFalse(HuggingFaceClient.isRepoID("a/b/c"))
        XCTAssertFalse(HuggingFaceClient.isRepoID("a/.."))
        XCTAssertTrue(HuggingFaceClient.isRepoID("mlx-community/Qwen3-0.6B-4bit"))
    }

    // MARK: Local models

    func testLocalStoreListsLibraryAndCacheModels() throws {
        let paths = AIPaths(base: temp.appendingPathComponent("AI"))
        let cache = temp.appendingPathComponent("hub")

        // Finished library model.
        let done = paths.modelFolder("mlx-community/Done-4bit")
        try FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(to: done.appendingPathComponent("model.safetensors"))
        try ModelManifest(repo: "mlx-community/Done-4bit", files: [HFFile(path: "model.safetensors", size: 5000)], complete: true).save(done)

        // Unfinished one.
        let half = paths.modelFolder("mlx-community/Half-4bit")
        try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: half.appendingPathComponent("model.safetensors.part"))
        try ModelManifest(repo: "mlx-community/Half-4bit", files: [HFFile(path: "model.safetensors", size: 5000)], complete: false).save(half)

        // Hugging Face cache layout: blobs plus a snapshot symlink.
        let repo = cache.appendingPathComponent("models--mlx-community--Cached-8bit")
        let blobs = repo.appendingPathComponent("blobs")
        let snapshot = repo.appendingPathComponent("snapshots/abc123")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try "abc123".write(to: repo.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
        try Data(repeating: 2, count: 8000).write(to: blobs.appendingPathComponent("sha"))
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("config.json"), withDestinationURL: blobs.appendingPathComponent("sha"))
        // Not an MLX model: skipped.
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("models--bert--base/snapshots/x"), withIntermediateDirectories: true)

        let store = LocalModelStore(paths: paths, huggingFaceCache: cache)
        let models = store.list()
        XCTAssertEqual(models.map(\.repo), ["mlx-community/Done-4bit", "mlx-community/Half-4bit", "mlx-community/Cached-8bit"])
        XCTAssertEqual(models.map(\.isComplete), [true, false, true])
        XCTAssertEqual(models[0].source, .library)
        XCTAssertEqual(models[0].modelPath, done.path)
        XCTAssertGreaterThanOrEqual(models[0].sizeBytes, 5000)
        XCTAssertEqual(models[2].source, .huggingFaceCache)
        XCTAssertEqual(models[2].modelPath, snapshot.path)
        XCTAssertLessThan(models[2].sizeBytes, 16_000, "symlinked snapshot files are not counted twice")

        try store.delete(models[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: done.path))
        try store.delete(models[2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.path))
        XCTAssertEqual(store.list().map(\.repo), ["mlx-community/Half-4bit"])
    }

    func testDeleteRefusesFoldersOutsideTheStore() {
        let store = LocalModelStore(paths: AIPaths(base: temp.appendingPathComponent("AI")), huggingFaceCache: temp.appendingPathComponent("hub"))
        let outside = LocalModel(repo: "x/y", folder: temp, modelPath: temp.path, sizeBytes: 0, isComplete: true, modified: nil, source: .library)
        XCTAssertThrowsError(try store.delete(outside))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
    }

    func testCacheFolderNames() {
        XCTAssertEqual(LocalModelStore.repo(fromCacheFolder: "models--mlx-community--SmolLM-135M"), "mlx-community/SmolLM-135M")
        XCTAssertNil(LocalModelStore.repo(fromCacheFolder: "datasets--roneneldan--TinyStories"))
        XCTAssertNil(LocalModelStore.repo(fromCacheFolder: "models--broken"))
    }

    func testRemainingBytesCountsPartsAsDone() throws {
        let folder = temp.appendingPathComponent("m")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 10).write(to: folder.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 300).write(to: folder.appendingPathComponent("model.safetensors.part"))
        let files = [HFFile(path: "config.json", size: 10), HFFile(path: "model.safetensors", size: 1000), HFFile(path: "tokenizer.json", size: 50)]
        XCTAssertEqual(ModelDownloader.remainingBytes(files, in: folder), 750)
    }

    func testPathsForRepo() {
        let paths = AIPaths(base: URL(fileURLWithPath: "/AI"))
        XCTAssertEqual(paths.modelFolder("mlx-community/X-4bit").path, "/AI/models/mlx-community/X-4bit")
        XCTAssertEqual(paths.mlxServer.path, "/AI/bin/mlx_lm.server")
        XCTAssertEqual(paths.serverLog.path, "/AI/logs/mlx-server.log")
    }
}

/// Real network and model tests. Run with DECK_LIVE_AI=1.
/// Downloads a 76 MB model into a temp folder (resumed half way), serves it with
/// mlx_lm.server when the runtime is installed, chats with it, then deletes everything.
final class AIModelsLiveTests: XCTestCase {
    private var live: Bool { ProcessInfo.processInfo.environment["DECK_LIVE_AI"] == "1" }

    func testLiveSearchAndResumableDownload() async throws {
        try XCTSkipUnless(live, "Set DECK_LIVE_AI=1")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("deck-v2-ai-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AIPaths(base: base)
        let hub = HuggingFaceClient()

        let results = try await hub.search("SmolLM-135M-Instruct-4bit")
        XCTAssertTrue(results.contains { $0.id == "mlx-community/SmolLM-135M-Instruct-4bit" })
        let repo = "mlx-community/SmolLM-135M-Instruct-4bit"
        let files = try await hub.files(repo)
        let total = files.reduce(0) { $0 + $1.size }
        XCTAssertLessThan(total, 100_000_000, "test model must stay under 100 MB")

        // Start, stop half way, then resume.
        let downloader = ModelDownloader(paths: paths)
        let seen = ProgressBox()
        let first = Task { try await downloader.download(repo: repo, files: files) { seen.set($0.completedBytes) } }
        while seen.value < 20_000_000 { try await Task.sleep(for: .milliseconds(50)) }
        first.cancel()
        _ = try? await first.value
        let folder = paths.modelFolder(repo)
        let part = folder.appendingPathComponent("model.safetensors.part")
        let partial = (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.uint64Value ?? 0
        XCTAssertGreaterThan(partial, 0, "a partial file is kept")
        XCTAssertLessThan(ModelDownloader.remainingBytes(files, in: folder), total)

        try await downloader.download(repo: repo, files: files) { _ in }
        let store = LocalModelStore(paths: paths, huggingFaceCache: base.appendingPathComponent("none"))
        let models = store.list()
        XCTAssertEqual(models.first?.repo, repo)
        XCTAssertEqual(models.first?.isComplete, true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("model.safetensors").path)[.size] as? NSNumber)?.uint64Value, 75_789_919)

        // Serve and chat when an MLX runtime is installed in the app's folder.
        let runtime = await MLXRuntime().status()
        if let server = runtime.serverPath {
            let controller = MLXServerController(paths: paths)
            try controller.start(MLXServerConfig(model: folder.path, port: 8597), serverPath: server)
            defer { Task { await controller.stop() } }
            var answered = false
            for _ in 0..<60 where !answered {
                try await Task.sleep(for: .milliseconds(500))
                answered = await ModelEndpoints.discover().contains { $0.port == 8597 && $0.isRunning && $0.kind == .mlxLM }
            }
            XCTAssertTrue(answered, "discovery finds the server")
            var stats = ChatStats()
            var text = ""
            for try await event in ChatClient().stream(baseURL: URL(string: "http://127.0.0.1:8597/v1")!, model: folder.path,
                                                       messages: [ChatMessage(role: .user, content: "Say hi")], maxTokens: 16) {
                stats.record(event)
                if case .content(let piece) = event { text += piece }
            }
            XCTAssertFalse(text.isEmpty)
            XCTAssertNotNil(stats.tokensPerSecond())
            await controller.stop()
        }
        try store.delete(models[0])
    }
}

/// Loads and unloads the smallest Ollama model, and re-pulls it (already on disk, so it only checks).
/// Runs only when Ollama is already running. Leaves it as found.
final class AIModelsOllamaLiveTests: XCTestCase {
    func testLiveOllamaLoadUnloadAndPull() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_LIVE_AI"] == "1", "Set DECK_LIVE_AI=1")
        let client = OllamaClient()
        let running = await client.isRunning()
        try XCTSkipUnless(running, "Ollama is not running")
        let models = try await client.models()
        let smallest = try XCTUnwrap(models.min { ($0.sizeBytes ?? .max) < ($1.sizeBytes ?? .max) })
        let wasLoaded = smallest.isLoaded

        try await client.load(smallest.id)
        let loaded = try await client.models().first { $0.id == smallest.id }
        XCTAssertEqual(loaded?.isLoaded, true)
        let endpoint = await ModelEndpoints.discover().first { $0.kind == .ollama && $0.isRunning }
        XCTAssertEqual(endpoint?.models.first { $0.id == smallest.id }?.isLoaded, true)

        try await client.unload(smallest.id)
        let unloaded = try await client.models().first { $0.id == smallest.id }
        XCTAssertEqual(unloaded?.isLoaded, false)

        var steps: [OllamaPullProgress] = []
        for try await progress in client.pull(smallest.id) { steps.append(progress) }
        XCTAssertEqual(steps.last?.isSuccess, true)

        if wasLoaded { try await client.load(smallest.id) }
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64 = 0
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: UInt64) { lock.lock(); stored = value; lock.unlock() }
}
