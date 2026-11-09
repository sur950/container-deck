import Foundation

// Ollama has no documented search API (checked 9 Nov 2026). What exists:
//   https://ollama.com/search?q=<text>      HTML only, 20 results, most popular first.
//   https://ollama.com/library/<name>/tags  HTML with every tag and its size. With
//                                           `Accept: application/json` it answers {"tags":[...]} (names only).
//   https://registry.ollama.ai/v2/library/<name>/manifests/<tag>
//                                           The OCI registry API. Layer sizes give the download size.
// So search reads the HTML defensively, caches what it found, and falls back to the cache
// and then to a short list of popular models. The exact name box always works.

/// One model family on ollama.com ("qwen3").
public struct OllamaLibraryModel: Sendable, Hashable, Codable {
    public var name: String
    public var summary: String?
    public var downloads: Int
    public var updated: Date?
    public var tagCount: Int?
    /// "0.6b", "8b".
    public var sizes: [String]
    /// "tools", "vision", "thinking", "embedding", "cloud".
    public var capabilities: [String]

    public init(name: String, summary: String? = nil, downloads: Int = 0, updated: Date? = nil, tagCount: Int? = nil,
                sizes: [String] = [], capabilities: [String] = []) {
        self.name = name
        self.summary = summary
        self.downloads = downloads
        self.updated = updated
        self.tagCount = tagCount
        self.sizes = sizes
        self.capabilities = capabilities
    }

    /// True for models that only run in Ollama's cloud.
    public var isCloudOnly: Bool { capabilities.contains("cloud") && sizes.isEmpty }

    public var libraryModel: LibraryModel {
        let counts = sizes.compactMap { LibraryModel.parameterCount($0) }
        return LibraryModel(source: .ollama, key: name, name: name, author: "Ollama", summary: summary,
                            parameters: counts.min(), parameterLabel: LibraryModel.rangeLabel(sizes),
                            downloads: downloads, lastModified: updated, capabilities: capabilities, tagCount: tagCount,
                            sizeTags: sizes, webURL: URL(string: "https://ollama.com/library/\(name)"))
    }
}

/// One tag of an Ollama model ("qwen3:0.6b").
public struct OllamaLibraryTag: Sendable, Hashable, Codable, Identifiable {
    /// "0.6b", "latest".
    public var tag: String
    public var sizeBytes: UInt64?
    /// Short digest. Tags with the same digest are the same download.
    public var digest: String?
    /// "40K".
    public var context: String?

    public init(tag: String, sizeBytes: UInt64? = nil, digest: String? = nil, context: String? = nil) {
        self.tag = tag
        self.sizeBytes = sizeBytes
        self.digest = digest
        self.context = context
    }

    public var id: String { tag }

    /// "Q4_K_M" from "8b-q4_K_M", "FP16" from "4b-fp16". nil for plain size tags.
    public var quantization: String? {
        let lower = tag.lowercased()
        guard let range = lower.range(of: #"(q[0-9]+(_[0-9a-z]+)*|fp16|bf16|fp32|mxfp4)$"#, options: .regularExpression) else { return nil }
        return String(tag[range]).uppercased()
    }
}

/// Where a search result came from.
public enum LibrarySearchOrigin: String, Sendable, Codable, Equatable {
    case live
    /// The site did not answer. These are from the last good answer.
    case cached
    /// Nothing reachable and nothing saved: popular models built into the app.
    case builtIn
}

public struct OllamaSearchResult: Sendable, Equatable {
    public var models: [OllamaLibraryModel]
    public var origin: LibrarySearchOrigin

    public init(models: [OllamaLibraryModel], origin: LibrarySearchOrigin) {
        self.models = models
        self.origin = origin
    }
}

/// Reads ollama.com's model library.
public struct OllamaLibraryClient: Sendable {
    let http: AIHTTPFetching
    let cache: LibraryCache?
    /// How long a saved search is used without asking the site again.
    public static let cacheLifetime: TimeInterval = 6 * 3600
    /// Most models shown for one search. The library page lists every model.
    public static let pageSize = 60

    public init(http: AIHTTPFetching = AIHTTPClient(), cache: LibraryCache? = LibraryCache(directory: AIPaths().libraryCache)) {
        self.http = http
        self.cache = cache
    }

