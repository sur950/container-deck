import XCTest
@testable import DeckCore

final class MLXDiagnosticsTests: XCTestCase {
    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Server output

    func testUnsupportedModelTypeFromBothErrorForms() {
        XCTAssertEqual(MLXServerOutput.unsupportedModelType("ValueError: Model type qwen3_5_mtp not supported."), "qwen3_5_mtp")
        XCTAssertEqual(MLXServerOutput.unsupportedModelType(
            "2026-11-06 21:48:55,536 - ERROR - mlx_lm.server generation thread died: Model type qwen3_5_mtp not supported."), "qwen3_5_mtp")
        XCTAssertEqual(MLXServerOutput.unsupportedModelType("ModuleNotFoundError: No module named 'mlx_lm.models.qwen3_5_mtp'"), "qwen3_5_mtp")
        XCTAssertNil(MLXServerOutput.unsupportedModelType("ModuleNotFoundError: No module named 'transformers'"))
        XCTAssertNil(MLXServerOutput.unsupportedModelType("2026-11-06 21:48:55,543 - INFO - Starting httpd at 127.0.0.1 on port 8585..."))
    }

    func testGenerationThreadDiedWhileHTTPKeepsAnswering() throws {
        let log = lines(MLXServerFixtures.generationThreadDied)
        let failure = try XCTUnwrap(MLXServerOutput.modelLoadFailure(log))
        XCTAssertEqual(failure.modelType, "qwen3_5_mtp")
        XCTAssertTrue(failure.generationThreadDied)
        XCTAssertTrue(failure.details.first?.contains("generation thread died") == true)
        XCTAssertTrue(failure.details.contains { $0.contains("No module named 'mlx_lm.models.qwen3_5_mtp'") })
        XCTAssertFalse(failure.details.contains { $0.contains("GET /v1/models") }, "access lines stay out of Details")
        XCTAssertFalse(MLXServerOutput.isBindFailure(log))
        XCTAssertNil(MLXServerOutput.modelLoadFailure(["2026-11-06 21:48:55,543 - INFO - Starting httpd at 127.0.0.1 on port 8585..."]))
    }

    func testBindFailure() {
        let log = lines(MLXServerFixtures.bindFailure)
        XCTAssertTrue(MLXServerOutput.isBindFailure(log))
        XCTAssertEqual(MLXServerOutput.modelLoadFailure(log)?.modelType, "qwen3_5_mtp")
    }

    func testMessages() throws {
        let failure = try XCTUnwrap(MLXServerOutput.modelLoadFailure(lines(MLXServerFixtures.generationThreadDied)))
        // The owner's case: 0.32.2 is the newest on PyPI, so updating cannot help.
        let newest = MLXServerOutput.message(failure, installed: "0.32.2", latest: "0.32.2")
        XCTAssertEqual(newest.text, "mlx-lm doesn't support model type qwen3_5_mtp yet. Pick another model.")
        XCTAssertFalse(newest.offerUpdate)
        let older = MLXServerOutput.message(failure, installed: "0.31.0", latest: "0.32.2")
        XCTAssertEqual(older.text, "This model needs a newer mlx-lm (model type qwen3_5_mtp).")
        XCTAssertTrue(older.offerUpdate)
        XCTAssertTrue(MLXServerOutput.message(failure, installed: "0.32.2", latest: nil).offerUpdate, "offline: offer the update")
        let unknown = MLXServerOutput.message(MLXModelLoadFailure(modelType: nil, generationThreadDied: true, details: []), installed: nil, latest: nil)
        XCTAssertEqual(unknown.text, "The model could not load. Open Details to see why.")
        for text in [newest.text, older.text, unknown.text] {
            XCTAssertFalse(text.contains(";") || text.contains("\u{2014}"), "plain copy")
        }
    }

    func testChatFailureMapping() throws {
        let log = lines(MLXServerFixtures.generationThreadDied)
        // The chat POST got a 404 while the log shows the failed load.
        let failure = try XCTUnwrap(MLXServerOutput.chatFailure(errorText: "generation thread died", serverLog: log))
        XCTAssertEqual(failure.modelType, "qwen3_5_mtp")
        XCTAssertEqual(failure.details.first, "Server answer: generation thread died", "the raw answer goes under Details")
        XCTAssertNotNil(MLXServerOutput.chatFailure(errorText: "The server answered with status 404.", serverLog: log))
        XCTAssertNil(MLXServerOutput.chatFailure(errorText: "The server answered with status 404.",
                                                 serverLog: ["2026-11-06 21:48:55,543 - INFO - Starting httpd at 127.0.0.1 on port 8585..."]),
                     "a healthy log keeps the server's own error")
    }

