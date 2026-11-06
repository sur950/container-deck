import Foundation

/// Small TOML value used for the Codex `[mcp_servers.<name>]` tables.
public enum TOMLValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var arrayValue: [TOMLValue]? { if case .array(let a) = self { return a }; return nil }
    public var tableValue: [String: TOMLValue]? { if case .table(let t) = self { return t }; return nil }
}

/// Reads the MCP tables of a Codex config and edits one `[mcp_servers.<name>]` table at a time.
/// Edits touch only the lines of that table (and its sub tables). Everything else stays byte for byte.
public struct TOMLEditor: Sendable {
    public private(set) var text: String

    public init(text: String) {
        self.text = text
    }

    // MARK: Lines and headers

    struct Header {
        var path: [String]
        var line: Int
    }

    /// Splits into lines (keeping newlines) and finds every table header outside multi line values.
    func scan() -> (lines: [String], headers: [Header]) {
        var lines: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "\n" || ch == "\r\n" { lines.append(current); current = "" }
        }
        if !current.isEmpty { lines.append(current) }

        var headers: [Header] = []
        var inMultiline: String?   // closing delimiter of a multi line string
        var bracketDepth = 0       // open [ or { of a value that spans lines
        for (index, line) in lines.enumerated() {
            if let closing = inMultiline {
                if line.contains(closing) { inMultiline = nil }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if bracketDepth == 0, trimmed.hasPrefix("["), !trimmed.hasPrefix("[[") {
                if let path = TOMLEditor.parseHeader(trimmed) {
                    headers.append(Header(path: path, line: index))
                    continue
                }
            }
            if bracketDepth == 0, trimmed.hasPrefix("[[") {
                headers.append(Header(path: ["[["], line: index))
                continue
            }
            // Track multi line strings and arrays opened on a key line.
            let (depthChange, opensMultiline) = TOMLEditor.lineEffects(line)
            if let opensMultiline { inMultiline = opensMultiline }
            bracketDepth = max(0, bracketDepth + depthChange)
        }
        return (lines, headers)
    }

