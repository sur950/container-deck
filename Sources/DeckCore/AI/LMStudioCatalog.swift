import Foundation
import Yams

// LM Studio's catalog is the LM Studio Hub. `lms get <owner/name>` resolves names against its
// staff picks, then downloads the Hugging Face repos the model's model.yaml lists (GGUF or MLX).
// The Hub has a public JSON list (checked 9 Nov 2026, no account needed):
//   https://lmstudio.ai/api/v1/artifacts?type=model     every public model, with downloads, likes, staff pick
//   https://lmstudio.ai/api/v1/artifacts/<owner>/<name> one model
// The model page (https://lmstudio.ai/models/<owner>/<name>) carries its model.yaml: parameter
// sizes, memory need, formats and the Hugging Face repos. File sizes come from Hugging Face.

/// One model in LM Studio's catalog.
public struct LMStudioCatalogModel: Sendable, Hashable, Codable {
    /// "qwen/qwen3-4b", what `lms get` takes.
    public var identifier: String
    public var summary: String?
    public var downloads: Int
    public var likes: Int
    public var updated: Date?
    public var isStaffPick: Bool

    public init(identifier: String, summary: String? = nil, downloads: Int = 0, likes: Int = 0, updated: Date? = nil, isStaffPick: Bool = false) {
        self.identifier = identifier
        self.summary = summary
        self.downloads = downloads
        self.likes = likes
        self.updated = updated
        self.isStaffPick = isStaffPick
    }

    public var owner: String { identifier.split(separator: "/").first.map(String.init) ?? "" }
    public var name: String { identifier.split(separator: "/").last.map(String.init) ?? identifier }

    public var libraryModel: LibraryModel {
        LibraryModel(source: .lmStudio, key: identifier, name: name, author: owner, summary: summary,
                     parameters: LibraryModel.parameterCount(inName: name), downloads: downloads, likes: likes,
                     lastModified: updated, isStaffPick: isStaffPick,
                     webURL: URL(string: "https://lmstudio.ai/models/\(identifier)"))
    }
}

/// One download option of an LM Studio model: a Hugging Face repo in GGUF or MLX format.
public struct LMStudioVariant: Sendable, Hashable, Codable, Identifiable {
    /// "lmstudio-community/qwen3-4b-mlx-4bit".
    public var key: String
    /// Hugging Face repo, "lmstudio-community/Qwen3-4B-MLX-4bit".
    public var repo: String?

    public init(key: String, repo: String? = nil) {
        self.key = key
        self.repo = repo
    }

    public var id: String { key }

    /// "MLX" or "GGUF" from the name.
    public var format: String {
        let lower = (repo ?? key).lowercased()
        if lower.contains("mlx") { return "MLX" }
        if lower.contains("gguf") { return "GGUF" }
        return "Other"
    }

    /// "4bit", "8bit" for MLX repos.
    public var quantization: String? {
        HFModel(id: repo ?? key).quantization
    }
}

/// What the model page tells about a model.
public struct LMStudioModelDetail: Sendable, Hashable, Codable {
    /// "4B".
    public var parameters: [String]
    public var minMemoryBytes: UInt64?
    /// "gguf", "safetensors".
    public var compatibility: [String]
    public var contextLength: Int?
    public var vision: Bool
    public var reasoning: Bool
    public var tools: Bool
    public var variants: [LMStudioVariant]

    public init(parameters: [String] = [], minMemoryBytes: UInt64? = nil, compatibility: [String] = [], contextLength: Int? = nil,
                vision: Bool = false, reasoning: Bool = false, tools: Bool = false, variants: [LMStudioVariant] = []) {
        self.parameters = parameters
        self.minMemoryBytes = minMemoryBytes
        self.compatibility = compatibility
        self.contextLength = contextLength
        self.vision = vision
        self.reasoning = reasoning
        self.tools = tools
        self.variants = variants
    }