    // MARK: Versions

    func testPackageVersionCompare() {
        XCTAssertEqual(PackageVersion.compare("0.32.2", "0.32.2"), .orderedSame)
        XCTAssertEqual(PackageVersion.compare("0.32.2", "0.32.10"), .orderedAscending)
        XCTAssertEqual(PackageVersion.compare("0.33.0", "0.32.9"), .orderedDescending)
        XCTAssertEqual(PackageVersion.compare("0.33", "0.33.0"), .orderedSame)
        XCTAssertEqual(PackageVersion.compare("0.33.0rc1", "0.33.0"), .orderedAscending)
        XCTAssertEqual(PackageVersion.compare("v1.2.0", "1.1.9"), .orderedDescending)
    }

    func testPyPILatestVersionParseAndCache() async {
        XCTAssertEqual(PyPILatestVersion.parseLatest(Data(#"{"info":{"name":"mlx-lm","version":"0.32.2"},"releases":{}}"#.utf8)), "0.32.2")
        XCTAssertNil(PyPILatestVersion.parseLatest(Data("<html>".utf8)))
        let http = CountingHTTP(body: #"{"info":{"version":"0.32.2"}}"#)
        let pypi = PyPILatestVersion(http: http)
        let first = await pypi.latest("mlx-lm")
        let second = await pypi.latest("mlx-lm")
        XCTAssertEqual(first, "0.32.2")
        XCTAssertEqual(second, "0.32.2")
        XCTAssertEqual(http.count, 1, "cached")
        XCTAssertEqual(http.urls.first, "https://pypi.org/pypi/mlx-lm/json")
    }

    // MARK: Bind address

    func testBindAddressCheck() {
        let assigned = NetworkInterfaces.assignedAddresses()
        XCTAssertTrue(assigned.contains("127.0.0.1"), "loopback is always on lo0")
        XCTAssertTrue(NetworkInterfaces.isAssigned("127.0.0.1"))
        XCTAssertFalse(NetworkInterfaces.isAssigned("203.0.113.77"), "a documentation address is on no interface")

        let up: Set<String> = ["127.0.0.1", "192.168.64.1"]
        XCTAssertEqual(MLXBind.containers(gateway: "192.168.64.1").resolved(assigned: up).bind, .containers(gateway: "192.168.64.1"))
        XCTAssertFalse(MLXBind.containers(gateway: "192.168.64.1").resolved(assigned: up).fellBack)
        let down = MLXBind.containers(gateway: "192.168.64.1").resolved(assigned: ["127.0.0.1"])
        XCTAssertEqual(down.bind, .mac, "never pass an address that is not assigned")
        XCTAssertTrue(down.fellBack)
        XCTAssertEqual(MLXBind.mac.resolved(assigned: []).bind, .mac)
    }

    // MARK: Model support

    func testModelSupportFromInstalledPackage() throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("mlx_lm-\(UUID().uuidString)")
        let models = package.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        for name in ["__init__.py", "base.py", "llama.py", "qwen3_5.py", "qwen3_5_moe.py", "bailing_moe_v3.py", "lfm2-vl.py"] {
            FileManager.default.createFile(atPath: models.appendingPathComponent(name).path, contents: Data())
        }
        // The tables as they are in mlx-lm 0.32.2's utils.py.
        let utils = """
        MODEL_REMAPPING = {
            "mistral": "llama",
            "llava": "mistral3",
            "gemma4_unified": "gemma4",  # encoder-free multimodal variant
        }

        MODEL_ARCHITECTURE_REMAPPING = {
            ("bailing_hybrid", "BailingMoeV3ForCausalLM"): "bailing_moe_v3",
        }
        """
        try utils.write(to: package.appendingPathComponent("utils.py"), atomically: true, encoding: .utf8)

        let support = try XCTUnwrap(MLXModelSupport.load(package: package, version: "0.32.2"))
        XCTAssertFalse(support.moduleTypes.contains("__init__"))
        XCTAssertTrue(support.supports(MLXModelConfig(modelType: "qwen3_5")))
        XCTAssertFalse(support.supports(MLXModelConfig(modelType: "qwen3_5_mtp")), "the owner's model")
        XCTAssertTrue(support.supports(MLXModelConfig(modelType: "mistral")), "remapped to llama")
        XCTAssertTrue(support.supports(MLXModelConfig(modelType: "bailing_hybrid", architectures: ["BailingMoeV3ForCausalLM"])))
        XCTAssertFalse(support.supports(MLXModelConfig(modelType: "bailing_hybrid", architectures: ["Other"])))
        XCTAssertTrue(support.supports(MLXModelConfig(modelType: "lfm2-vl")))
        XCTAssertEqual(support.remapping["gemma4_unified"], "gemma4")
    }

    func testModelConfigParse() throws {
        let config = try XCTUnwrap(MLXModelConfig.parse(Data(#"{"architectures":["Qwen3_5MTPForCausalLM"],"model_type":"qwen3_5_mtp","text_config":{"model_type":"qwen3_5_text"}}"#.utf8)))
        XCTAssertEqual(config.modelType, "qwen3_5_mtp", "the top level type is the one mlx-lm uses")
        XCTAssertEqual(config.architectures, ["Qwen3_5MTPForCausalLM"])
        XCTAssertNil(MLXModelConfig.parse(Data("{}".utf8)))
        XCTAssertEqual(HuggingFaceClient.resolveURL("mlx-community/Qwen3.8-27B-MTP-4bit", path: "config.json")?.absoluteString,
                       "https://huggingface.co/mlx-community/Qwen3.8-27B-MTP-4bit/resolve/main/config.json")
    }

    func testFindsPackageInOwnInstall() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ai-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AIPaths(base: base)
        XCTAssertNil(MLXModelSupport.findPackage(paths: paths))
        let models = paths.tools.appendingPathComponent("mlx-lm/lib/python3.12/site-packages/mlx_lm/models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        XCTAssertEqual(MLXModelSupport.findPackage(paths: paths)?.lastPathComponent, "mlx_lm")
    }

    // MARK: Display names

    func testShortDisplayNames() {
        XCTAssertEqual(ModelDisplayName.short("/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/models/mlx-community/Qwen3.8-27B-MTP-4bit"),
                       "Qwen3.8-27B-MTP-4bit")
        XCTAssertEqual(ModelDisplayName.short("mlx-community/Qwen3.8-27B-MTP-4bit"), "Qwen3.8-27B-MTP-4bit")
        XCTAssertEqual(ModelDisplayName.short("qwen3:0.6b"), "qwen3:0.6b")
        XCTAssertEqual(ModelDisplayName.short("/path/with/trailing/"), "trailing")
        XCTAssertEqual(ModelEndpointModel(id: "/a/mlx-community/SmolLM-135M").displayName, "SmolLM-135M")
    }

    // MARK: Shared probe

    func testSharedProbeDeduplicatesAndCaches() async {
        let counter = ProbeCounter()
        let center = EndpointProbeCenter {
            await counter.hit()
            try? await Task.sleep(for: .milliseconds(150))
            return [ModelEndpoint(id: "127.0.0.1:8585", kind: .mlxLM, host: "127.0.0.1", port: 8585, baseURL: URL(string: "http://127.0.0.1:8585/v1")!, status: .running)]
        }
        // Three views asking in the same second share one probe.
        async let a = center.endpoints(maxAge: 7)
        async let b = center.endpoints(maxAge: 7)
        async let c = center.endpoints(maxAge: 7)
        let results = await [a, b, c]
        XCTAssertEqual(results.map(\.count), [1, 1, 1])
        var probes = await center.probeCount
        XCTAssertEqual(probes, 1)
        // A poll inside the interval reads the cache.
        _ = await center.endpoints(maxAge: 7)
        probes = await center.probeCount
        XCTAssertEqual(probes, 1)
        // After a start or stop the app asks for a fresh probe.
        _ = await center.endpoints(maxAge: 0)
        probes = await center.probeCount
        XCTAssertEqual(probes, 2)
        let hits = await counter.count
        XCTAssertEqual(hits, 2)
    }
}

private actor ProbeCounter {
    var count = 0
    func hit() { count += 1 }
}

private final class CountingHTTP: AIHTTPFetching, @unchecked Sendable {
    let body: String
    var count = 0
    var urls: [String] = []
    init(body: String) { self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        count += 1
        urls.append(request.url?.absoluteString ?? "")
        return (Data(body.utf8), 200)
    }
}