    /// Change in bracket depth on a line and a multi line string it leaves open.
    static func lineEffects(_ line: String) -> (Int, String?) {
        var depth = 0
        var chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "#" { break }
            if c == "\"" || c == "'" {
                let triple = i + 2 < chars.count && chars[i + 1] == c && chars[i + 2] == c
                if triple {
                    let delimiter = String(repeating: String(c), count: 3)
                    let rest = String(chars[(i + 3)...])
                    if let range = rest.range(of: delimiter) {
                        i += 3 + rest.distance(from: rest.startIndex, to: range.upperBound)
                        continue
                    }
                    return (depth, delimiter)
                }
                i += 1
                while i < chars.count, chars[i] != c {
                    if c == "\"", chars[i] == "\\" { i += 1 }
                    i += 1
                }
                i += 1
                continue
            }
            if c == "[" || c == "{" { depth += 1 }
            if c == "]" || c == "}" { depth -= 1 }
            i += 1
        }
        chars.removeAll()
        return (depth, nil)
    }

    /// `[a.b."c d"]` to ["a", "b", "c d"]. nil when the line is not a header.
    static func parseHeader(_ trimmed: String) -> [String]? {
        guard trimmed.hasPrefix("[") else { return nil }
        var scanner = KeyScanner(Array(trimmed.dropFirst()))
        guard let keys = scanner.dottedKey() else { return nil }
        scanner.skipSpaces()
        guard scanner.peek == "]" else { return nil }
        return keys
    }

    // MARK: Reading

    /// Every `[mcp_servers.<name>]` server with its keys (sub tables like `env` included as tables).
    /// Also reads `[mcp_servers]` with inline tables per server.
    public func mcpServers() -> [(name: String, values: [String: TOMLValue])] {
        let (lines, headers) = scan()
        var order: [String] = []
        var servers: [String: [String: TOMLValue]] = [:]
        func add(_ name: String) { if servers[name] == nil { servers[name] = [:]; order.append(name) } }

        for (h, header) in headers.enumerated() where header.path.first == "mcp_servers" {
            let end = h + 1 < headers.count ? headers[h + 1].line : lines.count
            let body = Array(lines[(header.line + 1)..<end])
            let pairs = TOMLEditor.parsePairs(body)
            switch header.path.count {
            case 1:
                for (key, value) in pairs {
                    if case .table(let t) = value { add(key); servers[key]?.merge(t) { $1 } }
                }
            case 2:
                let name = header.path[1]
                add(name)
                for (key, value) in pairs { servers[name]?[key] = value }
            default:
                let name = header.path[1]
                add(name)
                var table: [String: TOMLValue] = [:]
                for (key, value) in pairs { table[key] = value }
                servers[name]?[header.path[2...].joined(separator: ".")] = .table(table)
            }
        }
        return order.map { ($0, servers[$0] ?? [:]) }
    }

    /// key = value pairs of a table body. Lines it cannot read are skipped.
    static func parsePairs(_ lines: [String]) -> [(String, TOMLValue)] {
        let joined = lines.joined()
        var scanner = ValueScanner(Array(joined))
        var pairs: [(String, TOMLValue)] = []
        while !scanner.atEnd {
            scanner.skipTrivia()
            if scanner.atEnd { break }
            let lineStart = scanner.index
            var keyScanner = KeyScanner(Array(scanner.chars[scanner.index...]))
            if let keys = keyScanner.dottedKey() {
                scanner.index += keyScanner.index
                scanner.skipSpaces()
                if scanner.peek == "=" {
                    scanner.index += 1
                    scanner.skipSpaces()
                    if let value = scanner.value() {
                        var stored = value
                        for key in keys.dropFirst().reversed() { stored = .table([key: stored]) }
                        pairs.append((keys[0], stored))
                    }
                }
            }
            scanner.skipToNextLine()
            if scanner.index == lineStart { scanner.index += 1 }
        }
        return pairs
    }

    // MARK: Editing

    /// Line range of `[mcp_servers.<name>]` and each `[mcp_servers.<name>.*]` sub table.
    func tableRanges(for name: String, lines: [String], headers: [Header]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for (h, header) in headers.enumerated() where header.path.count >= 2 && header.path[0] == "mcp_servers" && header.path[1] == name {
            var end = h + 1 < headers.count ? headers[h + 1].line : lines.count
            // Leave comment lines that sit right above the next header with that header.
            while end > header.line + 1 {
                let trimmed = lines[end - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("#") { end -= 1 } else { break }
            }
            ranges.append(header.line..<end)
        }
        return ranges
    }

    public func hasServer(_ name: String) -> Bool {
        let (lines, headers) = scan()
        return !tableRanges(for: name, lines: lines, headers: headers).isEmpty
    }

    /// Adds or replaces `[mcp_servers.<name>]`. The table is rewritten in place, or appended at the end.
    public mutating func setServer(_ name: String, values: [(String, TOMLValue)]) {
        var (lines, headers) = scan()
        let ranges = tableRanges(for: name, lines: lines, headers: headers)
        var block = "[mcp_servers.\(TOMLEditor.key(name))]\n"
        for (key, value) in values {
            block += "\(TOMLEditor.key(key)) = \(TOMLEditor.render(value))\n"
        }
        if let first = ranges.first {
            // Keep blank lines that end the old table so spacing stays the same.
            var trailing = ""
            var cursor = first.upperBound
            while cursor > first.lowerBound + 1, lines[cursor - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                trailing = lines[cursor - 1] + trailing
                cursor -= 1
            }
            for range in ranges.dropFirst().reversed() { lines.removeSubrange(range) }
            lines.replaceSubrange(first, with: [block + trailing])
            text = lines.joined()
        } else {
            var result = text
            if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
            if !result.isEmpty, !result.hasSuffix("\n\n") { result += "\n" }
            text = result + block
        }
        headers.removeAll()
    }

    /// Removes `[mcp_servers.<name>]` and its sub tables. Returns false when it was not there.
    @discardableResult
    public mutating func removeServer(_ name: String) -> Bool {
        var (lines, headers) = scan()
        let ranges = tableRanges(for: name, lines: lines, headers: headers)
        guard !ranges.isEmpty else { return false }
        for range in ranges.reversed() {
            var upper = range.upperBound
            // Take one blank line after the table with it.
            if upper < lines.count, lines[upper].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               range.lowerBound > 0, lines[range.lowerBound - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                upper += 1
            }
            lines.removeSubrange(range.lowerBound..<upper)
        }
        headers.removeAll()
        var result = lines.joined()
        while result.hasSuffix("\n\n") { result.removeLast() }
        text = result
        return true
    }

    // MARK: Rendering

    static func key(_ key: String) -> String {
        let bare = !key.isEmpty && key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-"
        }
        return bare ? key : quote(key)
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func render(_ value: TOMLValue) -> String {
        switch value {
        case .string(let s): return quote(s)
        case .integer(let i): return String(i)
        case .float(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .array(let items): return "[" + items.map(render).joined(separator: ", ") + "]"
        case .table(let t):
            if t.isEmpty { return "{}" }
            return "{ " + t.sorted { $0.key < $1.key }.map { "\(key($0.key)) = \(render($0.value))" }.joined(separator: ", ") + " }"
        }
    }
}

// MARK: - Scanners

struct KeyScanner {
    let chars: [Character]
    var index = 0

    init(_ chars: [Character]) { self.chars = chars }

    var peek: Character? { index < chars.count ? chars[index] : nil }

    mutating func skipSpaces() {
        while let c = peek, c == " " || c == "\t" { index += 1 }
    }

    mutating func dottedKey() -> [String]? {
        var keys: [String] = []
        while true {
            skipSpaces()
            guard let part = simpleKey() else { return keys.isEmpty ? nil : nil }
            keys.append(part)
            skipSpaces()
            if peek == "." { index += 1 } else { break }
        }
        return keys
    }

    mutating func simpleKey() -> String? {
        guard let c = peek else { return nil }
        if c == "\"" || c == "'" {
            index += 1
            var out = ""
            while let ch = peek, ch != c {
                if c == "\"", ch == "\\", index + 1 < chars.count {
                    index += 1
                    out.append(ValueScanner.unescape(chars[index]))
                } else {
                    out.append(ch)
                }
                index += 1
            }
            guard peek == c else { return nil }
            index += 1
            return out
        }
        var out = ""
        while let ch = peek, ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
            out.append(ch)
            index += 1
        }
        return out.isEmpty ? nil : out
    }
}

