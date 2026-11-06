import Foundation

/// Edits the user's `~/.config/container/config.toml`.
///
/// Since `container` 1.0 there is no `system property set` command. The
/// service reads this file when it starts, so a change needs
/// `container system stop` and `container system start` to take effect.
/// `container system start` copies it (read only) to
/// `~/Library/Application Support/com.apple.container/config/config.toml`, and
/// `system property list` shows that copy merged with the defaults.
/// Keys are dotted: "build.cpus", "container.memory", "dns.domain", "network.subnet".
public enum SystemConfigFile {
    /// `$XDG_CONFIG_HOME/container/config.toml`, else `~/.config/container/config.toml`.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        return base
            .appendingPathComponent("container", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    /// The value of a dotted key as written in the file (quotes removed), or nil.
    /// Use it to show a change that waits for a service restart.
    public static func value(_ key: String, at url: URL = defaultURL()) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return value(in: text, key: key)
    }

    /// The value of a dotted key in TOML text (quotes removed), or nil.
    public static func value(in text: String, key: String) -> String? {
        let parts = key.split(separator: ".").map { String($0) }
        guard let name = parts.last, !name.isEmpty else { return nil }
        let table = parts.dropLast().joined(separator: ".")
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if let header = headerName(line) {
                current = header
                continue
            }
            guard current == table, assignedKey(line) == name, let equals = line.firstIndex(of: "=") else { continue }
            var raw = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\"") {
                // Quoted string. Stop at the closing quote, so a trailing comment is ignored.
                var result = ""
                var escaped = false
                for character in raw.dropFirst() {
                    if escaped {
                        switch character {
                        case "n": result.append("\n")
                        case "t": result.append("\t")
                        default: result.append(character)
                        }
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        break
                    } else {
                        result.append(character)
                    }
                }
                return result
            }
            if raw.hasPrefix("'") {
                raw.removeFirst()
                return String(raw.prefix(while: { $0 != "'" }))
            }
            if let hash = raw.firstIndex(of: "#") { raw = String(raw[..<hash]) }
            return raw.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Sets (or with nil or "", removes) one key in the file. Creates the file when needed.
    public static func set(_ key: String, value: String?, at url: URL = defaultURL()) throws {
        let fm = FileManager.default
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let cleaned = value.flatMap { CLIText.nonEmpty($0) }
        let updated = updating(current, key: key, value: cleaned)
        guard updated != current else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The TOML text with `key` set to `value` (nil removes it). Comments and other keys are kept.
    public static func updating(_ text: String, key: String, value: String?) -> String {
        let parts = key.split(separator: ".").map { String($0) }
        guard let name = parts.last, !name.isEmpty else { return text }
        let table = parts.dropLast().joined(separator: ".")

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        // Table name for every line ("" is the top level before any header).
        var tables: [String] = []
        var headerIndex: Int?
        var current = ""
        for (index, line) in lines.enumerated() {
            if let header = headerName(line) {
                current = header
                if header == table, headerIndex == nil { headerIndex = index }
            }
            tables.append(current)
        }

        let keyIndex = lines.indices.first(where: { index in
            tables[index] == table && headerName(lines[index]) == nil && assignedKey(lines[index]) == name
        })

        if let keyIndex {
            if let value {
                lines[keyIndex] = "\(name) = \(tomlValue(value))"
            } else {
                lines.remove(at: keyIndex)
            }
            return lines.joined(separator: "\n") + "\n"
        }

        guard let value else { return text }
        let entry = "\(name) = \(tomlValue(value))"

        if table.isEmpty {
            // Top level keys must come before the first table.
            let firstHeader = lines.indices.first(where: { headerName(lines[$0]) != nil }) ?? lines.count
            lines.insert(entry, at: firstHeader)
            return lines.joined(separator: "\n") + "\n"
        }

        if let headerIndex {
            // After the last non blank line of that table.
            var insertAt = headerIndex + 1
            var index = headerIndex + 1
            while index < lines.count, tables[index] == table, headerName(lines[index]) == nil {
                if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { insertAt = index + 1 }
                index += 1
            }
            lines.insert(entry, at: insertAt)
            return lines.joined(separator: "\n") + "\n"
        }

        if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("")
        }
        lines.append("[\(table)]")
        lines.append(entry)
        return lines.joined(separator: "\n") + "\n"
    }

    /// "build" for "[build]", "container.dns" for "[ container.dns ] # note". nil when not a header.
    static func headerName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        if trimmed.hasPrefix("[[") {
            // Array of tables. Never matches a plain table name.
            return "[[" + String(trimmed.dropFirst(2).prefix(while: { $0 != "]" }))
        }
        guard let close = trimmed.firstIndex(of: "]") else { return nil }
        let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        return inner
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .joined(separator: ".")
    }

    /// "cpus" for `cpus = 4` or `"cpus" = 4`. nil for comments and blank lines.
    static func assignedKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        return trimmed[..<equals]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// Bools, whole numbers and arrays are written as is. Everything else is a quoted string
    /// (memory sizes like "4g" must be strings).
    static func tomlValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed == "true" || trimmed == "false" { return trimmed }
        if Int(trimmed) != nil { return trimmed }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { return trimmed }
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") { return trimmed }
        var escaped = ""
        for scalar in trimmed.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}
