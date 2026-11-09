import XCTest
@testable import DeckCore

/// Answers by URL. Unknown URLs fail like an unreachable host.
private final class RoutedHTTP: AIHTTPFetching, @unchecked Sendable {
    var routes: [String: (Data, Int)] = [:]
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock(); seen.append(request); lock.unlock()
        let url = request.url?.absoluteString ?? ""
        let accept = request.value(forHTTPHeaderField: "Accept") ?? ""
        if let answer = routes[url + " " + accept] ?? routes[url] { return answer }
        throw URLError(.cannotConnectToHost)
    }
}

private final class RecordingStreamer: CommandStreaming, @unchecked Sendable {
    var calls: [[String]] = []
    var lines: [String] = []
    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        calls.append([executable] + arguments)
        let lines = self.lines
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

final class ModelLibraryParsingTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("deck-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: Shared

    func testParameterWords() {
        XCTAssertEqual(LibraryModel.parameterCount("0.6b"), 600_000_000)
        XCTAssertEqual(LibraryModel.parameterCount("270m"), 270_000_000)
        XCTAssertEqual(LibraryModel.parameterCount("e4b"), 4_000_000_000)
        XCTAssertEqual(LibraryModel.parameterCount("8x7b"), 56_000_000_000)
        XCTAssertEqual(LibraryModel.parameterCount("35b-a3b"), 35_000_000_000)
        XCTAssertNil(LibraryModel.parameterCount("tools"))
        XCTAssertNil(LibraryModel.parameterCount("latest"))
        XCTAssertEqual(LibraryModel.parameterCount(inName: "qwen3-4b-thinking-2507"), 4_000_000_000)
        XCTAssertEqual(LibraryModel.parameterCount(inName: "gemma-4-e4b"), 4_000_000_000)
        XCTAssertEqual(LibraryModel.parameterCount(inName: "gpt-oss-20b"), 20_000_000_000)
        XCTAssertNil(LibraryModel.parameterCount(inName: "glm-4.7-flash"))
        XCTAssertEqual(LibraryModel.rangeLabel(["0.6b", "8b", "235b"]), "0.6B to 235B")
        XCTAssertEqual(LibraryModel.rangeLabel(["7b"]), "7B")
        XCTAssertNil(LibraryModel.rangeLabel([]))
    }

    func testIDsStayUniqueAcrossSources() {
        let mlx = LibraryModel(huggingFace: HFModel(id: "mlx-community/Qwen3-4B-4bit", downloads: 5, parameters: 4_000_000_000))
        XCTAssertEqual(mlx.id, "mlx-community/Qwen3-4B-4bit", "MLX keeps the plain repo id")
        XCTAssertEqual(mlx.quantization, "4bit")
        XCTAssertEqual(mlx.parameterText, "4.0B")
        XCTAssertEqual(LibraryModel(source: .ollama, key: "qwen3", name: "qwen3").id, "ollama:qwen3")
        XCTAssertEqual(LibraryModel(source: .lmStudio, key: "qwen/qwen3-4b", name: "qwen3-4b").id, "lmStudio:qwen/qwen3-4b")
    }

    func testCacheRoundTrip() {
        let cache = LibraryCache(directory: temp)
        cache.write("ollama-search-qwen 3/../x", ["a", "b"])
        let saved = cache.read("ollama-search-qwen 3/../x", as: [String].self)
        XCTAssertEqual(saved?.value, ["a", "b"])
        XCTAssertLessThan(saved?.age ?? 99, 5)
        XCTAssertFalse(LibraryCache.fileName("../../etc/passwd").contains("/"))
        XCTAssertNil(cache.read("missing", as: [String].self))
    }

    // MARK: Ollama

    func testParseOllamaSearch() throws {
        let models = OllamaLibraryParser.parseSearch(LibraryFixtures.ollamaSearch)
        XCTAssertEqual(models.map(\.name), ["qwen3.8", "qwen3", "qwen3-embedding"])
        let qwen3 = try XCTUnwrap(models.first { $0.name == "qwen3" })
        XCTAssertEqual(qwen3.downloads, 42_889_046)
        XCTAssertEqual(qwen3.sizes, ["0.6b", "1.7b", "4b", "8b", "14b", "30b", "32b", "235b"])
        XCTAssertEqual(qwen3.capabilities, ["tools", "thinking"])
        XCTAssertNotNil(qwen3.updated)
        XCTAssertTrue(qwen3.summary?.hasPrefix("Qwen3 is the latest generation") ?? false)
        XCTAssertEqual(models[0].capabilities, ["vision", "tools", "thinking"])
        XCTAssertEqual(models[0].tagCount, 13)
        XCTAssertEqual(models[2].capabilities, ["embedding"])

        let row = qwen3.libraryModel
        XCTAssertEqual(row.source, .ollama)
        XCTAssertEqual(row.key, "qwen3")
        XCTAssertEqual(row.parameterText, "0.6B to 235B")
        XCTAssertEqual(row.parameters, 600_000_000, "sorts by the smallest size")
        XCTAssertEqual(OllamaLibraryParser.resultCount(LibraryFixtures.ollamaSearch), 20)
    }

    func testParseOllamaLibraryPage() throws {
        let models = OllamaLibraryParser.parseSearch(LibraryFixtures.ollamaLibraryPage)
        let qwen3 = try XCTUnwrap(models.first)
        XCTAssertEqual(qwen3.name, "qwen3")
        XCTAssertEqual(qwen3.downloads, 42_900_000)
        XCTAssertEqual(qwen3.tagCount, 58)
        XCTAssertEqual(qwen3.sizes.first, "0.6b")
        XCTAssertEqual(qwen3.capabilities, ["tools", "thinking"])
        XCTAssertNotNil(qwen3.updated)
        XCTAssertEqual(OllamaLibraryClient.searchURL("").absoluteString, "https://ollama.com/library")
        XCTAssertEqual(OllamaLibraryClient.searchURL("qwen").absoluteString, "https://ollama.com/search?q=qwen")
        XCTAssertTrue(OllamaLibraryModel(name: "glm-5.3", capabilities: ["tools", "cloud"]).isCloudOnly)
        XCTAssertFalse(OllamaLibraryModel(name: "gpt-oss", sizes: ["20b"], capabilities: ["cloud"]).isCloudOnly)
    }

    func testOllamaSearchSurvivesChangedPages() {
        XCTAssertEqual(OllamaLibraryParser.parseSearch("<html><body>New design</body></html>").count, 0)
        XCTAssertEqual(OllamaLibraryParser.parseSearch(#"<a href="/library/../../etc">x</a><a href="/library/llama3.2">"#).map(\.name), ["llama3.2"])
        XCTAssertEqual(OllamaLibraryParser.parseTagsPage("garbage", model: "qwen3").count, 0)
        XCTAssertEqual(OllamaLibraryParser.parseTagList(Data("[]".utf8)), [])
        XCTAssertNil(OllamaLibraryParser.manifestSize(Data("{}".utf8)))
    }

    func testParseOllamaTagsPage() throws {
        let tags = OllamaLibraryParser.parseTagsPage(LibraryFixtures.ollamaTagsPage, model: "qwen3")
        XCTAssertEqual(tags.map(\.tag), ["latest", "0.6b", "8b-q8_0"])
        XCTAssertEqual(tags[0].sizeBytes, 5_200_000_000)
        XCTAssertEqual(tags[0].digest, "500a1f067a9f")
        XCTAssertEqual(tags[0].context, "40K")
        XCTAssertEqual(tags[1].sizeBytes, 523_000_000)
        XCTAssertNil(tags[1].quantization)
        XCTAssertEqual(tags[2].quantization, "Q8_0")
    }

    func testParseTagListAndManifest() {
        XCTAssertEqual(OllamaLibraryParser.parseTagList(Data(LibraryFixtures.ollamaTagList.utf8)).prefix(3), ["latest", "0.6b", "1.7b"])
        XCTAssertEqual(OllamaLibraryParser.manifestSize(Data(LibraryFixtures.ollamaManifest.utf8)), 487 + 5_225_374_496 + 1723 + 11338 + 120)
    }

    func testPullNames() {
        XCTAssertTrue(OllamaLibraryParser.isPullName("qwen3"))
        XCTAssertTrue(OllamaLibraryParser.isPullName("qwen3:0.6b"))
        XCTAssertTrue(OllamaLibraryParser.isPullName("hf.co-user/model:Q4_K_M"))
        XCTAssertFalse(OllamaLibraryParser.isPullName("../x"))
        XCTAssertFalse(OllamaLibraryParser.isPullName("a:b:c"))
        XCTAssertFalse(OllamaLibraryParser.isPullName("rm -rf"))
    }

    func testOllamaSearchUsesSiteThenCacheThenBuiltIn() async {
        let http = RoutedHTTP()
        http.routes["https://ollama.com/search?q=qwen"] = (Data(LibraryFixtures.ollamaSearch.utf8), 200)
        let cache = LibraryCache(directory: temp)
        let client = OllamaLibraryClient(http: http, cache: cache)
        let live = await client.search("Qwen ")
        XCTAssertEqual(live.origin, .live)
        XCTAssertEqual(live.models.count, 3)

        // Site down: the saved answer is used (older than the cache lifetime counts as cached).
        let offline = OllamaLibraryClient(http: RoutedHTTP(), cache: cache)
        let again = await offline.search("qwen")
        XCTAssertEqual(again.models.count, 3)

        // Nothing saved and no site: built in popular models that match.
        let empty = OllamaLibraryClient(http: RoutedHTTP(), cache: LibraryCache(directory: temp.appendingPathComponent("other")))
        let builtIn = await empty.search("llama")
        XCTAssertEqual(builtIn.origin, .builtIn)
        XCTAssertTrue(builtIn.models.contains { $0.name == "llama3.2" })
        XCTAssertTrue(builtIn.models.allSatisfy { $0.name.contains("llama") || ($0.summary ?? "").lowercased().contains("llama") })
    }

    func testOllamaTagsFallBackToJSONAndRegistry() async throws {
        let http = RoutedHTTP()
        http.routes["https://ollama.com/library/qwen3/tags application/json"] = (Data(LibraryFixtures.ollamaTagList.utf8), 200)
        http.routes["https://ollama.com/library/qwen3/tags"] = (Data("<html>changed</html>".utf8), 200)
        http.routes["https://registry.ollama.ai/v2/library/qwen3/manifests/latest"] = (Data(LibraryFixtures.ollamaManifest.utf8), 200)
        let client = OllamaLibraryClient(http: http, cache: nil)
        let tags = try await client.tags("qwen3")
        XCTAssertEqual(tags.count, 9)
        XCTAssertEqual(tags.first { $0.tag == "latest" }?.sizeBytes, 5_225_388_164)
        XCTAssertNil(tags.first { $0.tag == "0.6b-q8_0" }?.sizeBytes, "quantized tags are not looked up one by one")
        do {
            _ = try await client.tags("../etc")
            XCTFail("bad names are refused")
        } catch {}
    }

    // MARK: LM Studio

    func testParseLMStudioCatalog() throws {
        let models = LMStudioCatalogParser.parseArtifacts(Data(LibraryFixtures.lmStudioCatalog.utf8))
        XCTAssertEqual(models.map(\.identifier), ["qwen/qwen3-4b", "openai/gpt-oss-20b", "buns/qwen38-27b"])
        let qwen = models[0]
        XCTAssertTrue(qwen.isStaffPick)
        XCTAssertEqual(qwen.downloads, 85_816)
        XCTAssertEqual(qwen.summary, "The 4B parameter version of the Qwen3 model family.")
        XCTAssertNotNil(qwen.updated)
        XCTAssertFalse(models[2].isStaffPick)
        let row = qwen.libraryModel
        XCTAssertEqual(row.source, .lmStudio)
        XCTAssertEqual(row.key, "qwen/qwen3-4b")
        XCTAssertEqual(row.parameterText, "4.0B")
        XCTAssertTrue(row.isStaffPick)
        XCTAssertEqual(LMStudioCatalogParser.parseArtifacts(Data(#"{"publicArtifacts":[{"identifier":"a/b","type":"preset"}]}"#.utf8)).count, 0)
        XCTAssertEqual(LMStudioCatalogParser.parseArtifacts(Data("oops".utf8)).count, 0)
    }

    func testLMStudioFilterPutsStaffPicksFirst() {
        let models = [
            LMStudioCatalogModel(identifier: "user/qwen-fork", downloads: 10),
            LMStudioCatalogModel(identifier: "user/qwen-popular", downloads: 900_000),
            LMStudioCatalogModel(identifier: "qwen/qwen3-4b", summary: "Small Qwen", downloads: 5_000, isStaffPick: true),
            LMStudioCatalogModel(identifier: "google/gemma-4-e4b", downloads: 9_000, isStaffPick: true)
        ]
        XCTAssertEqual(LMStudioCatalogParser.filter(models, query: "").map(\.identifier), ["google/gemma-4-e4b", "qwen/qwen3-4b", "user/qwen-popular"])
        XCTAssertEqual(LMStudioCatalogParser.filter(models, query: "qwen").map(\.identifier), ["qwen/qwen3-4b", "user/qwen-popular"], "forks with few downloads stay out")
        XCTAssertEqual(LMStudioCatalogParser.filter(models, query: "small qwen").map(\.identifier), ["qwen/qwen3-4b"])
    }

    func testParseLMStudioModelPage() throws {
        let detail = try XCTUnwrap(LMStudioCatalogParser.parseModelPage(LibraryFixtures.lmStudioModelPage))
        XCTAssertEqual(detail.parameters, ["4B"])
        XCTAssertEqual(detail.minMemoryBytes, 2_200_000_000)
        XCTAssertEqual(detail.compatibility, ["gguf", "safetensors"])
        XCTAssertEqual(detail.contextLength, 40960)
        XCTAssertTrue(detail.reasoning)
        XCTAssertTrue(detail.tools)
        XCTAssertFalse(detail.vision)
        XCTAssertEqual(detail.variants.map(\.repo), ["lmstudio-community/Qwen3-4B-GGUF", "lmstudio-community/Qwen3-4B-MLX-4bit", "lmstudio-community/Qwen3-4B-MLX-8bit"])
        XCTAssertEqual(detail.variants.map(\.format), ["GGUF", "MLX", "MLX"])
        XCTAssertEqual(detail.variants[1].quantization, "4bit")
        XCTAssertEqual(detail.formatText, "GGUF, MLX")
        XCTAssertNil(LMStudioCatalogParser.parseModelPage("<html>no yaml</html>"))
    }

    func testLMStudioModelPagesInOtherShapes() throws {
        let gemma = try XCTUnwrap(LMStudioCatalogParser.parseModelPage(LibraryFixtures.lmStudioModelPageDoubled), "escaped twice, after a colored copy")
        XCTAssertEqual(gemma.variants.compactMap(\.repo), ["lmstudio-community/gemma-3-1B-it-QAT-GGUF", "mlx-community/gemma-3-1b-it-qat-4bit"])
        XCTAssertEqual(gemma.parameters, ["1B"])
        let qwen = try XCTUnwrap(LMStudioCatalogParser.parseModelPage(LibraryFixtures.lmStudioModelPageTemplate), "a chat template does not break it")
        XCTAssertEqual(qwen.variants.count, 5)
        XCTAssertEqual(qwen.minMemoryBytes, 16_100_000_000)
        // Older pages (openai/gpt-oss-20b) only link their repos.
        let old = try XCTUnwrap(LMStudioCatalogParser.parseModelPage(#"<a href="https://huggingface.co/lmstudio-community/gpt-oss-20b-GGUF">x</a> https://huggingface.co/mlx-community/gpt-oss-20b-MXFP4-Q8 https://huggingface.co/lmstudio-community/gpt-oss-20b-GGUF"#))
        XCTAssertEqual(old.variants.compactMap(\.repo), ["lmstudio-community/gpt-oss-20b-GGUF", "mlx-community/gpt-oss-20b-MXFP4-Q8"])
        XCTAssertEqual(old.formatText, "GGUF, MLX")
    }

    func testLMStudioCatalogClientFallsBackToSavedCatalog() async throws {
        let http = RoutedHTTP()
        http.routes["https://lmstudio.ai/api/v1/artifacts?type=model application/json"] = (Data(LibraryFixtures.lmStudioCatalog.utf8), 200)
        let cache = LibraryCache(directory: temp)
        let live = try await LMStudioCatalogClient(http: http, cache: cache).search("gpt")
        XCTAssertEqual(live.models.map(\.identifier), ["openai/gpt-oss-20b"])
        let offline = try await LMStudioCatalogClient(http: RoutedHTTP(), cache: cache).search("")
        XCTAssertEqual(offline.models.count, 2, "staff picks only, the fork has few downloads")
        do {
            _ = try await LMStudioCatalogClient(http: RoutedHTTP(), cache: nil).search("")
            XCTFail("no site and no cache is an error")
        } catch {}
    }

    func testLMSGetProgress() {
        let lines = LibraryFixtures.lmsGetOutput.compactMap(LMStudioDownloadProgress.parse)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].message, "Resolving qwen/qwen3-4b...")
        XCTAssertEqual(lines[1].fraction ?? 0, 0.245, accuracy: 0.0001)
        XCTAssertEqual(lines[1].completedBytes, 612_300_000)
        XCTAssertEqual(lines[1].totalBytes, 2_500_000_000)
        XCTAssertNil(lines[1].message)
        XCTAssertEqual(lines[3].message, "Download completed.")
        XCTAssertNil(LMStudioDownloadProgress.parse("   "))
        XCTAssertNil(LMStudioDownloadProgress.parse("⠋ ["))
    }

    func testLMSGetRunsTheStandInTool() async throws {
        let tools = temp.appendingPathComponent("tools").path
        let streamer = RecordingStreamer()
        streamer.lines = LibraryFixtures.lmsGetOutput
        let runtime = LMStudioRuntime(runner: MockRunner(), streamer: streamer, toolsDirectory: tools, fileExists: { $0 == tools + "/lms" })
        var seen: [String] = []
        for try await line in try runtime.download("qwen/qwen3-4b") { seen.append(line) }
        XCTAssertEqual(streamer.calls, [[tools + "/lms", "get", "qwen/qwen3-4b", "--yes"]])
        XCTAssertEqual(seen.count, 4)
        XCTAssertThrowsError(try runtime.download("rm -rf /"))
        let missing = LMStudioRuntime(runner: MockRunner(), streamer: streamer, toolsDirectory: tools, fileExists: { _ in false })
        XCTAssertThrowsError(try missing.download("qwen/qwen3-4b"))
        XCTAssertEqual(runtime.modelsDirectory().path, tools + "/models")
        XCTAssertEqual(LMStudioRuntime.parseDownloadsFolder(Data(#"{"downloadsFolder":"/Volumes/AI/lms"}"#.utf8)), "/Volumes/AI/lms")
        XCTAssertNil(LMStudioRuntime.parseDownloadsFolder(Data("{}".utf8)))
    }

    func testLMSListKeepsPathAndQuantization() {
        let models = LMStudioRuntime.parseModels(LibraryFixtures.lmsList)
        XCTAssertEqual(models.first?.path, "nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf")
        XCTAssertEqual(models.first?.quantization, "Q4_K_M")
    }
}

/// Counts lookups running at once.
private actor LookupMeter {
    var now = 0
    var peak = 0
    var started: [String] = []
    func begin(_ key: String) { now += 1; peak = max(peak, now); started.append(key) }
    func end() { now -= 1 }
}

private actor Answers {
    var keys: [String: LibrarySize?] = [:]
    func add(_ key: String, _ size: LibrarySize?) { keys[key] = size }
}

final class LibrarySizeQueueTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("deck-size-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func queue(delay: Duration, meter: LookupMeter, answers: Answers, cache: LibraryCache? = nil) -> LibrarySizeQueue {
        LibrarySizeQueue(maxConcurrent: 4, cache: cache, lookup: { key in
            await meter.begin(key)
            try? await Task.sleep(for: delay)
            await meter.end()
            if Task.isCancelled { return nil }
            return key.hasSuffix("missing") ? nil : LibrarySize(bytes: UInt64(key.count), label: "latest")
        }, report: { key, size in await answers.add(key, size) })
    }

    func testAtMostFourAtOnce() async {
        let meter = LookupMeter(), answers = Answers()
        let queue = queue(delay: .milliseconds(30), meter: meter, answers: answers, cache: LibraryCache(directory: temp))
        for index in 0..<12 { await queue.request("ollama:model\(index)") }
        await queue.request("ollama:model0")
        let waiting = await queue.waiting
        XCTAssertEqual(waiting, 8, "four run, the rest wait, a repeat is not queued twice")
        await queue.waitUntilIdle()
        let peak = await meter.peak
        let started = await queue.lookupsStarted
        let count = await answers.keys.count
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertEqual(started, 12)
        XCTAssertEqual(count, 12)
        let order = await meter.started
        XCTAssertEqual(Array(order.prefix(4)).sorted(), (0..<4).map { "ollama:model\($0)" }.sorted(), "first come, first served")
    }

    func testCancelStopsTheQueue() async throws {
        let meter = LookupMeter(), answers = Answers()
        let queue = queue(delay: .milliseconds(200), meter: meter, answers: answers)
        for index in 0..<10 { await queue.request("lmStudio:a/m\(index)") }
        try await Task.sleep(for: .milliseconds(30))
        await queue.cancelAll()
        await queue.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(300))
        let started = await queue.lookupsStarted
        let count = await answers.keys.count
        XCTAssertEqual(started, 4, "nothing new starts after a cancel")
        XCTAssertEqual(count, 0, "answers from cancelled lookups are dropped")
    }

    func testWithdrawnRowsAreNotLookedUp() async {
        let meter = LookupMeter(), answers = Answers()
        let queue = queue(delay: .milliseconds(40), meter: meter, answers: answers)
        for index in 0..<8 { await queue.request("ollama:m\(index)") }
        for index in 4..<8 { await queue.withdraw("ollama:m\(index)") }
        await queue.waitUntilIdle()
        let started = await queue.lookupsStarted
        XCTAssertEqual(started, 4, "rows that scrolled away before their turn cost nothing")
    }

    func testCacheHitNeedsNoLookup() async {
        let cache = LibraryCache(directory: temp)
        cache.write("size-ollama:qwen3", LibrarySize(bytes: 5_225_388_164, label: "latest"))
        let meter = LookupMeter(), answers = Answers()
        let queue = queue(delay: .milliseconds(10), meter: meter, answers: answers, cache: cache)
        await queue.request("ollama:qwen3")
        await queue.request("ollama:gone-missing")
        await queue.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(30))
        let hits = await queue.cacheHits
        let started = await queue.lookupsStarted
        let keys = await answers.keys
        XCTAssertEqual(hits, 1)
        XCTAssertEqual(started, 1, "only the uncached row is looked up")
        XCTAssertEqual(keys["ollama:qwen3"]??.bytes, 5_225_388_164)
        XCTAssertEqual(keys["ollama:gone-missing"].map { $0 == nil }, true, "a size that can't be found is reported as nil")
        XCTAssertNil(cache.read("size-ollama:gone-missing", as: LibrarySize.self), "misses are not saved")
        // A found size is saved for next time.
        let fresh = LibrarySizeQueue(maxConcurrent: 4, cache: cache, lookup: { _ in LibrarySize(bytes: 9) })
        await fresh.request("lmStudio:qwen/qwen3-4b")
        await fresh.waitUntilIdle()
        XCTAssertEqual(cache.read("size-lmStudio:qwen/qwen3-4b", as: LibrarySize.self)?.value.bytes, 9)
    }

    func testOptionSizes() {
        let gguf = LMStudioVariant(key: "lmstudio-community/qwen3-4b-gguf", repo: "lmstudio-community/Qwen3-4B-GGUF")
        let size = LMStudioCatalogParser.optionSize(gguf, files: [
            HFFile(path: "Qwen3-4B-Q8_0.gguf", size: 4_280_000_000),
            HFFile(path: "Qwen3-4B-Q4_K_M.gguf", size: 2_500_000_000),
            HFFile(path: "mmproj-F16.gguf", size: 100),
            HFFile(path: "README.md", size: 10)
        ])
        XCTAssertEqual(size, LibrarySize(bytes: 2_500_000_000, label: "GGUF Q4_K_M"))
        let mlx = LMStudioVariant(key: "lmstudio-community/qwen3-4b-mlx-4bit", repo: "lmstudio-community/Qwen3-4B-MLX-4bit")
        XCTAssertEqual(LMStudioCatalogParser.optionSize(mlx, files: [HFFile(path: "model.safetensors", size: 2_000), HFFile(path: "config.json", size: 5), HFFile(path: "README.md", size: 9)]),
                       LibrarySize(bytes: 2_005, label: "MLX 4bit"))
        XCTAssertNil(LMStudioCatalogParser.optionSize(mlx, files: []))
    }

    func testCountingFetcher() async throws {
        final class OK: AIHTTPFetching, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> (Data, Int) { (Data(), 200) }
        }
        let http = CountingHTTPFetcher(base: OK())
        _ = try await http.get(URL(string: "https://example.com")!, timeout: 1)
        _ = try await http.get(URL(string: "https://example.com")!, timeout: 1)
        XCTAssertEqual(http.count, 2)
    }
}
