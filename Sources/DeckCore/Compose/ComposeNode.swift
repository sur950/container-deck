import Foundation
import Yams

/// A small YAML tree built once from Yams nodes. Keeps line numbers, applies
/// `<<` merge keys and fills in variables, so the parser never touches Yams.
struct ComposeNode {
    enum Value {
        case scalar(String, isNull: Bool)
        case map([ComposeEntry])
        case list([ComposeNode])
    }

    /// `!reset` and `!override` from Compose 2.24. Only used while files merge.
    enum Tag: Equatable {
        case reset
        case override
    }

    var value: Value
    /// 1 based line, 0 when unknown. In a project made of several files the line
    /// also carries the file (see `ComposeSources`).
    var line: Int
    var tag: Tag?

    init(value: Value, line: Int, tag: Tag? = nil) {
        self.value = value
        self.line = line
        self.tag = tag
    }

    var isNull: Bool {
        if case .scalar(_, let isNull) = value { return isNull }
        return false
    }

    /// Text of a scalar. nil for null, maps and lists.
    var text: String? {
        if case .scalar(let text, let isNull) = value, !isNull { return text }
        return nil
    }

    var entries: [ComposeEntry]? {
        if case .map(let entries) = value { return entries }
        return nil
    }

    var items: [ComposeNode]? {
        if case .list(let items) = value { return items }
        return nil
    }

    subscript(key: String) -> ComposeNode? {
        entries?.first { $0.key == key }?.node
    }

    func entry(_ key: String) -> ComposeEntry? {
        entries?.first { $0.key == key }
    }

    var bool: Bool? {
        guard let text = text?.lowercased() else { return nil }
        switch text {
        case "true", "yes", "on", "y": return true
        case "false", "no", "off", "n": return false
        default: return nil
        }
    }

    var int: Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Int(text)
    }

    /// A list of scalars, or one scalar as a list of one.
    var stringList: [String]? {
        if let text { return [text] }
        if let items { return items.compactMap(\.text) }
        return nil
    }

    /// `KEY: value` maps and `KEY=value` lists. A nil value means "not set here".
    var keyValues: [(key: String, value: String?, line: Int)]? {
        if let entries {
            return entries.map { (entry: ComposeEntry) -> (key: String, value: String?, line: Int) in
                (key: entry.key, value: entry.node.text, line: entry.line)
            }
        }
        if let items {
            return items.compactMap { (item: ComposeNode) -> (key: String, value: String?, line: Int)? in
                guard let text = item.text else { return nil }
                if let eq = text.firstIndex(of: "=") {
                    return (key: String(text[..<eq]), value: String(text[text.index(after: eq)...]), line: item.line)
                }
                return (key: text, value: nil, line: item.line)
            }
        }
        return nil
    }
}

struct ComposeEntry {
    var key: String
    /// Line of the key.
    var line: Int
    var node: ComposeNode
}

/// Turns a Yams node into a ComposeNode.
struct ComposeNodeBuilder {
    let interpolator: ComposeInterpolator
    /// Added to every line, so lines from several files stay apart.
    let lineOffset: Int
    private(set) var errors: [(line: Int, message: String)] = []

    init(interpolator: ComposeInterpolator, lineOffset: Int = 0) {
        self.interpolator = interpolator
        self.lineOffset = lineOffset
    }

    /// Parses YAML text. Returns nil for an empty file.
    static func parse(_ yaml: String, interpolator: ComposeInterpolator, lineOffset: Int = 0) throws -> (node: ComposeNode?, errors: [(line: Int, message: String)]) {
        let composed: Node?
        do {
            composed = try Yams.compose(yaml: yaml)
        } catch {
            // Keep the line and column so the screen can point at the place.
            if let issue = ComposeYAMLIssue.from(error) {
                throw ComposeError.invalidYAML(issue.message)
            }
            throw ComposeError.invalidYAML(String(describing: error))
        }
        guard let root = composed else { return (nil, []) }
        var builder = ComposeNodeBuilder(interpolator: interpolator, lineOffset: lineOffset)
        let node = builder.build(root)
        return (node, builder.errors)
    }

