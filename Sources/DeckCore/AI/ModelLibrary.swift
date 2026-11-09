import Foundation

/// The local AI runtimes the Model Library can browse, download for and clean up.
public enum ModelSource: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case mlx
    case ollama
    case lmStudio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mlx: return "MLX"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        }
    }

    /// The source of a model server kind, when it has one.
    public init?(kind: ModelServerKind) {
        switch kind {
        case .ollama: self = .ollama
        case .lmStudio: self = .lmStudio
        case .mlxLM, .oMLX: self = .mlx
        default: return nil
        }
    }
}

/// One model in the Model Library's Browse list, from any source.
public struct LibraryModel: Identifiable, Hashable, Sendable, Codable {
    public var source: ModelSource
    /// What the runtime downloads: a Hugging Face repo, an Ollama name, an LM Studio model key.
    public var key: String
    /// Short name for the table.
    public var name: String
    public var author: String?
    public var summary: String?
    /// Parameter count, for sorting. For a family with several sizes, the smallest.
    public var parameters: UInt64?
    /// "4B", "0.6B to 235B".
    public var parameterLabel: String?
    /// "4bit", "Q4_K_M".
    public var quantization: String?
    /// Download size, when the source tells it in the list.
    public var sizeBytes: UInt64?
    /// Downloads or pulls.
    public var downloads: Int
    public var likes: Int
    public var lastModified: Date?
    /// "tools", "vision", "thinking", "embedding".
    public var capabilities: [String]
    /// Ollama: how many tags the model has.
    public var tagCount: Int?
    /// Ollama: the sizes on offer ("0.6b", "8b").
    public var sizeTags: [String]
    /// LM Studio staff pick.
    public var isStaffPick: Bool
    public var webURL: URL?

    public init(source: ModelSource, key: String, name: String, author: String? = nil, summary: String? = nil,
                parameters: UInt64? = nil, parameterLabel: String? = nil, quantization: String? = nil, sizeBytes: UInt64? = nil,
                downloads: Int = 0, likes: Int = 0, lastModified: Date? = nil, capabilities: [String] = [], tagCount: Int? = nil,
                sizeTags: [String] = [], isStaffPick: Bool = false, webURL: URL? = nil) {
        self.source = source
        self.key = key
        self.name = name
        self.author = author
        self.summary = summary
        self.parameters = parameters
        self.parameterLabel = parameterLabel
        self.quantization = quantization
        self.sizeBytes = sizeBytes
        self.downloads = downloads
        self.likes = likes
        self.lastModified = lastModified
        self.capabilities = capabilities
        self.tagCount = tagCount
        self.sizeTags = sizeTags
        self.isStaffPick = isStaffPick
        self.webURL = webURL
    }

    /// Unique across sources. MLX keeps the plain repo id, so older selections and links still work.
    public var id: String { Self.id(source: source, key: key) }

    public static func id(source: ModelSource, key: String) -> String {
        source == .mlx ? key : "\(source.rawValue):\(key)"
    }

    /// "135M", "3.1B", "0.6B to 235B".
    public var parameterText: String? {
        if let parameterLabel { return parameterLabel }
        return parameters.flatMap(Self.parameterText)
    }

    public static func parameterText(_ count: UInt64) -> String? {
        guard count > 0 else { return nil }
        let value = Double(count)
        if value >= 1e9 { return String(format: value >= 1e10 ? "%.0fB" : "%.1fB", value / 1e9) }
        return String(format: "%.0fM", value / 1e6)
    }

