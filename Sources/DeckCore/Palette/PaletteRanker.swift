import Foundation

/// One thing the palette can show. The app maps its rows to these for ranking.
public struct PaletteEntry: Sendable, Hashable, Identifiable {
    /// Stable id, like "container:web" or "screen:images". Also used for recents.
    public var id: String
    public var kind: PaletteKind
    public var title: String
    public var subtitle: String?
    /// Extra words that find the entry but are not shown highlighted (image reference, IP and so on).
    public var keywords: [String]

    public init(id: String, kind: PaletteKind, title: String, subtitle: String? = nil, keywords: [String] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
    }
}

public struct RankedEntry: Sendable, Hashable, Identifiable {
    public var entry: PaletteEntry
    public var score: Int
    /// Matched runs in the title, as character offsets.
    public var highlights: [Range<Int>]
    public var isRecent: Bool

    public var id: String { entry.id }

    public init(entry: PaletteEntry, score: Int, highlights: [Range<Int>] = [], isRecent: Bool = false) {
        self.entry = entry
        self.score = score
        self.highlights = highlights
        self.isRecent = isRecent
    }
}

public struct PaletteSection: Sendable, Hashable, Identifiable {
    public var title: String
    public var items: [RankedEntry]
    public var id: String { title }

    public init(title: String, items: [RankedEntry]) {
        self.title = title
        self.items = items
    }
}

/// Orders palette entries for a query. Pure, so it is unit tested.
public enum PaletteRanker {
    /// A keyword hit counts less than a title hit.
    static let keywordPenalty = 15
    /// Boost for the most recent item. Older recents get less.
    static let recentBoost = 12
    /// Results scoring under best / relativeCutoff are hidden.
    static let relativeCutoff = 4

    /// Ranks entries for `query`. An empty query keeps recents first (newest first), then the rest in order.
    /// `recents` holds entry ids, newest first.
    public static func rank(_ entries: [PaletteEntry], query: String, recents: [String] = [], limit: Int? = nil) -> [RankedEntry] {
        let recentIndex = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [(offset: Int, item: RankedEntry)] = []

        if trimmed.isEmpty {
            for (offset, entry) in entries.enumerated() {
                let recent = recentIndex[entry.id]
                result.append((recent.map { $0 - recents.count } ?? offset,
                               RankedEntry(entry: entry, score: 0, highlights: [], isRecent: recent != nil)))
            }
            result.sort { $0.offset < $1.offset }
        } else {
            for (offset, entry) in entries.enumerated() {
                var score: Int?
                var highlights: [Range<Int>] = []
                if let hit = FuzzyMatcher.match(trimmed, in: entry.title) {
                    score = hit.score
                    highlights = hit.ranges
                }
                for keyword in entry.keywords {
                    if let hit = FuzzyMatcher.match(trimmed, in: keyword) {
                        let value = hit.score - keywordPenalty
                        if score == nil || value > score! {
                            score = value
                            highlights = []
                        }
                    }
                }
                guard var total = score else { continue }
                let recent = recentIndex[entry.id]
                if let recent { total += max(0, recentBoost - recent * 2) }
                result.append((offset, RankedEntry(entry: entry, score: total, highlights: highlights, isRecent: recent != nil)))
            }
            result.sort { lhs, rhs in
                lhs.item.score != rhs.item.score ? lhs.item.score > rhs.item.score : lhs.offset < rhs.offset
            }
            // Drop weak scattered hits when there are strong ones, so the list stays short.
            if let best = result.first?.item.score, best > 0 {
                let floor = best / relativeCutoff
                result.removeAll { $0.item.score < floor }
            }
        }
        let items = result.map(\.item)
        if let limit { return Array(items.prefix(limit)) }
        return items
    }

    /// Groups ranked items for display.
    /// With a query: the best item is "Top hit", then one section per kind in rank order.
    /// Without a query: "Recent" first, then one section per kind in the order given.
    public static func sections(_ ranked: [RankedEntry], hasQuery: Bool) -> [PaletteSection] {
        var sections: [PaletteSection] = []
        var rest = ranked[...]
        if hasQuery, let first = rest.first {
            sections.append(PaletteSection(title: "Top hit", items: [first]))
            rest = rest.dropFirst()
        } else if !hasQuery {
            let recents = rest.filter(\.isRecent)
            if !recents.isEmpty {
                sections.append(PaletteSection(title: "Recent", items: Array(recents)))
                rest = rest.filter { !$0.isRecent }[...]
            }
        }
        var order: [String] = []
        var groups: [String: [RankedEntry]] = [:]
        for item in rest {
            let title = item.entry.kind.sectionTitle
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(item)
        }
        for title in order {
            sections.append(PaletteSection(title: title, items: groups[title] ?? []))
        }
        return sections
    }
}

/// Palette items used last, newest first. Stored in UserDefaults.
public struct PaletteRecents {
    public static let defaultsKey = "paletteRecentItems"
    public static let limit = 8

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var ids: [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    public func add(_ id: String) {
        var list = ids
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: Self.defaultsKey)
    }
}