    private func place(_ mark: Mark?) -> Int {
        guard let line = mark?.line, line > 0 else { return 0 }
        return line + lineOffset
    }

    private static func tag(_ node: Node) -> ComposeNode.Tag? {
        switch node.tag.rawValue {
        case "!reset": return .reset
        case "!override": return .override
        default: return nil
        }
    }

    mutating func build(_ node: Node) -> ComposeNode {
        var result = buildValue(node)
        result.tag = Self.tag(node)
        return result
    }

    private mutating func buildValue(_ node: Node) -> ComposeNode {
        let line = place(node.mark)

        // The value under !reset is ignored, so it is not filled in.
        if Self.tag(node) == .reset {
            return ComposeNode(value: .scalar("", isNull: true), line: line)
        }

        if let mapping = node.mapping {
            var entries: [ComposeEntry] = []
            var merged: [ComposeEntry] = []
            for pair in mapping {
                let key = pair.key.scalar?.string ?? ""
                let child = build(pair.value)
                if key == "<<" {
                    // YAML merge key: the first source wins, explicit keys win over all.
                    if let mergedEntries = child.entries {
                        merged.append(contentsOf: mergedEntries)
                    } else if let list = child.items {
                        for item in list {
                            if let mergedEntries = item.entries { merged.append(contentsOf: mergedEntries) }
                        }
                    }
                    continue
                }
                let keyLine = pair.key.mark == nil ? line : place(pair.key.mark)
                entries.append(ComposeEntry(key: key, line: keyLine, node: child))
            }
            for item in merged {
                if !entries.contains(where: { $0.key == item.key }) {
                    entries.append(item)
                }
            }
            return ComposeNode(value: .map(entries), line: line)
        }

        if let sequence = node.sequence {
            var items: [ComposeNode] = []
            for child in sequence {
                items.append(build(child))
            }
            return ComposeNode(value: .list(items), line: line)
        }

        let scalar = node.scalar
        let raw = scalar?.string ?? ""
        let isPlain = scalar?.style == .plain || scalar?.style == .any
        let isNull = isPlain && ["", "~", "null", "Null", "NULL"].contains(raw)
        if isNull {
            return ComposeNode(value: .scalar("", isNull: true), line: line)
        }
        let result = interpolator.interpolate(raw)
        for message in result.errors {
            errors.append((line, message))
        }
        return ComposeNode(value: .scalar(result.text, isNull: false), line: line)
    }
}

extension ComposeNode {
    /// Same value, ignoring lines and tags. Used to drop exact duplicates in merges.
    func sameValue(as other: ComposeNode) -> Bool {
        switch (value, other.value) {
        case let (.scalar(a, aNull), .scalar(b, bNull)):
            return aNull == bNull && a == b
        case let (.list(a), .list(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.sameValue(as: $1) }
        case let (.map(a), .map(b)):
            guard a.count == b.count else { return false }
            return a.allSatisfy { entry in
                b.contains { $0.key == entry.key && $0.node.sameValue(as: entry.node) }
            }
        default:
            return false
        }
    }

    /// A copy with `!reset` values removed and tags cleared, all the way down.
    func cleaned() -> ComposeNode {
        var copy = self
        copy.tag = nil
        switch value {
        case .scalar:
            break
        case .list(let items):
            copy.value = .list(items.filter { $0.tag != .reset }.map { $0.cleaned() })
        case .map(let entries):
            copy.value = .map(entries.filter { $0.node.tag != .reset }.map { entry in
                var entry = entry
                entry.node = entry.node.cleaned()
                return entry
            })
        }
        return copy
    }

    static func null(line: Int) -> ComposeNode {
        ComposeNode(value: .scalar("", isNull: true), line: line)
    }

    static func scalar(_ text: String, line: Int) -> ComposeNode {
        ComposeNode(value: .scalar(text, isNull: false), line: line)
    }
}
