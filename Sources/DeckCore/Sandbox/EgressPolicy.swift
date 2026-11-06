import Foundation

/// Network mode of a sandbox.
public enum SandboxEgress: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// Host only network. No internet.
    case isolated
    /// Normal network. Full internet.
    case open
    /// Host only network plus the app's proxy that lets through only listed hosts.
    case allowList = "allowlist"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .isolated: return "Isolated"
        case .open: return "Internet"
        case .allowList: return "Allow list"
        }
    }

    /// The sandbox network is created with `--internal`.
    public var isInternal: Bool { self != .open }
}

/// Which hosts the allow list proxy lets through.
///
/// Rules: `example.com` matches only that name. `*.example.com` matches example.com and
/// every name below it. `host:port` limits a rule to one port. IP addresses must be
/// listed as they are. Everything else is blocked.
public struct EgressPolicy: Sendable, Hashable {
    public struct Rule: Sendable, Hashable {
        public var host: String
        public var includesSubdomains: Bool
        public var port: Int?
    }

    public private(set) var rules: [Rule]
    /// Exact host and port pairs always allowed (the sandbox's own model relay).
    public var alwaysAllowed: Set<String>

    public init(entries: [String], alwaysAllowed: Set<String> = []) {
        rules = entries.compactMap(Self.rule)
        self.alwaysAllowed = alwaysAllowed
    }

    public func allows(host rawHost: String, port: Int) -> Bool {
        let host = Self.cleanHost(rawHost)
        guard !host.isEmpty else { return false }
        if alwaysAllowed.contains("\(host):\(port)") { return true }
        return rules.contains { rule in
            if let rulePort = rule.port, rulePort != port { return false }
            if host == rule.host { return true }
            return rule.includesSubdomains && host.hasSuffix("." + rule.host)
        }
    }

    /// Turns what someone typed (a URL, a name, `*.name`, `name:port`) into a clean entry.
    /// nil when it is not a usable host.
    public static func normalize(_ entry: String) -> String? {
        guard let rule = rule(entry) else { return nil }
        let host = (rule.includesSubdomains ? "*." : "") + rule.host
        return rule.port.map { "\(host):\($0)" } ?? host
    }

    /// Splits text on commas, spaces and new lines, normalizes and removes repeats (order kept).
    public static func parseList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == "\t" })
            .compactMap { normalize(String($0)) }
            .filter { seen.insert($0).inserted }
    }

    /// Entries that cannot be used, for a warning in the form.
    public static func invalidEntries(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { normalize($0) == nil }
    }

    static func rule(_ entry: String) -> Rule? {
        var text = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        var wildcard = false
        if text.hasPrefix("*.") {
            wildcard = true
            text.removeFirst(2)
        } else if text.hasPrefix(".") {
            wildcard = true
            text.removeFirst()
        }
        var port: Int?
        if text.hasPrefix("[") {
            // [ipv6]:port
            guard let close = text.firstIndex(of: "]") else { return nil }
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":") {
                guard let value = Int(rest.dropFirst()), (1...65535).contains(value) else { return nil }
                port = value
            } else if !rest.isEmpty {
                return nil
            }
            text = String(text[text.index(after: text.startIndex)..<close])
        } else if let colon = text.lastIndex(of: ":"), text.filter({ $0 == ":" }).count == 1 {
            guard let value = Int(text[text.index(after: colon)...]), (1...65535).contains(value) else { return nil }
            port = value
            text = String(text[..<colon])
        }
        let host = cleanHost(text)
        guard !host.isEmpty, host.count <= 253 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !host.hasPrefix("."), !host.hasPrefix("-"), !host.contains("..") else { return nil }
        // A bare top level name with a wildcard (like *.com) would open far too much.
        if wildcard && !host.contains(".") { return nil }
        return Rule(host: host, includesSubdomains: wildcard, port: port)
    }

    static func cleanHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("[") && value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }
}