    /// Searches ollama.com. Never throws: falls back to the last saved answer, then to built in popular models.
    public func search(_ query: String) async -> OllamaSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = "ollama-search-" + trimmed
        if let saved = cache?.read(key, as: [OllamaLibraryModel].self), saved.age < Self.cacheLifetime, !saved.value.isEmpty {
            return OllamaSearchResult(models: saved.value, origin: .live)
        }
        if let (data, status) = try? await http.get(Self.searchURL(trimmed), timeout: 15), status == 200 {
            // Cloud only models can't be downloaded to this Mac.
            let models = Array(OllamaLibraryParser.parseSearch(String(decoding: data, as: UTF8.self)).filter { !$0.isCloudOnly }.prefix(Self.pageSize))
            if !models.isEmpty {
                cache?.write(key, models)
                return OllamaSearchResult(models: models, origin: .live)
            }
            // A page that parsed to nothing but says it has no results is a real empty answer.
            if OllamaLibraryParser.resultCount(String(decoding: data, as: UTF8.self)) == 0 {
                return OllamaSearchResult(models: [], origin: .live)
            }
        }
        if let saved = cache?.read(key, as: [OllamaLibraryModel].self), !saved.value.isEmpty {
            return OllamaSearchResult(models: saved.value, origin: .cached)
        }
        return OllamaSearchResult(models: OllamaLibraryParser.builtIn(matching: trimmed), origin: .builtIn)
    }

    /// Tags with sizes. Reads the tags page, else the tag list plus registry sizes for the first few.
    public func tags(_ name: String) async throws -> [OllamaLibraryTag] {
        guard OllamaLibraryParser.isModelName(name) else { throw DeckError.network("\(name) is not an Ollama model name.") }
        let key = "ollama-tags-" + name
        if let saved = cache?.read(key, as: [OllamaLibraryTag].self), saved.age < Self.cacheLifetime, !saved.value.isEmpty {
            return saved.value
        }
        var tags: [OllamaLibraryTag] = []
        if let (data, status) = try? await http.get(Self.tagsURL(name), timeout: 15), status == 200 {
            tags = OllamaLibraryParser.parseTagsPage(String(decoding: data, as: UTF8.self), model: name)
        }
        if tags.isEmpty {
            var request = URLRequest(url: Self.tagsURL(name), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (data, status) = try? await http.send(request), status == 200 {
                tags = OllamaLibraryParser.parseTagList(data).map { OllamaLibraryTag(tag: $0) }
                // Sizes for the plain size tags (latest, 0.6b, 8b) from the registry, a few at a time.
                let wanted = tags.filter { $0.quantization == nil }.prefix(12).map(\.tag)
                let sizes = await registrySizes(name, tags: Array(wanted))
                tags = tags.map { tag in
                    var copy = tag
                    copy.sizeBytes = sizes[tag.tag]
                    return copy
                }
            }
        }
        if tags.isEmpty {
            if let saved = cache?.read(key, as: [OllamaLibraryTag].self), !saved.value.isEmpty { return saved.value }
            throw DeckError.network("Could not read the tags of \(name) from ollama.com.")
        }
        cache?.write(key, tags)
        return tags
    }

    /// Download size of one tag from the registry manifest.
    public func registrySize(_ name: String, tag: String) async -> UInt64? {
        guard let url = Self.manifestURL(name, tag: tag) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.docker.distribution.manifest.v2+json", forHTTPHeaderField: "Accept")
        guard let (data, status) = try? await http.send(request), status == 200 else { return nil }
        return OllamaLibraryParser.manifestSize(data)
    }

    func registrySizes(_ name: String, tags: [String]) async -> [String: UInt64] {
        await withTaskGroup(of: (String, UInt64?).self) { group in
            for tag in tags { group.addTask { (tag, await registrySize(name, tag: tag)) } }
            var sizes: [String: UInt64] = [:]
            for await (tag, size) in group { if let size { sizes[tag] = size } }
            return sizes
        }
    }

    // MARK: URLs

    /// An empty search reads the library page, which lists the most popular models first.
    static func searchURL(_ query: String) -> URL {
        if query.isEmpty { return URL(string: "https://ollama.com/library")! }
        var components = URLComponents(string: "https://ollama.com/search")!
        if !query.isEmpty { components.queryItems = [URLQueryItem(name: "q", value: query)] }
        return components.url!
    }

    static func tagsURL(_ name: String) -> URL {
        URL(string: "https://ollama.com/library/\(name)/tags")!
    }

    static func manifestURL(_ name: String, tag: String) -> URL? {
        guard OllamaLibraryParser.isModelName(name), OllamaLibraryParser.isModelName(tag) else { return nil }
        return URL(string: "https://registry.ollama.ai/v2/library/\(name)/manifests/\(tag)")
    }
}

/// Pure parsing for ollama.com pages. Every field is optional: a changed page gives fewer
/// details, never a crash.
public enum OllamaLibraryParser {
    /// Library names and tags: lower case letters, digits, dots, dashes and underscores.
    public static func isModelName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), text.count <= 120 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return text.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// "name" or "name:tag", the way `ollama pull` takes it.
    public static func isPullName(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let name = parts.first else { return false }
        // Namespaced models ("user/model") are allowed too.
        let nameParts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard nameParts.count <= 2, nameParts.allSatisfy({ isModelName(String($0)) }) else { return false }
        return parts.count == 1 || isModelName(String(parts[1]))
    }

