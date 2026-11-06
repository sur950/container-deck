import Foundation

// Pure helpers for live lists: stale result protection, change detection,
// reference counted subscriptions, steady row order and grouping.
// The app's shared container feed and stats sampler are built on these.

// MARK: - Sequencing

/// Hands out a number for every poll and accepts a result only when nothing newer
/// was applied first. A slow manual refresh can never overwrite a newer poll.
public struct PollSequencer: Sendable, Equatable {
    public private(set) var issued = 0
    public private(set) var applied = 0

    public init() {}

    /// Call when a poll starts. Keep the token until the result is back.
    public mutating func begin() -> Int {
        issued += 1
        return issued
    }

    /// True when the result of `token` may be applied. Marks it as the newest applied one.
    public mutating func accept(_ token: Int) -> Bool {
        guard token > applied else { return false }
        applied = token
        return true
    }

    /// True while a poll newer than the applied one is still running.
    public var hasPending: Bool { issued > applied }
}

// MARK: - Diff

/// What changed between two lists, by id.
public struct ListChange<ID: Hashable & Sendable>: Sendable, Equatable {
    public var inserted: [ID]
    public var removed: [ID]
    public var updated: [ID]
    public var reordered: Bool

    public init(inserted: [ID] = [], removed: [ID] = [], updated: [ID] = [], reordered: Bool = false) {
        self.inserted = inserted
        self.removed = removed
        self.updated = updated
        self.reordered = reordered
    }

    /// Nothing to publish.
    public var isEmpty: Bool { inserted.isEmpty && removed.isEmpty && updated.isEmpty && !reordered }
    /// Rows appear or go away, worth an animation.
    public var changesMembership: Bool { !inserted.isEmpty || !removed.isEmpty }
}

public enum ListDiff {
    /// Compares two lists by id. Duplicate ids keep their first entry.
    public static func diff<T: Identifiable & Equatable>(old: [T], new: [T]) -> ListChange<T.ID> where T.ID: Sendable {
        var oldByID: [T.ID: T] = [:]
        for item in old where oldByID[item.id] == nil { oldByID[item.id] = item }
        var newByID: [T.ID: T] = [:]
        for item in new where newByID[item.id] == nil { newByID[item.id] = item }

        let inserted = new.map(\.id).filter { oldByID[$0] == nil }
        let removed = old.map(\.id).filter { newByID[$0] == nil }
        let updated = new.compactMap { item -> T.ID? in
            guard let before = oldByID[item.id], before != item else { return nil }
            return item.id
        }
        let keptOld = old.map(\.id).filter { newByID[$0] != nil }
        let keptNew = new.map(\.id).filter { oldByID[$0] != nil }
        return ListChange(inserted: unique(inserted), removed: unique(removed), updated: unique(updated), reordered: keptOld != keptNew)
    }

    private static func unique<ID: Hashable>(_ ids: [ID]) -> [ID] {
        var seen = Set<ID>()
        return ids.filter { seen.insert($0).inserted }
    }
}

/// Ids of running containers, for "did anything start or stop".
public extension Array where Element == ContainerSummary {
    var runningIDs: Set<String> { Set(filter(\.isRunning).map(\.id)) }
}

// MARK: - Subscriptions

/// Reference counted interest in a shared resource (the stats sampler).
/// Each screen takes a token while it is on screen and gives it back when it goes.
public struct SubscriptionSet: Sendable, Equatable {
    private var nextToken = 0
    private var holders: [Int: String] = [:]

    public init() {}

    /// Registers interest. `owner` is only for debugging.
    public mutating func acquire(_ owner: String) -> Int {
        nextToken += 1
        holders[nextToken] = owner
        return nextToken
    }

    /// Gives a token back. Unknown or already released tokens are ignored.
    @discardableResult
    public mutating func release(_ token: Int) -> Bool {
        holders.removeValue(forKey: token) != nil
    }

    public var count: Int { holders.count }
    public var isActive: Bool { !holders.isEmpty }
    public var owners: [String] { holders.keys.sorted().compactMap { holders[$0] } }
}

// MARK: - Steady order