struct ValueScanner {
    let chars: [Character]
    var index = 0

    init(_ chars: [Character]) { self.chars = chars }

    var atEnd: Bool { index >= chars.count }
    var peek: Character? { index < chars.count ? chars[index] : nil }

    static func unescape(_ c: Character) -> Character {
        switch c {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        default: return c
        }
    }

    mutating func skipSpaces() {
        while let c = peek, c == " " || c == "\t" { index += 1 }
    }

    /// Spaces, newlines and comments.
    mutating func skipTrivia() {
        while let c = peek {
            if c == " " || c == "\t" || c == "\n" || c == "\r\n" || c == "\r" { index += 1 }
            else if c == "#" { while let d = peek, d != "\n", d != "\r\n" { index += 1 } }
            else { return }
        }
    }

    mutating func skipToNextLine() {
        while let c = peek, c != "\n", c != "\r\n" { index += 1 }
        if peek != nil { index += 1 }
    }

    mutating func value() -> TOMLValue? {
        guard let c = peek else { return nil }
        switch c {
        case "\"", "'":
            return string().map { .string($0) }
        case "[":
            index += 1
            var items: [TOMLValue] = []
            while true {
                skipTrivia()
                if peek == "]" { index += 1; break }
                guard let item = value() else { return nil }
                items.append(item)
                skipTrivia()
                if peek == "," { index += 1 } else if peek == "]" { index += 1; break } else { return nil }
            }
            return .array(items)
        case "{":
            index += 1
            var table: [String: TOMLValue] = [:]
            while true {
                skipSpaces()
                if peek == "}" { index += 1; break }
                var keyScanner = KeyScanner(Array(chars[index...]))
                guard let keys = keyScanner.dottedKey() else { return nil }
                index += keyScanner.index
                skipSpaces()
                guard peek == "=" else { return nil }
                index += 1
                skipSpaces()
                guard var item = value() else { return nil }
                for key in keys.dropFirst().reversed() { item = .table([key: item]) }
                table[keys[0]] = item
                skipSpaces()
                if peek == "," { index += 1 } else if peek == "}" { index += 1; break } else { return nil }
            }
            return .table(table)
        default:
            var raw = ""
            while let ch = peek, !(ch == "," || ch == "]" || ch == "}" || ch == "\n" || ch == "\r\n" || ch == "#" || ch == " " || ch == "\t") {
                raw.append(ch)
                index += 1
            }
            if raw == "true" { return .bool(true) }
            if raw == "false" { return .bool(false) }
            let digits = raw.replacingOccurrences(of: "_", with: "")
            if let i = Int(digits) { return .integer(i) }
            if let d = Double(digits) { return .float(d) }
            return raw.isEmpty ? nil : .string(raw)
        }
    }

    mutating func string() -> String? {
        guard let quote = peek else { return nil }
        let triple = index + 2 < chars.count && chars[index + 1] == quote && chars[index + 2] == quote
        if triple {
            index += 3
            if peek == "\n" || peek == "\r\n" { index += 1 }
            var out = ""
            while index + 2 < chars.count || index < chars.count {
                if index + 2 < chars.count, chars[index] == quote, chars[index + 1] == quote, chars[index + 2] == quote {
                    index += 3
                    return out
                }
                if quote == "\"", chars[index] == "\\", index + 1 < chars.count {
                    index += 1
                    out.append(ValueScanner.unescape(chars[index]))
                } else {
                    out.append(chars[index])
                }
                index += 1
            }
            return nil
        }
        index += 1
        var out = ""
        while let ch = peek, ch != quote {
            if quote == "\"", ch == "\\", index + 1 < chars.count {
                index += 1
                let escaped = chars[index]
                if escaped == "u" || escaped == "U" {
                    let count = escaped == "u" ? 4 : 8
                    let end = min(index + 1 + count, chars.count)
                    let hex = String(chars[(index + 1)..<end])
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
                    index = end - 1
                } else {
                    out.append(ValueScanner.unescape(escaped))
                }
            } else {
                out.append(ch)
            }
            index += 1
        }
        guard peek == quote else { return nil }
        index += 1
        return out
    }
}