    /// "GGUF, MLX".
    public var formatText: String? {
        var names: [String] = []
        for variant in variants where !names.contains(variant.format) && variant.format != "Other" { names.append(variant.format) }
        if names.isEmpty {
            if compatibility.contains("gguf") { names.append("GGUF") }
            if compatibility.contains("safetensors") { names.append("MLX") }
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
}

public struct LMStudioCatalogResult: Sendable, Equatable {
    public var models: [LMStudioCatalogModel]
    public var origin: LibrarySearchOrigin

    public init(models: [LMStudioCatalogModel], origin: LibrarySearchOrigin) {
        self.models = models
        self.origin = origin
    }
}

/// Reads LM Studio's model catalog.
public struct LMStudioCatalogClient: Sendable {
    let http: AIHTTPFetching
    let cache: LibraryCache?
    public static let cacheLifetime: TimeInterval = 6 * 3600
    static let catalogURL = URL(string: "https://lmstudio.ai/api/v1/artifacts?type=model")!
    /// Community models (not staff picks) need this many downloads to be listed.
    public static let communityMinimumDownloads = 2_000
    public static let pageSize = 60

    public init(http: AIHTTPFetching = AIHTTPClient(), cache: LibraryCache? = LibraryCache(directory: AIPaths().libraryCache)) {
        self.http = http
        self.cache = cache
    }

    /// The catalog, filtered by a query. When the site does not answer, the saved catalog is used.
    public func search(_ query: String) async throws -> LMStudioCatalogResult {
        let catalog = try await self.catalog()
        return LMStudioCatalogResult(models: LMStudioCatalogParser.filter(catalog.models, query: query), origin: catalog.origin)
    }

    func catalog() async throws -> LMStudioCatalogResult {
        let key = "lmstudio-catalog"
        if let saved = cache?.read(key, as: [LMStudioCatalogModel].self), saved.age < Self.cacheLifetime, !saved.value.isEmpty {
            return LMStudioCatalogResult(models: saved.value, origin: .live)
        }
        var request = URLRequest(url: Self.catalogURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let (data, status) = try? await http.send(request), status == 200 {
            let models = LMStudioCatalogParser.parseArtifacts(data)
            if !models.isEmpty {
                cache?.write(key, models)
                return LMStudioCatalogResult(models: models, origin: .live)
            }
        }
        if let saved = cache?.read(key, as: [LMStudioCatalogModel].self), !saved.value.isEmpty {
            return LMStudioCatalogResult(models: saved.value, origin: .cached)
        }
        throw DeckError.network("Could not reach LM Studio's model catalog.")
    }

    /// Parameters, memory need, formats and download options from the model page.
    public func detail(_ identifier: String) async throws -> LMStudioModelDetail {
        guard HuggingFaceClient.isRepoID(identifier), let url = URL(string: "https://lmstudio.ai/models/\(identifier)") else {
            throw DeckError.network("\(identifier) is not an LM Studio model name.")
        }
        let key = "lmstudio-detail-" + identifier
        if let saved = cache?.read(key, as: LMStudioModelDetail.self), saved.age < Self.cacheLifetime { return saved.value }
        let (data, status) = try await http.get(url, timeout: 20)
        guard status == 200 else { throw DeckError.network(AIHTTP.errorMessage(data, status: status)) }
        guard let detail = LMStudioCatalogParser.parseModelPage(String(decoding: data, as: UTF8.self)) else {
            throw DeckError.parse("the LM Studio model page")
        }
        cache?.write(key, detail)
        return detail
    }
}

public enum LMStudioCatalogParser {
    /// Models from `/api/v1/artifacts`. Leaves out presets, plugins, skills and private models.
    public static func parseArtifacts(_ data: Data) -> [LMStudioCatalogModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list: [[String: Any]]
        if let dict = object as? [String: Any], let items = dict["publicArtifacts"] as? [[String: Any]] {
            list = items
        } else if let items = object as? [[String: Any]] {
            list = items
        } else {
            return []
        }
        return list.compactMap { item in
            guard (item["type"] as? String ?? "model") == "model", (item["private"] as? Bool) != true else { return nil }
            let identifier = (item["identifier"] as? String)
                ?? [item["owner"] as? String, item["name"] as? String].compactMap { $0 }.joined(separator: "/")
            guard HuggingFaceClient.isRepoID(identifier) else { return nil }
            let description = (item["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return LMStudioCatalogModel(
                identifier: identifier,
                summary: (description?.isEmpty ?? true) ? nil : description,
                downloads: (item["downloadCount"] as? Int) ?? ((item["current"] as? [String: Any])?["downloadCount"] as? Int) ?? 0,
                likes: item["likeCount"] as? Int ?? 0,
                updated: (item["updatedAt"] as? String).flatMap(DeckDate.parse),
                isStaffPick: item["staffPickedAt"] is String
            )
        }
    }

    /// Staff picks and popular community models whose name or summary has every word of the query,
    /// staff picks first, then most downloaded.
    public static func filter(_ models: [LMStudioCatalogModel], query: String, limit: Int = LMStudioCatalogClient.pageSize) -> [LMStudioCatalogModel] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = models.filter { model in
            guard model.isStaffPick || model.downloads >= LMStudioCatalogClient.communityMinimumDownloads else { return false }
            let text = (model.identifier + " " + (model.summary ?? "")).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        return Array(matching.sorted { a, b in
            if a.isStaffPick != b.isStaffPick { return a.isStaffPick }
            return a.downloads > b.downloads
        }.prefix(limit))
    }

    /// Reads the model.yaml that the model page carries in its page data.
    public static func parseModelPage(_ html: String) -> LMStudioModelDetail? {
        if let yaml = modelYAML(html), let detail = parseModelYAML(yaml) { return detail }
        // Older pages have no model.yaml, only links to their Hugging Face repos.
        var repos: [String] = []
        for repo in HTMLText.matches(#"huggingface\.co/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)"#, in: html)
            where HuggingFaceClient.isRepoID(repo) && !repos.contains(repo) && !repo.hasPrefix("docs/") {
            repos.append(repo)
        }
        guard !repos.isEmpty else { return nil }
        return LMStudioModelDetail(variants: repos.prefix(6).map { LMStudioVariant(key: $0.lowercased(), repo: $0) })
    }

    /// The model.yaml text inside the page. It sits in the page data as an escaped string, once
    /// (`\n` for new lines) or twice (`\\n`) depending on the page, so it is unescaped as JSON
    /// strings. Only the parts we read are kept (model, base, metadataOverrides): the rest can hold
    /// chat templates that are not plain YAML once cut out of the page.
    static func modelYAML(_ html: String) -> String? {
        // The page can also carry a syntax colored copy (HTML spans). Use the first plain one.
        var searchStart = html.startIndex
        while let start = html.range(of: "# model.yaml is an open standard", range: searchStart..<html.endIndex) {
            if let yaml = modelYAML(from: html[start.lowerBound...]) { return yaml }
            searchStart = start.upperBound
        }
        return nil
    }

    static func modelYAML(from rest: Substring) -> String? {
        guard !rest.prefix(120).contains("\\u003c") else { return nil }
        let doubled = rest.prefix(400).contains("\\\\n")
        let ends: [String] = doubled ? [#"\\","#, #"\\"\}"#, "</script>"] : [#"\\n[0-9a-z]{1,4}:[A-Z\[]"#, #"","#, #""\]\)"#, "</script>"]
        var cut = rest.endIndex
        for pattern in ends {
            if let range = rest.range(of: pattern, options: .regularExpression), range.lowerBound < cut { cut = range.lowerBound }
        }
        var text = String(rest[..<cut])
        for _ in 0..<(doubled ? 2 : 1) {
            guard let decoded = jsonUnescape(text) else { return nil }
            text = decoded
        }
        let kept = topLevelSections(text, keep: ["model", "base", "metadataOverrides"])
        return kept.contains("model:") ? kept : nil
    }

    /// One level of JSON string escapes (\n, \", \\, \u0026).
    static func jsonUnescape(_ text: String) -> String? {
        // A cut can end in the middle of an escape. Drop a lone trailing backslash.
        var body = text
        while body.hasSuffix("\\") && !body.hasSuffix("\\\\") { body.removeLast() }
        guard let data = ("\"" + body + "\"").data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }

    /// The top level YAML blocks with these keys, comments dropped.
    static func topLevelSections(_ yaml: String, keep: Set<String>) -> String {
        var lines: [String] = []
        var keeping = false
        for line in yaml.components(separatedBy: "\n") {
            if let first = line.first, first != " ", first != "-", first != "#" {
                let key = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                keeping = keep.contains(key)
            }
            if keeping { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    public static func parseModelYAML(_ yaml: String) -> LMStudioModelDetail? {
        guard let object = (try? Yams.load(yaml: yaml)) as? [String: Any] else { return nil }
        var detail = LMStudioModelDetail()
        let meta = object["metadataOverrides"] as? [String: Any] ?? [:]
        detail.parameters = (meta["paramsStrings"] as? [Any])?.map { "\($0)" } ?? []
        detail.minMemoryBytes = ModelDiscoveryParser.uint64(meta["minMemoryUsageBytes"])
            ?? (meta["minMemoryUsageBytes"] as? Double).map { UInt64($0) }
        detail.compatibility = (meta["compatibilityTypes"] as? [Any])?.map { "\($0)".lowercased() } ?? []
        detail.contextLength = (meta["contextLengths"] as? [Any])?.compactMap { $0 as? Int }.max()
        detail.vision = meta["vision"] as? Bool ?? false
        detail.reasoning = meta["reasoning"] as? Bool ?? false
        detail.tools = meta["trainedForToolUse"] as? Bool ?? false
        for base in object["base"] as? [[String: Any]] ?? [] {
            guard let key = base["key"] as? String else { continue }
            let source = (base["sources"] as? [[String: Any]])?.first { ($0["type"] as? String) == "huggingface" }
            var repo: String?
            if let user = source?["user"] as? String, let name = source?["repo"] as? String { repo = "\(user)/\(name)" }
            detail.variants.append(LMStudioVariant(key: key, repo: repo.flatMap { HuggingFaceClient.isRepoID($0) ? $0 : nil }))
        }
        return detail
    }
}

/// Progress of `lms get`, read from its progress bar:
/// `⠋ [████▌     ] 45.20% | 1.20 GB / 2.50 GB | 10.5 MB/s | ETA 2m 3s`.
public struct LMStudioDownloadProgress: Sendable, Equatable {
    public var fraction: Double?
    public var completedBytes: UInt64?
    public var totalBytes: UInt64?
    /// Last plain line lms printed ("Finalizing download...").
    public var message: String?

    public init(fraction: Double? = nil, completedBytes: UInt64? = nil, totalBytes: UInt64? = nil, message: String? = nil) {
        self.fraction = fraction
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.message = message
    }

    /// Reads one output line. nil for blank lines.
    public static func parse(_ raw: String) -> LMStudioDownloadProgress? {
        let line = stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if let percent = HTMLText.first(#"([0-9]+(?:\.[0-9]+)?)%"#, in: line), let value = Double(percent) {
            var progress = LMStudioDownloadProgress(fraction: min(1, max(0, value / 100)))
            let sizes = HTMLText.matches(#"([0-9]+(?:\.[0-9]+)?\s*[KMGT]?B)(?![/a-zA-Z])"#, in: line)
            if sizes.count >= 2 {
                progress.completedBytes = ByteText.parse(sizes[0])
                progress.totalBytes = ByteText.parse(sizes[1])
            }
            return progress
        }
        // Box drawing and spinner lines say nothing useful.
        let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 3 else { return nil }
        return LMStudioDownloadProgress(message: line)
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
    }
}

public extension LMStudioRuntime {
    /// `lms get <model> --yes`: downloads the variant lms picks for this Mac without asking.
    static func getArguments(_ model: String) -> [String] { ["get", model, "--yes"] }

    /// Downloads a model with `lms get`. Streams its output, one line per progress update.
    func download(_ model: String) throws -> AsyncThrowingStream<String, Error> {
        guard HuggingFaceClient.isRepoID(model) || model.hasPrefix("https://huggingface.co/") else {
            throw DeckError.commandFailed("\(model) is not an LM Studio model name.")
        }
        guard let cli = findCLI() else {
            throw DeckError.commandFailed("The lms command was not found. Install LM Studio core on the LM Studio tab.")
        }
        return streamer.stream(cli, Self.getArguments(model))
    }

    /// The folder LM Studio downloads models into: `downloadsFolder` in ~/.lmstudio/settings.json,
    /// else ~/.lmstudio/models. With a stand in tools folder, `<tools>/models`.
    func modelsDirectory() -> URL {
        if let toolsDirectory { return URL(fileURLWithPath: toolsDirectory, isDirectory: true).appendingPathComponent("models", isDirectory: true) }
        let settings = URL(fileURLWithPath: AIConfig.expand("~/.lmstudio/settings.json"))
        if let data = try? Data(contentsOf: settings), let folder = Self.parseDownloadsFolder(data) {
            return URL(fileURLWithPath: AIConfig.expand(folder), isDirectory: true)
        }
        return URL(fileURLWithPath: AIConfig.expand("~/.lmstudio/models"), isDirectory: true)
    }

    /// Models that come with LM Studio (~/.lmstudio/.internal/bundled-models). Never deleted here.
    func bundledModelsDirectory() -> URL {
        if let toolsDirectory { return URL(fileURLWithPath: toolsDirectory, isDirectory: true).appendingPathComponent(".internal/bundled-models", isDirectory: true) }
        return URL(fileURLWithPath: AIConfig.expand("~/.lmstudio/.internal/bundled-models"), isDirectory: true)
    }

    /// `downloadsFolder` from LM Studio's settings.json.
    static func parseDownloadsFolder(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = object["downloadsFolder"] as? String, !folder.isEmpty else { return nil }
        return folder
    }
}
