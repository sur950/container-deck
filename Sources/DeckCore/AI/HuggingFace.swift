import Foundation

/// One model repository on Hugging Face.
public struct HFModel: Sendable, Hashable, Identifiable, Codable {
    /// "mlx-community/SmolLM-135M-Instruct-4bit".
    public var id: String
    public var downloads: Int
    public var likes: Int
    public var lastModified: Date?
    public var pipelineTag: String?
    public var tags: [String]
    /// Parameter count from the safetensors metadata.
    public var parameters: UInt64?

    public init(id: String, downloads: Int = 0, likes: Int = 0, lastModified: Date? = nil, pipelineTag: String? = nil, tags: [String] = [], parameters: UInt64? = nil) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
        self.lastModified = lastModified
        self.pipelineTag = pipelineTag
        self.tags = tags
        self.parameters = parameters
    }

    /// The part after the slash.
    public var name: String { id.split(separator: "/").last.map(String.init) ?? id }
    public var author: String { id.split(separator: "/").first.map(String.init) ?? "" }

    /// "4bit", "8bit", "bf16", from the name or tags.
    public var quantization: String? {
        let lower = name.lowercased()
        for marker in ["3bit", "4bit", "5bit", "6bit", "8bit", "bf16", "fp16", "mxfp4", "dwq"] where lower.contains(marker) {
            return marker
        }
        return tags.first { $0.hasSuffix("-bit") }.map { $0.replacingOccurrences(of: "-bit", with: "bit") }
    }

    /// "135M", "3.1B".
    public var parameterText: String? {
        guard let parameters, parameters > 0 else { return nil }
        let value = Double(parameters)
        if value >= 1e9 { return String(format: value >= 1e10 ? "%.0fB" : "%.1fB", value / 1e9) }
        return String(format: "%.0fM", value / 1e6)
    }
}

/// One file of a repository.
public struct HFFile: Sendable, Hashable, Codable {
    public var path: String
    public var size: UInt64

    public init(path: String, size: UInt64) {
        self.path = path
        self.size = size
    }
}

/// Public Hugging Face API. No account needed for public models.
public struct HuggingFaceClient: Sendable {
    let http: AIHTTPFetching

    public init(http: AIHTTPFetching = AIHTTPClient()) {
        self.http = http
    }

    /// Searches `mlx-community`, most downloaded first. An empty query lists the most popular.
    public func search(_ query: String, author: String = AIConfig.libraryAuthor, limit: Int = AIConfig.searchPageSize) async throws -> [HFModel] {
        let (data, status) = try await http.get(Self.searchURL(query, author: author, limit: limit), timeout: 20)
        guard status == 200 else { throw DeckError.network(AIHTTP.errorMessage(data, status: status)) }
        guard let models = Self.parseSearch(data) else { throw DeckError.parse("the Hugging Face search") }
        return models
    }

    /// Files to download for a model, with sizes. Leaves out read me files, images and other formats.
    public func files(_ repo: String) async throws -> [HFFile] {
        guard let url = Self.treeURL(repo) else { throw DeckError.network("\(repo) is not a model name.") }
        let (data, status) = try await http.get(url, timeout: 20)
        guard status == 200 else { throw DeckError.network(AIHTTP.errorMessage(data, status: status)) }
        guard let files = Self.parseTree(data) else { throw DeckError.parse("the model's file list") }
        return files.filter { Self.isNeeded($0.path) }
    }

    /// Every file of a repository with its size, unfiltered.
    public func allFiles(_ repo: String) async throws -> [HFFile] {
        guard let url = Self.treeURL(repo) else { throw DeckError.network("\(repo) is not a model name.") }
        let (data, status) = try await http.get(url, timeout: 20)
        guard status == 200 else { throw DeckError.network(AIHTTP.errorMessage(data, status: status)) }
        guard let files = Self.parseTree(data) else { throw DeckError.parse("the model's file list") }
        return files
    }

    /// The model's config.json (`model_type`), to check mlx-lm can load it before download.
    public func config(_ repo: String) async throws -> MLXModelConfig {
        guard let url = Self.resolveURL(repo, path: "config.json") else { throw DeckError.network("\(repo) is not a model name.") }
        let (data, status) = try await http.get(url, timeout: 20)
        guard status == 200 else { throw DeckError.network(AIHTTP.errorMessage(data, status: status)) }
        guard let config = MLXModelConfig.parse(data) else { throw DeckError.parse("the model's config.json") }
        return config
    }

    // MARK: URLs

    static func searchURL(_ query: String, author: String, limit: Int) -> URL {
        var components = URLComponents(url: AIConfig.huggingFaceAPI.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "author", value: author),
            // Chat and text models only: what mlx_lm.server can run. Not speech or image models.
            URLQueryItem(name: "pipeline_tag", value: "text-generation"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "search", value: trimmed)) }
        for field in ["downloads", "likes", "lastModified", "pipeline_tag", "tags", "safetensors"] {
            items.append(URLQueryItem(name: "expand[]", value: field))
        }
        components.queryItems = items
        return components.url ?? AIConfig.huggingFaceAPI
    }

    static func treeURL(_ repo: String) -> URL? {
        guard isRepoID(repo) else { return nil }
        return URL(string: AIConfig.huggingFaceAPI.absoluteString + "/api/models/\(repo)/tree/main?recursive=true")
    }

    /// Download link for one file.
    public static func resolveURL(_ repo: String, path: String) -> URL? {
        guard isRepoID(repo) else { return nil }
        let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: AIConfig.huggingFaceAPI.absoluteString + "/\(repo)/resolve/main/\(encoded)")
    }

    /// "owner/name" with safe characters only.
    public static func isRepoID(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }

    /// Files a model needs: weights, configs and tokenizer. Not docs, images or other weight formats.
    public static func isNeeded(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        if name == ".gitattributes" || name.hasPrefix(".") { return false }
        for suffix in [".md", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf", ".gguf", ".pth", ".pt", ".bin", ".onnx", ".h5", ".msgpack", ".ckpt"]
            where lower.hasSuffix(suffix) { return false }
        // Path traversal guard: tree paths never contain these.
        if lower.hasPrefix("/") || lower.split(separator: "/").contains("..") { return false }
        return true
    }

    // MARK: Parsing

    public static func parseSearch(_ data: Data) -> [HFModel]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let id = (item["id"] as? String) ?? (item["modelId"] as? String) else { return nil }
            let safetensors = item["safetensors"] as? [String: Any]
            return HFModel(
                id: id,
                downloads: item["downloads"] as? Int ?? 0,
                likes: item["likes"] as? Int ?? 0,
                lastModified: (item["lastModified"] as? String).flatMap(DeckDate.parse),
                pipelineTag: item["pipeline_tag"] as? String,
                tags: item["tags"] as? [String] ?? [],
                parameters: ModelDiscoveryParser.uint64(safetensors?["total"])
            )
        }
    }

    public static func parseTree(_ data: Data) -> [HFFile]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard (item["type"] as? String) == "file", let path = item["path"] as? String else { return nil }
            let lfs = item["lfs"] as? [String: Any]
            let size = ModelDiscoveryParser.uint64(lfs?["size"]) ?? ModelDiscoveryParser.uint64(item["size"]) ?? 0
            return HFFile(path: path, size: size)
        }
    }
}