    /// `data-result-count="20"` on the search page.
    static func resultCount(_ html: String) -> Int? {
        HTMLText.first(#"data-result-count="(\d+)""#, in: html).flatMap(Int.init)
    }

    /// Models on https://ollama.com/search.
    public static func parseSearch(_ html: String) -> [OllamaLibraryModel] {
        let pieces = html.components(separatedBy: "<a href=\"/library/").dropFirst()
        var models: [OllamaLibraryModel] = []
        for piece in pieces {
            guard let quote = piece.firstIndex(of: "\"") else { continue }
            let name = String(piece[..<quote])
            guard isModelName(name), !models.contains(where: { $0.name == name }) else { continue }
            let block = piece.components(separatedBy: "</li>").first ?? piece
            var model = OllamaLibraryModel(name: name)
            if let summary = HTMLText.first(#"<p[^>]*>(.*?)</p>"#, in: block, options: [.dotMatchesLineSeparators]) {
                let text = HTMLText.plain(summary)
                model.summary = text.isEmpty ? nil : text
            }
            // The search page says "6,089,193 downloads". The library page says "42.9M Pulls".
            if let downloads = HTMLText.first(#"title="([0-9,]+) downloads""#, in: block) {
                model.downloads = Int(downloads.replacingOccurrences(of: ",", with: "")) ?? 0
            } else if let short = HTMLText.first(#"<span\s*>([0-9.,]+[KMB]?)</span>\s*<span[^>]*>(?:&nbsp;|\s)*Pulls"#, in: block, options: [.caseInsensitive]) {
                model.downloads = shortCount(short.replacingOccurrences(of: ",", with: "")) ?? 0
            }
            if let updated = HTMLText.first(#"title="Updated ([^"]+)""#, in: block) {
                model.updated = longDate(updated)
            } else if let updated = HTMLText.first(#"title="([A-Z][a-z]{2} [0-9]{1,2}, [0-9]{4})[^"]*""#, in: block) {
                model.updated = shortDate(updated)
            }
            if let tags = HTMLText.first(#">\s*([0-9,]+) tags?\s*<"#, in: block, options: [.caseInsensitive])
                ?? HTMLText.first(#"<span\s*>([0-9,]+)</span>\s*<span[^>]*>(?:&nbsp;|\s)*Tags"#, in: block, options: [.caseInsensitive]) {
                model.tagCount = Int(tags.replacingOccurrences(of: ",", with: ""))
            }
            for chip in chips(block) {
                if chip.isSize { model.sizes.append(chip.text) } else { model.capabilities.append(chip.text) }
            }
            models.append(model)
        }
        return models
    }

    /// The small labels on a result: sizes (blue) and capabilities (indigo).
    static func chips(_ block: String) -> [(text: String, isSize: Bool)] {
        guard let regex = try? NSRegularExpression(pattern: #"<span\s+class="([^"]*rounded-md[^"]*)"[^>]*>([^<]+)</span>"#) else { return [] }
        let ns = block as NSString
        return regex.matches(in: block, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let style = ns.substring(with: match.range(at: 1))
            let text = HTMLText.plain(ns.substring(with: match.range(at: 2))).lowercased()
            guard !text.isEmpty, text.count <= 24 else { return nil }
            let looksLikeSize = LibraryModel.parameterCount(text) != nil
            return (text, style.contains("ddf4ff") || (looksLikeSize && !style.contains("indigo")))
        }
    }

    /// Tags on https://ollama.com/library/<name>/tags with size, digest and context.
    public static func parseTagsPage(_ html: String, model: String) -> [OllamaLibraryTag] {
        let marker = "<a href=\"/library/\(model):"
        var tags: [OllamaLibraryTag] = []
        for piece in html.components(separatedBy: marker).dropFirst() {
            guard let quote = piece.firstIndex(of: "\"") else { continue }
            let tag = String(piece[..<quote])
            guard isModelName(tag) else { continue }
            let block = piece.components(separatedBy: "</a>").first ?? piece
            let text = HTMLText.plain(block)
            var item = OllamaLibraryTag(tag: tag)
            item.digest = HTMLText.first(#"\b([0-9a-f]{12})\b"#, in: text)
            if let size = HTMLText.first(#"•\s*([0-9]+(?:\.[0-9]+)?\s*[KMGT]?B)\s*•"#, in: text) {
                item.sizeBytes = ByteText.parse(size)
            }
            item.context = HTMLText.first(#"([0-9]+(?:\.[0-9]+)?[KM]?) context window"#, in: text)
            // Each row has two links (phone and desktop layout). Keep the one with details.
            if let index = tags.firstIndex(where: { $0.tag == tag }) {
                if tags[index].sizeBytes == nil, item.sizeBytes != nil { tags[index] = item }
                continue
            }
            tags.append(item)
        }
        return tags
    }

    /// `{"tags":["latest","0.6b"]}` from the tags page asked for JSON.
    public static func parseTagList(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tags = object["tags"] as? [String] else { return [] }
        return tags.filter(isModelName)
    }

    /// Download size from a registry manifest: the config plus every layer.
    public static func manifestSize(_ data: Data) -> UInt64? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = object["layers"] as? [[String: Any]] else { return nil }
        let config = ModelDiscoveryParser.uint64((object["config"] as? [String: Any])?["size"]) ?? 0
        let total = layers.reduce(config) { $0 + (ModelDiscoveryParser.uint64($1["size"]) ?? 0) }
        return total > 0 ? total : nil
    }

    /// "6.1M" as 6_100_000.
    static func shortCount(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let last = trimmed.last else { return nil }
        let scale: Double
        switch last {
        case "K": scale = 1e3
        case "M": scale = 1e6
        case "B": scale = 1e9
        default: return Int(trimmed)
        }
        return Double(trimmed.dropLast()).map { Int($0 * scale) }
    }

    /// "Oct 10, 2025".
    static func shortDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    /// "November 8, 2026".
    static func longDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Built in

    /// Popular models, used only when ollama.com cannot be reached and nothing is saved.
    public static let popular: [OllamaLibraryModel] = [
        OllamaLibraryModel(name: "llama3.2", summary: "Meta's small Llama models, good for chat on a laptop.", sizes: ["1b", "3b"], capabilities: ["tools"]),
        OllamaLibraryModel(name: "llama3.1", summary: "Meta's Llama 3.1 with tool use.", sizes: ["8b", "70b", "405b"], capabilities: ["tools"]),
        OllamaLibraryModel(name: "qwen3", summary: "Qwen's dense and mixture of experts models.", sizes: ["0.6b", "1.7b", "4b", "8b", "14b", "30b", "32b", "235b"], capabilities: ["tools", "thinking"]),
        OllamaLibraryModel(name: "qwen2.5-coder", summary: "Qwen models for writing and fixing code.", sizes: ["0.5b", "1.5b", "3b", "7b", "14b", "32b"], capabilities: ["tools"]),
        OllamaLibraryModel(name: "gemma3", summary: "Google's Gemma 3, with image input.", sizes: ["270m", "1b", "4b", "12b", "27b"], capabilities: ["vision"]),
        OllamaLibraryModel(name: "gpt-oss", summary: "OpenAI's open weight models.", sizes: ["20b", "120b"], capabilities: ["tools", "thinking"]),
        OllamaLibraryModel(name: "deepseek-r1", summary: "DeepSeek's reasoning models.", sizes: ["1.5b", "7b", "8b", "14b", "32b", "70b"], capabilities: ["tools", "thinking"]),
        OllamaLibraryModel(name: "mistral", summary: "Mistral 7B.", sizes: ["7b"], capabilities: ["tools"]),
        OllamaLibraryModel(name: "phi4", summary: "Microsoft's Phi 4.", sizes: ["14b"]),
        OllamaLibraryModel(name: "llava", summary: "A model that reads images.", sizes: ["7b", "13b", "34b"], capabilities: ["vision"]),
        OllamaLibraryModel(name: "tinyllama", summary: "A very small Llama model for quick tests.", sizes: ["1.1b"]),
        OllamaLibraryModel(name: "nomic-embed-text", summary: "Text embeddings.", capabilities: ["embedding"]),
        OllamaLibraryModel(name: "qwen3-embedding", summary: "Qwen's text embedding models.", sizes: ["0.6b", "4b", "8b"], capabilities: ["embedding"])
    ]

    /// Built in models whose name or summary contains the query.
    public static func builtIn(matching query: String) -> [OllamaLibraryModel] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return popular }
        return popular.filter { $0.name.contains(text) || ($0.summary?.lowercased().contains(text) ?? false) }
    }
}
