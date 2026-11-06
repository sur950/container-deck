import Foundation

// Helpers for reading `container --format json` output.
// Apple changes these shapes between releases, so everything here is
// forgiving: missing keys, wrong types and unknown fields never fail a whole list.

/// A coding key with any name. Used to read keys we do not know ahead of time.
struct CLIKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Decodes one item and keeps nil when it fails, so one bad item does not drop a list.
struct CLILenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) {
        value = try? T(from: decoder)
    }
}

/// A date that may be ISO 8601 text (with or without fractional seconds) or a number.
struct CLIDate: Decodable {
    let date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self), let date = DeckDate.fromNumber(number) {
            self.date = date
            return
        }
        if let text = try? container.decode(String.self), let date = DeckDate.parse(text) {
            self.date = date
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a date")
    }
}

extension KeyedDecodingContainer {
    /// The value when present and of the right type. Anything else gives nil.
    func lax<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard contains(key) else { return nil }
        return try? decodeIfPresent(type, forKey: key)
    }

    /// The first key in the list that holds a value of this type.
    func lax<T: Decodable>(_ type: T.Type, _ keys: [Key]) -> T? {
        for key in keys {
            if let value = lax(type, key) { return value }
        }
        return nil
    }

    /// A list where items that fail to decode are skipped.
    func laxList<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        guard let items = lax([CLILenient<T>].self, key) else { return [] }
        return items.compactMap { $0.value }
    }

    func laxString(_ key: Key) -> String? {
        if let value = lax(String.self, key) { return value }
        if let value = lax(Int64.self, key) { return String(value) }
        return nil
    }

    func laxString(_ keys: [Key]) -> String? {
        for key in keys {
            if let value = laxString(key) { return value }
        }
        return nil
    }

    func laxUInt64(_ key: Key) -> UInt64? {
        if let value = lax(UInt64.self, key) { return value }
        if let value = lax(Int64.self, key) { return value >= 0 ? UInt64(value) : nil }
        if let value = lax(Double.self, key), value.isFinite, value >= 0, value < 1.8e19 {
            return UInt64(value)
        }
        if let text = lax(String.self, key) {
            return UInt64(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func laxInt(_ key: Key) -> Int? {
        if let value = lax(Int.self, key) { return value }
        if let value = lax(Double.self, key), value.isFinite, abs(value) < 9.0e18 {
            return Int(value)
        }
        if let text = lax(String.self, key) {
            return Int(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func laxDouble(_ key: Key) -> Double? {
        if let value = lax(Double.self, key) { return value.isFinite ? value : nil }
        if let text = lax(String.self, key) {
            return Double(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func laxBool(_ key: Key) -> Bool? {
        if let value = lax(Bool.self, key) { return value }
        if let text = lax(String.self, key) {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        if let number = lax(Int.self, key) { return number != 0 }
        return nil
    }

    func laxDate(_ key: Key) -> Date? {
        lax(CLIDate.self, key)?.date
    }

    func laxDate(_ keys: [Key]) -> Date? {
        for key in keys {
            if let value = laxDate(key) { return value }
        }
        return nil
    }

    func laxStrings(_ key: Key) -> [String]? {
        if let value = lax([String].self, key) { return value }
        if let items = lax([CLILenient<String>].self, key) { return items.compactMap { $0.value } }
        if let single = lax(String.self, key) { return [single] }
        return nil
    }

    func laxMap(_ key: Key) -> [String: String]? {
        if let value = lax([String: String].self, key) { return value }
        // Some values may be numbers or bools. Keep the ones we can read as text.
        guard contains(key), let nested = try? nestedContainer(keyedBy: CLIKey.self, forKey: key) else {
            return nil
        }
        var result: [String: String] = [:]
        for inner in nested.allKeys {
            if let text = nested.laxString(inner) {
                result[inner.stringValue] = text
            } else if let flag = nested.lax(Bool.self, inner) {
                result[inner.stringValue] = flag ? "true" : "false"
            }
        }
        return result
    }

    /// Names of the keys inside an object value, for maps like `{"80/tcp": {}}`.
    func laxKeys(_ key: Key) -> [String]? {
        guard contains(key), let nested = try? nestedContainer(keyedBy: CLIKey.self, forKey: key) else {
            return nil
        }
        return nested.allKeys.map { $0.stringValue }
    }
}

// MARK: - Dates

/// Reads the date formats the platform and Docker Hub use.
public enum DeckDate {
    private static let pattern = #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|z|[+-]\d{2}:?\d{2})?$"#

    /// Parses ISO 8601 text with or without fractional seconds (any number of digits),
    /// with "Z" or an offset, or a number given as text.
    public static func parse(_ text: String) -> Date? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if let number = Double(value) { return fromNumber(number) }
        if value.count > 10 {
            let index = value.index(value.startIndex, offsetBy: 10)
            if value[index] == " " {
                value.replaceSubrange(index...index, with: "T")
            }
        }
        guard let regex = compiledPattern else { return nil }
        let ns = value as NSString
        guard let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else {
            return dateOnly(value)
        }
        let base = ns.substring(with: match.range(at: 1))
        var fraction = 0.0
        if match.range(at: 2).location != NSNotFound {
            fraction = Double("0" + ns.substring(with: match.range(at: 2))) ?? 0
        }
        var zone = "Z"
        if match.range(at: 3).location != NSNotFound {
            zone = ns.substring(with: match.range(at: 3))
            if zone == "z" { zone = "Z" }
            if zone != "Z", !zone.contains(":"), zone.count == 5 {
                zone.insert(":", at: zone.index(zone.startIndex, offsetBy: 3))
            }
        }
        guard let date = internetFormatter.date(from: base + zone) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    /// Numbers are seconds since 1970, or since 2001 for values written by
    /// Swift's default date encoding (older CLI releases). Milliseconds and
    /// microseconds since 1970 are recognised by size.
    // Made once: building these costs more than using them, and lists are read every second.
    // Both are safe to share between threads once configured.
    nonisolated(unsafe) private static let compiledPattern = try? NSRegularExpression(pattern: pattern)
    nonisolated(unsafe) private static let internetFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func fromNumber(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        if value > 1e14 { return Date(timeIntervalSince1970: value / 1_000_000) }
        if value > 1e11 { return Date(timeIntervalSince1970: value / 1000) }
        // Seconds since 2001 stay below 1.2e9 until 2039. Seconds since 1970 pass 1.2e9 in 2008.
        if value >= 1.2e9 { return Date(timeIntervalSince1970: value) }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    /// Placeholder dates (the 1970 epoch) mean "unknown".
    static func meaningful(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970 > 86_400 * 366 else { return nil }
        return date
    }

    private static func dateOnly(_ value: String) -> Date? {
        guard value.count == 10 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: value)
    }
}

// MARK: - Documents

enum CLIJSON {
    /// The JSON part of command output. Skips text a command printed before it.
    static func payload(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            return Data(trimmed.utf8)
        }
        let newlines = ["\n[", "\n{"].compactMap { trimmed.range(of: $0)?.lowerBound }
        guard let newline = newlines.min() else { return nil }
        return Data(trimmed[trimmed.index(after: newline)...].utf8)
    }

    /// Decodes a JSON array (or a single object) into items, skipping bad items.
    /// Empty output means an empty list.
    static func decodeList<T: Decodable>(_ type: T.Type, from text: String, what: String) throws -> [T] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let data = payload(text) else { throw DeckError.parse(what) }
        let decoder = JSONDecoder()
        if let items = try? decoder.decode([CLILenient<T>].self, from: data) {
            return items.compactMap { $0.value }
        }
        if let item = try? decoder.decode(T.self, from: data) {
            return [item]
        }
        throw DeckError.parse(what)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String, what: String) throws -> T {
        guard let data = payload(text) else { throw DeckError.parse(what) }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DeckError.parse(what)
        }
    }

    /// Any JSON value (dictionaries, arrays, NSNumber, String, NSNull).
    static func object(_ text: String) -> Any? {
        guard let data = payload(text) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Pretty printed copies of each item of a JSON array, or of the one object.
    static func prettyItems(_ text: String) -> [String] {
        guard let root = object(text) else { return [] }
        if let array = root as? [Any] {
            return array.map { pretty($0) }
        }
        return [pretty(root)]
    }

    static func pretty(_ value: Any) -> String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Text for a scalar JSON value. Bools stay "true" or "false".
    static func scalarText(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if String(cString: number.objCType) == "c" {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        // Arrays and tables as compact JSON (also valid TOML for arrays).
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Text helpers

enum CLIText {
    /// The text with ANSI escape sequences (colors, cursor moves) removed.
    static func strippingANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}|\u{1B}[@-Z\\\\-_]",
            with: "",
            options: .regularExpression
        )
    }

    /// "192.168.64.3" from "192.168.64.3/24".
    static func withoutCIDRSuffix(_ text: String) -> String {
        guard let slash = text.firstIndex(of: "/") else { return text }
        return String(text[..<slash])
    }

    /// "web.test" from "web.test.".
    static func withoutTrailingDot(_ text: String) -> String {
        text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    /// Trimmed text, or nil when nothing is left.
    static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One word for `sh`. Plain words stay as they are, others get single quotes.
    static func shellQuoted(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:=@%+,")
        if !text.isEmpty, text.unicodeScalars.allSatisfy({ plain.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