/// Keeps rows in place while a live value (CPU, memory) moves a little.
public enum StableOrder {
    /// Orders `items` by value, but starts from `previous` and only swaps neighbours
    /// whose values differ by more than `threshold(a, b)`. When rows were added or removed
    /// it sorts fully (that change is animated anyway). Ties keep the previous order.
    public static func order<ID: Hashable>(
        previous: [ID],
        items: [(id: ID, value: Double)],
        descending: Bool,
        threshold: (Double, Double) -> Double
    ) -> [ID] {
        var values: [ID: Double] = [:]
        for item in items where values[item.id] == nil { values[item.id] = item.value }
        let ids = items.map(\.id)

        func fullSort() -> [ID] {
            let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            return Array(Set(ids)).sorted { a, b in
                let va = values[a] ?? 0, vb = values[b] ?? 0
                if va != vb { return descending ? va > vb : va < vb }
                return (rank[a] ?? 0) < (rank[b] ?? 0)
            }
        }

        guard !previous.isEmpty, Set(previous) == Set(ids), previous.count == Set(ids).count else {
            return fullSort()
        }

        var order = previous
        // Bubble passes: every swap removes one real inversion, so this ends.
        var swapped = true
        var passes = 0
        while swapped && passes <= order.count {
            swapped = false
            passes += 1
            for index in 0..<max(0, order.count - 1) {
                let a = values[order[index]] ?? 0
                let b = values[order[index + 1]] ?? 0
                let outOfOrder = descending ? b - a : a - b
                if outOfOrder > threshold(a, b) {
                    order.swapAt(index, index + 1)
                    swapped = true
                }
            }
        }
        return order
    }

    /// Default band: at least `absolute`, or `relative` of the larger value.
    public static func band(absolute: Double, relative: Double) -> (Double, Double) -> Double {
        { a, b in max(absolute, max(abs(a), abs(b)) * relative) }
    }
}

// MARK: - Grouping

/// How the Containers list groups rows.
public enum ContainerGrouping: Hashable, Sendable {
    case none
    case composeProject
    case label(String)

    /// Saved form, for scene storage.
    public var storageValue: String {
        switch self {
        case .none: return ""
        case .composeProject: return "compose"
        case .label(let key): return "label:" + key
        }
    }

    public init(storageValue: String) {
        if storageValue == "compose" {
            self = .composeProject
        } else if storageValue.hasPrefix("label:"), storageValue.count > 6 {
            self = .label(String(storageValue.dropFirst(6)))
        } else {
            self = .none
        }
    }
}

/// One section of the grouped list.
public struct ContainerGroup: Identifiable, Hashable, Sendable {
    /// The group value. Empty for "no value".
    public var value: String
    public var title: String
    public var containers: [ContainerSummary]

    public var id: String { value.isEmpty ? "\u{0}none" : value }
    public var runningCount: Int { containers.filter(\.isRunning).count }
}

public enum ContainerGroups {
    /// Sections in name order. Containers without the value go last.
    public static func group(_ containers: [ContainerSummary], by grouping: ContainerGrouping) -> [ContainerGroup] {
        let key: String
        let noneTitle: String
        switch grouping {
        case .none:
            return [ContainerGroup(value: "", title: "All containers", containers: containers)]
        case .composeProject:
            key = ComposeLabel.project
            noneTitle = "Not in a project"
        case .label(let name):
            key = name
            noneTitle = "No \(name) label"
        }
        var byValue: [String: [ContainerSummary]] = [:]
        var order: [String] = []
        for container in containers {
            let value: String
            if case .composeProject = grouping {
                // Our label first, then Docker Compose's, so stacks started by other tools group too.
                value = ComposeLabel.projectName(container.labels) ?? ""
            } else {
                value = container.labels[key]?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            if byValue[value] == nil { order.append(value) }
            byValue[value, default: []].append(container)
        }
        let named = order.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var groups = named.map { ContainerGroup(value: $0, title: $0, containers: byValue[$0] ?? []) }
        if let rest = byValue[""], !rest.isEmpty {
            groups.append(ContainerGroup(value: "", title: noneTitle, containers: rest))
        }
        return groups
    }

    /// Label keys worth grouping by: used by at least one container. Apple's own keys
    /// and the app's helper keys are left out.
    public static func labelKeys(_ containers: [ContainerSummary]) -> [String] {
        var keys = Set<String>()
        for container in containers {
            for key in container.labels.keys where !isInternal(key) {
                keys.insert(key)
            }
        }
        return keys.sorted()
    }

    static func isInternal(_ key: String) -> Bool {
        key.hasPrefix("com.apple.") || key.hasPrefix("deck.") || key.hasPrefix("com.containerdeck.")
    }
}
