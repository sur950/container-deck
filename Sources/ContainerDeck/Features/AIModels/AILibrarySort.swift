import Foundation
import DeckCore

/// Sortable columns of the Model Library tables.
enum AILibraryColumn: String, CaseIterable {
    case model, source, parameters, bits, size, downloads, updated, location
}

/// The chosen sort of one Model Library table. Saved in Prefs as "column:asc" or "column:desc".
struct AILibrarySort: Equatable, RawRepresentable {
    var column: AILibraryColumn
    var ascending: Bool

    static let browseDefault = AILibrarySort(column: .downloads, ascending: false)
    static let localDefault = AILibrarySort(column: .size, ascending: false)

    init(column: AILibraryColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":").map(String.init)
        guard parts.count == 2, let column = AILibraryColumn(rawValue: parts[0]), parts[1] == "asc" || parts[1] == "desc" else { return nil }
        self.init(column: column, ascending: parts[1] == "asc")
    }

    var rawValue: String { "\(column.rawValue):\(ascending ? "asc" : "desc")" }

    /// Words for the status bar: "most downloaded first", "sorted by size, smallest first".
    var phrase: String {
        switch column {
        case .downloads: return ascending ? "least downloaded first" : "most downloaded first"
        case .model: return "sorted by name, \(ascending ? "A to Z" : "Z to A")"
        case .source: return "sorted by source, \(ascending ? "A to Z" : "Z to A")"
        case .parameters: return "sorted by parameters, \(ascending ? "smallest" : "largest") first"
        case .bits: return "sorted by bits, \(ascending ? "lowest" : "highest") first"
        case .size: return "sorted by size, \(ascending ? "smallest" : "largest") first"
        case .updated: return "sorted by date, \(ascending ? "oldest" : "newest") first"
        case .location: return "sorted by location, \(ascending ? "A to Z" : "Z to A")"
        }
    }

    // MARK: Values

    /// Bits per weight as a number: "4bit" is 4, "bf16" is 16, "mxfp4" is 4. Unknown ("dwq", nil) is nil.
    static func bits(_ quantization: String?) -> Double? {
        guard let quantization else { return nil }
        let digits = quantization.filter { $0.isASCII && $0.isNumber }
        return Double(digits)
    }

    // MARK: Comparing

    /// Compares two optional values. Unknown values sort last in both directions.
    static func order<T: Comparable>(_ lhs: T?, _ rhs: T?, ascending: Bool) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (lhs?, rhs?):
            if lhs == rhs { return .orderedSame }
            return (lhs < rhs) == ascending ? .orderedAscending : .orderedDescending
        }
    }

    /// Names in Finder order ("Qwen3-4B" before "Qwen3-14B"), in the given direction.
    static func order(name lhs: String, _ rhs: String, ascending: Bool) -> ComparisonResult {
        let result = lhs.localizedStandardCompare(rhs)
        guard result != .orderedSame, !ascending else { return result }
        return result == .orderedAscending ? .orderedDescending : .orderedAscending
    }
}

/// One search result with what the table shows. `rank` is the order the sources sent
/// (most downloaded first), used to break ties.
struct AILibraryRow: Identifiable, Hashable {
    let model: LibraryModel
    let size: UInt64?
    let rank: Int
    var id: String { model.id }

    init(model: LibraryModel, size: UInt64?, rank: Int) {
        self.model = model
        self.size = size
        self.rank = rank
    }

    /// A Hugging Face result (MLX).
    init(model: HFModel, size: UInt64?, rank: Int) {
        self.init(model: LibraryModel(huggingFace: model), size: size, rank: rank)
    }

    static func rows(_ models: [LibraryModel], size: (LibraryModel) -> UInt64?) -> [AILibraryRow] {
        models.enumerated().map { AILibraryRow(model: $0.element, size: size($0.element) ?? $0.element.sizeBytes, rank: $0.offset) }
    }
}

/// Sorts search results by real values: parameter counts, bits, bytes, download counts and dates.
struct AILibraryComparator: SortComparator, Hashable {
    var column: AILibraryColumn
    var order: SortOrder = .forward

    init(column: AILibraryColumn, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    init(_ sort: AILibrarySort) {
        self.init(column: sort.column, order: sort.ascending ? .forward : .reverse)
    }

    var sort: AILibrarySort { AILibrarySort(column: column, ascending: order == .forward) }

    func compare(_ lhs: AILibraryRow, _ rhs: AILibraryRow) -> ComparisonResult {
        let ascending = order == .forward
        let result: ComparisonResult
        switch column {
        case .model, .location: result = AILibrarySort.order(name: lhs.model.name, rhs.model.name, ascending: ascending)
        case .source: result = AILibrarySort.order(name: lhs.model.source.displayName, rhs.model.source.displayName, ascending: ascending)
        case .parameters: result = AILibrarySort.order(lhs.model.parameters, rhs.model.parameters, ascending: ascending)
        case .bits: result = AILibrarySort.order(AILibrarySort.bits(lhs.model.quantization), AILibrarySort.bits(rhs.model.quantization), ascending: ascending)
        case .size: result = AILibrarySort.order(lhs.size, rhs.size, ascending: ascending)
        case .downloads: result = AILibrarySort.order(lhs.model.downloads, rhs.model.downloads, ascending: ascending)
        case .updated: result = AILibrarySort.order(lhs.model.lastModified, rhs.model.lastModified, ascending: ascending)
        }
        if result != .orderedSame { return result }
        return lhs.rank == rhs.rank ? .orderedSame : (lhs.rank < rhs.rank ? .orderedAscending : .orderedDescending)
    }
}

/// Sorts the models on this Mac, from every runtime.
struct AILocalComparator: SortComparator, Hashable {
    var column: AILibraryColumn
    var order: SortOrder = .forward

    init(column: AILibraryColumn, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    init(_ sort: AILibrarySort) {
        self.init(column: sort.column, order: sort.ascending ? .forward : .reverse)
    }

    var sort: AILibrarySort { AILibrarySort(column: column, ascending: order == .forward) }

    func compare(_ lhs: InstalledModel, _ rhs: InstalledModel) -> ComparisonResult {
        let ascending = order == .forward
        let result: ComparisonResult
        switch column {
        case .size: result = AILibrarySort.order(lhs.sizeBytes, rhs.sizeBytes, ascending: ascending)
        case .updated: result = AILibrarySort.order(lhs.lastUsed, rhs.lastUsed, ascending: ascending)
        case .location: result = AILibrarySort.order(lhs.folderText, rhs.folderText, ascending: ascending)
        case .source: result = AILibrarySort.order(name: lhs.source.displayName, rhs.source.displayName, ascending: ascending)
        case .model, .parameters, .bits, .downloads: result = .orderedSame
        }
        if result != .orderedSame { return result }
        // Ties (and the Model column) go by name.
        return AILibrarySort.order(name: lhs.name, rhs.name, ascending: column == .model ? ascending : true)
    }
}
