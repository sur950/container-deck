import Foundation

/// One line of a diff.
public struct DiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case same, added, removed, gap }
    public var kind: Kind
    public var text: String
    /// Line number in the new file (old file for removed lines).
    public var number: Int?
    public var id: Int

    public init(kind: Kind, text: String, number: Int?, id: Int) {
        self.kind = kind
        self.text = text
        self.number = number
        self.id = id
    }
}

/// Line diff for previews. Big files are trimmed to the changed part before the LCS step.
public enum LineDiff {
    public static func diff(_ old: String, _ new: String, context: Int = 3) -> [DiffLine] {
        let a = lines(old)
        let b = lines(new)
        // Trim the common head and tail so huge files (like ~/.claude.json) stay fast.
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let midA = Array(a[head..<(a.count - tail)])
        let midB = Array(b[head..<(b.count - tail)])

        var raw: [(DiffLine.Kind, String, Int?)] = []
        for i in 0..<head { raw.append((.same, a[i], i + 1)) }
        for (kind, text, index) in lcs(midA, midB) {
            raw.append((kind, text, index.map { $0 + head + 1 }))
        }
        for i in 0..<tail { raw.append((.same, b[b.count - tail + i], b.count - tail + i + 1)) }

        // Keep `context` lines around changes, a gap marker elsewhere.
        let changed = raw.indices.filter { raw[$0].0 != .same }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            for k in max(0, index - context)...min(raw.count - 1, index + context) { keep.insert(k) }
        }
        var out: [DiffLine] = []
        var lastKept = -1
        for index in raw.indices where keep.contains(index) {
            if index > lastKept + 1 {
                out.append(DiffLine(kind: .gap, text: "…", number: nil, id: out.count))
            }
            out.append(DiffLine(kind: raw[index].0, text: raw[index].1, number: raw[index].2, id: out.count))
            lastKept = index
        }
        if lastKept < raw.count - 1 {
            out.append(DiffLine(kind: .gap, text: "…", number: nil, id: out.count))
        }
        return out
    }

    static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var result = text.components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result
    }

    /// Classic LCS table. Inputs are the changed middle only.
    static func lcs(_ a: [String], _ b: [String]) -> [(DiffLine.Kind, String, Int?)] {
        if a.isEmpty { return b.enumerated().map { (.added, $0.element, $0.offset) } }
        if b.isEmpty { return a.enumerated().map { (.removed, $0.element, $0.offset) } }
        // Large changed blocks: show as remove then add, no table.
        if a.count * b.count > 4_000_000 {
            return a.enumerated().map { (.removed, $0.element, $0.offset) } + b.enumerated().map { (.added, $0.element, $0.offset) }
        }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0
        var out: [(DiffLine.Kind, String, Int?)] = []
        while i < a.count, j < b.count {
            if a[i] == b[j] { out.append((.same, b[j], j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { out.append((.removed, a[i], i)); i += 1 }
            else { out.append((.added, b[j], j)); j += 1 }
        }
        while i < a.count { out.append((.removed, a[i], i)); i += 1 }
        while j < b.count { out.append((.added, b[j], j)); j += 1 }
        return out
    }
}
