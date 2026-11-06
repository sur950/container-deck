import Foundation

/// An ordered JSON value. Used to write new config entries with keys in a stable order.
public indirect enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// Pretty JSON text. `indent` is one level, `level` the depth of this value.
    public func render(indent: String = "  ", level: Int = 0) -> String {
        let pad = String(repeating: indent, count: level)
        let inner = String(repeating: indent, count: level + 1)
        switch self {
        case .string(let s): return JSONValue.quote(s)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            if items.isEmpty { return "[]" }
            if items.allSatisfy({ if case .string = $0 { return true }; if case .number = $0 { return true }; return false }) {
                let flat = "[" + items.map { $0.render() }.joined(separator: ", ") + "]"
                if flat.count <= 80 { return flat }
            }
            return "[\n" + items.map { inner + $0.render(indent: indent, level: level + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            return "{\n" + members.map { inner + JSONValue.quote($0.0) + ": " + $0.1.render(indent: indent, level: level + 1) }
                .joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

public enum JSONCError: Error, LocalizedError, Equatable {
    case syntax(String, line: Int)
    case notAnObject(String)

    public var errorDescription: String? {
        switch self {
        case let .syntax(message, line): return "The file is not valid JSON (line \(line)): \(message)"
        case let .notAnObject(path): return "\(path) is not an object in this file."
        }
    }
}

/// Edits JSON and JSON with comments (VS Code settings) without reformatting.
/// Only the bytes of the member being added, replaced or removed change.
/// Unknown keys, comments, key order and spacing elsewhere stay exactly as they were.
public struct JSONCEditor: Sendable {
    public private(set) var text: String

    public init(text: String) {
        self.text = text
    }

    // MARK: Reading

    /// Parses the file into plain Foundation values (comments and trailing commas allowed).
    /// An empty file reads as an empty object.
    public func foundationValue() throws -> Any {
        let bytes = Array(text.utf8)
        if JSONCEditor.isBlank(bytes) { return [String: Any]() }
        var parser = Parser(bytes: bytes)
        let node = try parser.parseDocument()
        return node.foundation(bytes)
    }

    /// The object at a key path, or nil when it is missing or not an object.
    public func object(at path: [String]) throws -> [String: Any]? {
        var current: Any = try foundationValue()
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current as? [String: Any]
    }

    // MARK: Editing

    /// Sets `key` inside the object at `path` to `value`. Missing objects on the path are created.
    public mutating func set(_ value: JSONValue, forKey key: String, in path: [String]) throws {
        var bytes = Array(text.utf8)
        if JSONCEditor.isBlank(bytes) {
            // Start a new file with one top level object.
            var nested: JSONValue = .object([(key, value)])
            for parent in path.reversed() { nested = .object([(parent, nested)]) }
            text = nested.render(indent: "  ") + "\n"
            return
        }
        var parser = Parser(bytes: bytes)
        let root = try parser.parseDocument()
        let unit = JSONCEditor.indentUnit(bytes)

        // Walk down as far as the path exists.
        var object = root
        var depth = 0
        while depth < path.count {
            guard case .object(let members, _, _) = object.kind else {
                throw JSONCError.notAnObject(path.prefix(depth).joined(separator: "."))
            }
            guard let member = members.first(where: { $0.key == path[depth] }) else { break }
            object = member.value
            depth += 1
        }
        guard case .object(let members, let open, let close) = object.kind else {
            throw JSONCError.notAnObject(path.prefix(depth).joined(separator: ".").isEmpty ? "The top level" : path.prefix(depth).joined(separator: "."))
        }

        // What to place inside `object`: either the final key, or the missing rest of the path.
        var newKey = key
        var newValue = value
        if depth < path.count {
            var nested: JSONValue = .object([(key, value)])
            for parent in path[(depth + 1)...].reversed() { nested = .object([(parent, nested)]) }
            newKey = path[depth]
            newValue = nested
        }

        let baseIndent = JSONCEditor.lineIndent(bytes, at: object.start)
        let level = JSONCEditor.level(of: baseIndent, unit: unit)

        if depth == path.count, let existing = members.first(where: { $0.key == newKey }) {
            // Replace only the value bytes.
            let memberIndent = JSONCEditor.lineIndent(bytes, at: existing.keyStart)
            let memberLevel = JSONCEditor.level(of: memberIndent, unit: unit)
            let rendered = newValue.render(indent: unit, level: memberLevel)
            bytes.replaceSubrange(existing.value.start..<existing.value.end, with: Array(rendered.utf8))
        } else if let last = members.last {
            let memberIndent = JSONCEditor.lineIndent(bytes, at: last.keyStart)
            let sameLine = JSONCEditor.isSameLine(bytes, object.start, last.keyStart)
            let indentText = sameLine ? String(repeating: unit, count: level + 1) : memberIndent
            let memberLevel = JSONCEditor.level(of: indentText, unit: unit)
            let rendered = JSONValue.quote(newKey) + ": " + newValue.render(indent: unit, level: memberLevel)
            // Insert after the last value. A trailing comma (JSONC) then follows our new member.
            let insertion = ",\n" + indentText + rendered
            bytes.insert(contentsOf: Array(insertion.utf8), at: last.value.end)
        } else {
            // Empty object: replace what is between the braces (only whitespace or comments).
            let inner = String(repeating: unit, count: level + 1)
            let rendered = "\n" + inner + JSONValue.quote(newKey) + ": " + newValue.render(indent: unit, level: level + 1) + "\n" + baseIndent
            let between = Array(bytes[(open + 1)..<close])
            if JSONCEditor.containsComment(between) {
                bytes.insert(contentsOf: Array(rendered.dropLast(baseIndent.count + 1).utf8), at: open + 1)
            } else {
                bytes.replaceSubrange((open + 1)..<close, with: Array(rendered.utf8))
            }
        }
        text = String(decoding: bytes, as: UTF8.self)
    }

    /// Removes `key` from the object at `path`. Returns false when it was not there.
    @discardableResult
    public mutating func remove(key: String, in path: [String]) throws -> Bool {
        var bytes = Array(text.utf8)
        if JSONCEditor.isBlank(bytes) { return false }
        var parser = Parser(bytes: bytes)
        var object = try parser.parseDocument()
        for part in path {
            guard case .object(let members, _, _) = object.kind,
                  let member = members.first(where: { $0.key == part }) else { return false }
            object = member.value
        }
        guard case .object(let members, let open, let close) = object.kind,
              let index = members.firstIndex(where: { $0.key == key }) else { return false }
        let member = members[index]
        let range: Range<Int>
        if members.count == 1 {
            let between = Array(bytes[(open + 1)..<close])
            if JSONCEditor.containsComment(between) {
                // Keep comments: remove only this member and a comma after it.
                var end = member.value.end
                if let comma = JSONCEditor.nextComma(bytes, from: end, before: close) { end = comma + 1 }
                range = JSONCEditor.lineStart(bytes, member.keyStart)..<end
            } else {
                range = (open + 1)..<close
            }
        } else if index < members.count - 1 {
            // From the start of this member's line through its comma and the rest of that line.
            let from = JSONCEditor.lineStartIfOnlyWhitespace(bytes, member.keyStart)
            var to = (JSONCEditor.nextComma(bytes, from: member.value.end, before: close) ?? (member.value.end - 1)) + 1
            var probe = to
            while probe < bytes.count, bytes[probe] == 0x20 || bytes[probe] == 0x09 { probe += 1 }
            if probe < bytes.count, bytes[probe] == 0x0A { to = probe + 1 } else if probe < bytes.count, bytes[probe] == 0x0D { to = min(probe + 2, bytes.count) }
            range = (from == member.keyStart ? from : from)..<max(to, from)
        } else {
            // Last member: from the end of the previous value, which takes the comma before it.
            let previous = members[index - 1]
            range = previous.value.end..<member.value.end
        }
        bytes.removeSubrange(range)
        text = String(decoding: bytes, as: UTF8.self)
        return true
    }

    // MARK: Helpers

    static func isBlank(_ bytes: [UInt8]) -> Bool {
        var parser = Parser(bytes: bytes)
        parser.skipTrivia()
        return parser.pos >= bytes.count
    }

    /// Indent of the line that holds `offset`.
    static func lineIndent(_ bytes: [UInt8], at offset: Int) -> String {
        let start = lineStart(bytes, offset)
        var end = start
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    static func lineStart(_ bytes: [UInt8], _ offset: Int) -> Int {
        var i = min(offset, bytes.count)
        while i > 0, bytes[i - 1] != 0x0A { i -= 1 }
        return i
    }

    /// Start of the line when only spaces come before `offset` on it, else `offset`.
    static func lineStartIfOnlyWhitespace(_ bytes: [UInt8], _ offset: Int) -> Int {
        let start = lineStart(bytes, offset)
        return bytes[start..<offset].allSatisfy { $0 == 0x20 || $0 == 0x09 } ? start : offset
    }

    static func isSameLine(_ bytes: [UInt8], _ a: Int, _ b: Int) -> Bool {
        !bytes[min(a, b)..<max(a, b)].contains(0x0A)
    }

    static func nextComma(_ bytes: [UInt8], from: Int, before limit: Int) -> Int? {
        var parser = Parser(bytes: bytes)
        parser.pos = from
        parser.skipTrivia()
        return parser.pos < limit && bytes[parser.pos] == UInt8(ascii: ",") ? parser.pos : nil
    }

    /// True when the bytes hold a // or /* comment outside strings.
    static func containsComment(_ bytes: [UInt8]) -> Bool {
        var i = 0
        var inString = false
        while i < bytes.count {
            let c = bytes[i]
            if inString {
                if c == UInt8(ascii: "\\") { i += 1 } else if c == UInt8(ascii: "\"") { inString = false }
            } else if c == UInt8(ascii: "\"") {
                inString = true
            } else if c == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "/") || bytes[i + 1] == UInt8(ascii: "*") {
                return true
            }
            i += 1
        }
        return false
    }

    /// One indent level as used by the file (first indented line), two spaces by default.
    static func indentUnit(_ bytes: [UInt8]) -> String {
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A, i + 1 < bytes.count {
                var j = i + 1
                while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
                if j > i + 1, j < bytes.count, bytes[j] != 0x0A {
                    let indent = String(decoding: bytes[(i + 1)..<j], as: UTF8.self)
                    if indent.hasPrefix("\t") { return "\t" }
                    return indent.count >= 2 && indent.count <= 8 ? indent : "  "
                }
            }
            i += 1
        }
        return "  "
    }

    static func level(of indent: String, unit: String) -> Int {
        guard !unit.isEmpty else { return 0 }
        return indent.count / unit.count
    }
}

// MARK: - Parser with byte ranges

struct JSONNode {
    enum Kind {
        case object([JSONMember], open: Int, close: Int)
        case array([JSONNode])
        case string(String)
        case scalar
    }
    var kind: Kind
    var start: Int
    var end: Int

    func foundation(_ bytes: [UInt8]) -> Any {
        switch kind {
        case .object(let members, _, _):
            var dict: [String: Any] = [:]
            for member in members { dict[member.key] = member.value.foundation(bytes) }
            return dict
        case .array(let items): return items.map { $0.foundation(bytes) }
        case .string(let s): return s
        case .scalar:
            let raw = String(decoding: bytes[start..<end], as: UTF8.self)
            switch raw {
            case "true": return true
            case "false": return false
            case "null": return NSNull()
            default: return Double(raw).map { $0.rounded() == $0 && abs($0) < 1e15 ? Int($0) as Any : $0 as Any } ?? raw
            }
        }
    }
}

struct JSONMember {
    var key: String
    var keyStart: Int
    var value: JSONNode
}

struct Parser {
    let bytes: [UInt8]
    var pos = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        // Skip a UTF-8 byte order mark.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { pos = 3 }
    }

    mutating func parseDocument() throws -> JSONNode {
        skipTrivia()
        let node = try parseValue()
        skipTrivia()
        if pos < bytes.count { throw error("Unexpected text after the end") }
        return node
    }

    func error(_ message: String) -> JSONCError {
        let line = bytes[..<min(pos, bytes.count)].filter { $0 == 0x0A }.count + 1
        return .syntax(message, line: line)
    }

    mutating func skipTrivia() {
        while pos < bytes.count {
            let c = bytes[pos]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                pos += 1
            } else if c == UInt8(ascii: "/"), pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "/") {
                while pos < bytes.count, bytes[pos] != 0x0A { pos += 1 }
            } else if c == UInt8(ascii: "/"), pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "*") {
                pos += 2
                while pos + 1 < bytes.count, !(bytes[pos] == UInt8(ascii: "*") && bytes[pos + 1] == UInt8(ascii: "/")) { pos += 1 }
                pos = min(pos + 2, bytes.count)
            } else {
                return
            }
        }
    }

    mutating func parseValue() throws -> JSONNode {
        guard pos < bytes.count else { throw error("Unexpected end of file") }
        let start = pos
        switch bytes[pos] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["):
            pos += 1
            var items: [JSONNode] = []
            skipTrivia()
            while pos < bytes.count, bytes[pos] != UInt8(ascii: "]") {
                items.append(try parseValue())
                skipTrivia()
                if pos < bytes.count, bytes[pos] == UInt8(ascii: ",") { pos += 1; skipTrivia() }
                else if pos < bytes.count, bytes[pos] != UInt8(ascii: "]") { throw error("Expected , or ]") }
            }
            guard pos < bytes.count else { throw error("Missing ]") }
            pos += 1
            return JSONNode(kind: .array(items), start: start, end: pos)
        case UInt8(ascii: "\""):
            let s = try parseString()
            return JSONNode(kind: .string(s), start: start, end: pos)
        default:
            while pos < bytes.count {
                let c = bytes[pos]
                let isScalar = (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
                    || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")
                if !isScalar { break }
                pos += 1
            }
            if pos == start { throw error("Unexpected character") }
            return JSONNode(kind: .scalar, start: start, end: pos)
        }
    }

    mutating func parseObject() throws -> JSONNode {
        let open = pos
        pos += 1
        var members: [JSONMember] = []
        skipTrivia()
        while pos < bytes.count, bytes[pos] != UInt8(ascii: "}") {
            guard bytes[pos] == UInt8(ascii: "\"") else { throw error("Expected a key in quotes") }
            let keyStart = pos
            let key = try parseString()
            skipTrivia()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw error("Expected :") }
            pos += 1
            skipTrivia()
            let value = try parseValue()
            members.append(JSONMember(key: key, keyStart: keyStart, value: value))
            skipTrivia()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: ",") { pos += 1; skipTrivia() }
            else if pos < bytes.count, bytes[pos] != UInt8(ascii: "}") { throw error("Expected , or }") }
        }
        guard pos < bytes.count else { throw error("Missing }") }
        let close = pos
        pos += 1
        return JSONNode(kind: .object(members, open: open, close: close), start: open, end: pos)
    }

    mutating func parseString() throws -> String {
        let start = pos
        pos += 1
        var escaped = false
        while pos < bytes.count {
            let c = bytes[pos]
            if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") { break }
            pos += 1
        }
        guard pos < bytes.count else { throw error("Unclosed string") }
        pos += 1
        let raw = Array(bytes[start..<pos])
        if !raw.contains(UInt8(ascii: "\\")) {
            return String(decoding: raw.dropFirst().dropLast(), as: UTF8.self)
        }
        let data = Data(raw)
        if let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return decoded
        }
        return String(decoding: raw.dropFirst().dropLast(), as: UTF8.self)
    }
}