    /// Parameter count from a size word: "0.6b", "270m", "e4b" (effective 4B), "8x7b", "35b-a3b". nil when it is not one.
    public static func parameterCount(_ word: String) -> UInt64? {
        var text = word.lowercased().trimmingCharacters(in: .whitespaces)
        if let dash = text.firstIndex(of: "-") { text = String(text[..<dash]) }
        if text.hasPrefix("e") { text.removeFirst() }
        var multiplier = 1.0
        if let x = text.firstIndex(of: "x") {
            multiplier = Double(text[..<x]) ?? 1
            text = String(text[text.index(after: x)...])
        }
        guard let unit = text.last, unit == "b" || unit == "m" || unit == "k" else { return nil }
        guard let number = Double(text.dropLast()), number > 0 else { return nil }
        let scale: Double = unit == "b" ? 1e9 : (unit == "m" ? 1e6 : 1e3)
        return UInt64(number * scale * multiplier)
    }

    /// The first size word in a model name: "qwen3-4b-thinking-2507" gives 4B, "gemma-4-e4b" gives 4B.
    public static func parameterCount(inName name: String) -> UInt64? {
        let words = name.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == ":" || $0 == "/" || $0 == " " })
        for word in words {
            let text = String(word)
            guard text.count <= 8, text.contains(where: \.isNumber) else { continue }
            if let count = parameterCount(text) { return count }
        }
        return nil
    }

    /// "0.6B to 235B" from Ollama's size tags.
    public static func rangeLabel(_ sizeTags: [String]) -> String? {
        let counts = sizeTags.compactMap { parameterCount($0) }
        guard let low = counts.min(), let high = counts.max() else { return nil }
        let lowText = shortSize(sizeTags[counts.firstIndex(of: low)!])
        if low == high { return lowText }
        return "\(lowText) to \(shortSize(sizeTags[counts.firstIndex(of: high)!]))"
    }

    private static func shortSize(_ tag: String) -> String { tag.uppercased() }
}

public extension LibraryModel {
    /// A Hugging Face mlx-community repo.
    init(huggingFace model: HFModel) {
        self.init(source: .mlx, key: model.id, name: model.name, author: model.author, summary: nil,
                  parameters: model.parameters, quantization: model.quantization, downloads: model.downloads,
                  likes: model.likes, lastModified: model.lastModified, capabilities: model.pipelineTag.map { [$0] } ?? [],
                  webURL: URL(string: "https://huggingface.co/\(model.id)"))
    }
}

/// A small JSON cache in the AI folder, for library lists that change slowly.
public struct LibraryCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    struct Entry<Value: Codable>: Codable {
        var saved: Date
        var value: Value
    }

    /// File name safe for any key.
    static func fileName(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }).prefix(80)
        var hash: UInt64 = 1469598103934665603
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return "\(cleaned)-\(String(hash, radix: 16)).json"
    }

    /// The saved value and how old it is.
    public func read<Value: Codable>(_ key: String, as type: Value.Type) -> (value: Value, age: TimeInterval)? {
        let url = directory.appendingPathComponent(Self.fileName(key))
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let entry = try? decoder.decode(Entry<Value>.self, from: data) else { return nil }
        return (entry.value, Date().timeIntervalSince(entry.saved))
    }

    public func write<Value: Codable>(_ key: String, _ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(Entry(saved: Date(), value: value)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(Self.fileName(key)), options: .atomic)
    }
}

enum HTMLText {
    /// Plain text from a bit of HTML: tags removed, common entities decoded, spaces folded.
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&nbsp;": " ", "&apos;": "'"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every capture group 1 of a pattern.
    static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
            return ns.substring(with: match.range(at: 1))
        }
    }

    static func first(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        matches(pattern, in: text, options: options).first
    }
}

/// "523MB", "5.2GB", "1.20 GB" as bytes (1000 based, as the sites print them).
enum ByteText {
    static func parse(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let match = HTMLText.first(#"^([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?B)$"#, in: trimmed),
              let number = Double(match) else { return nil }
        let unit = trimmed.replacingOccurrences(of: match, with: "").trimmingCharacters(in: .whitespaces)
        let scale: Double
        switch unit {
        case "KB": scale = 1e3
        case "MB": scale = 1e6
        case "GB": scale = 1e9
        case "TB": scale = 1e12
        default: scale = 1
        }
        return UInt64(number * scale)
    }
}
