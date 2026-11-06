import Foundation

/// Replaces ${VAR}, ${VAR:-default}, ${VAR-default}, ${VAR:?error}, ${VAR?error},
/// ${VAR:+other}, ${VAR+other} and $VAR. `$$` becomes a single `$`.
public struct ComposeInterpolator: Sendable {
    public var values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }

    /// Values from a `.env` file next to the compose file, then the process
    /// environment on top (the process wins, like Docker).
    public static func environment(dotEnv: [String: String], process: [String: String]) -> [String: String] {
        dotEnv.merging(process) { _, fromProcess in fromProcess }
    }

    public struct Result: Sendable, Equatable {
        public var text: String
        /// Messages for required values that are missing or bad syntax.
        public var errors: [String]
    }

    public func interpolate(_ input: String) -> Result {
        guard input.contains("$") else { return Result(text: input, errors: []) }
        var output = ""
        var errors: [String] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "$" else {
                output.append(c)
                i += 1
                continue
            }
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if next == "$" {
                output.append("$")
                i += 2
            } else if next == "{" {
                // Find the matching close brace, allowing nested ${...} in defaults.
                var depth = 1
                var j = i + 2
                while j < chars.count && depth > 0 {
                    if chars[j] == "{" { depth += 1 }
                    if chars[j] == "}" { depth -= 1 }
                    if depth > 0 { j += 1 }
                }
                if j >= chars.count {
                    errors.append("A ${ is not closed in \"\(input)\".")
                    output.append(contentsOf: String(chars[i...]))
                    break
                }
                let body = String(chars[(i + 2)..<j])
                let resolved = resolveBraced(body, errors: &errors)
                output.append(resolved)
                i = j + 1
            } else if let n = next, n == "_" || n.isLetter {
                var j = i + 1
                while j < chars.count, chars[j] == "_" || chars[j].isLetter || chars[j].isNumber {
                    j += 1
                }
                let name = String(chars[(i + 1)..<j])
                output.append(values[name] ?? "")
                i = j
            } else {
                output.append("$")
                i += 1
            }
        }
        return Result(text: output, errors: errors)
    }

    private func resolveBraced(_ body: String, errors: inout [String]) -> String {
        // Name is letters, digits and underscores. The rest is the modifier.
        var nameEnd = body.startIndex
        while nameEnd < body.endIndex, body[nameEnd] == "_" || body[nameEnd].isLetter || body[nameEnd].isNumber {
            nameEnd = body.index(after: nameEnd)
        }
        let name = String(body[..<nameEnd])
        let rest = String(body[nameEnd...])
        guard !name.isEmpty else {
            errors.append("\"${\(body)}\" is not a valid variable.")
            return ""
        }
        let value = values[name]
        if rest.isEmpty { return value ?? "" }

        let operators = [":-", ":?", ":+", "-", "?", "+"]
        guard let op = operators.first(where: { rest.hasPrefix($0) }) else {
            errors.append("\"${\(body)}\" is not a valid variable.")
            return ""
        }
        // The word after the operator can hold variables too.
        let word = interpolate(String(rest.dropFirst(op.count)))
        errors += word.errors
        let isSet = value != nil
        let isSetAndNotEmpty = !(value ?? "").isEmpty

        switch op {
        case ":-": return isSetAndNotEmpty ? (value ?? "") : word.text
        case "-": return isSet ? (value ?? "") : word.text
        case ":+": return isSetAndNotEmpty ? word.text : ""
        case "+": return isSet ? word.text : ""
        case ":?":
            if !isSetAndNotEmpty {
                errors.append(word.text.isEmpty ? "\(name) must be set." : word.text)
            }
            return value ?? ""
        case "?":
            if !isSet {
                errors.append(word.text.isEmpty ? "\(name) must be set." : word.text)
            }
            return value ?? ""
        default:
            return value ?? ""
        }
    }
}

/// Reads `.env` style files: KEY=VALUE, `export KEY=VALUE`, comments and quotes.
public enum DotEnvParser {
    public static func parse(_ text: String, lookup: [String: String] = [:]) -> [EnvVar] {
        var result: [EnvVar] = []
        var known = lookup
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else {
                // A bare key takes its value from the environment, when set.
                let key = line
                if let value = lookup[key] { result.append(EnvVar(key: key, value: value)) }
                continue
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("'"), value.count >= 2, let close = value.dropFirst().firstIndex(of: "'") {
                value = String(value[value.index(after: value.startIndex)..<close])
            } else if value.hasPrefix("\""), value.count >= 2, let close = value.dropFirst().firstIndex(of: "\"") {
                value = String(value[value.index(after: value.startIndex)..<close])
                    .replacingOccurrences(of: "\\n", with: "\n")
                value = ComposeInterpolator(values: known).interpolate(value).text
            } else {
                if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
                value = value.trimmingCharacters(in: .whitespaces)
                value = ComposeInterpolator(values: known).interpolate(value).text
            }
            result.removeAll { $0.key == key }
            result.append(EnvVar(key: key, value: value))
            known[key] = value
        }
        return result
    }

    public static func dictionary(_ text: String, lookup: [String: String] = [:]) -> [String: String] {
        var out: [String: String] = [:]
        for item in parse(text, lookup: lookup) { out[item.key] = item.value }
        return out
    }
}

/// Splits a command string like a shell does (quotes and backslashes, no expansion).
public enum ShellWords {
    public static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for c in text {
            if escaped {
                current.append(c)
                escaped = false
                inWord = true
                continue
            }
            if let q = quote {
                if c == q {
                    quote = nil
                } else if c == "\\" && q == "\"" {
                    escaped = true
                } else {
                    current.append(c)
                }
                continue
            }
            if c == "\\" {
                escaped = true
            } else if c == "\"" || c == "'" {
                quote = c
                inWord = true
            } else if c == " " || c == "\t" || c == "\n" {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            } else {
                current.append(c)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// Quotes one word for display in a shell.
    public static func quote(_ word: String) -> String {
        if word.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@%+,"))
        if word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
