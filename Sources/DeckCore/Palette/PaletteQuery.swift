import Foundation

/// The kinds of things the palette can list.
public enum PaletteKind: String, Sendable, CaseIterable, Hashable {
    case screen, action, container, image, volume, network, machine, stack

    /// Section title in the palette.
    public var sectionTitle: String {
        switch self {
        case .screen: return "Screens"
        case .action: return "Actions"
        case .container: return "Containers"
        case .image: return "Images"
        case .volume: return "Volumes"
        case .network: return "Networks"
        case .machine: return "Machines"
        case .stack: return "Compose Stacks"
        }
    }
}

/// A verb typed in front of a target, like "stop db" or "logs api".
public enum PaletteVerb: String, Sendable, CaseIterable, Hashable {
    case start, stop, restart, logs, shell, delete, pull, run, inspect

    /// Other words that mean the same verb.
    public var aliases: [String] {
        switch self {
        case .start: return ["up", "boot"]
        case .stop: return ["down", "halt"]
        case .restart: return ["reboot"]
        case .logs: return ["log", "tail"]
        case .shell: return ["sh", "exec", "ssh", "attach"]
        case .delete: return ["rm", "remove", "del"]
        case .pull: return []
        case .run: return ["new"]
        case .inspect: return ["open", "show", "go"]
        }
    }

    /// Resource kinds this verb works on.
    public var targetKinds: Set<PaletteKind> {
        switch self {
        case .start, .stop: return [.container, .machine]
        case .restart, .logs: return [.container]
        case .shell: return [.container, .machine]
        case .delete: return [.container, .image, .volume, .network, .machine]
        case .pull, .run: return [.image]
        case .inspect: return [.container, .image, .volume, .network, .machine, .stack]
        }
    }

    /// True when the target can be any text, not only a known resource (an image reference).
    public var acceptsFreeText: Bool {
        self == .pull || self == .run
    }

    /// Title for the verb, like "Stop".
    public var title: String {
        switch self {
        case .logs: return "Show logs for"
        case .shell: return "Open a shell in"
        case .inspect: return "Open"
        default: return rawValue.capitalized
        }
    }

    /// Finds a verb by its name or an alias. Case is ignored.
    public static func named(_ word: String) -> PaletteVerb? {
        let word = word.lowercased()
        return allCases.first { $0.rawValue == word || $0.aliases.contains(word) }
    }

    /// Tab completion: the first verb whose name starts with `prefix`.
    /// Returns nil for an empty prefix or a word that is already a full verb.
    public static func completion(for prefix: String) -> PaletteVerb? {
        let prefix = prefix.lowercased()
        guard !prefix.isEmpty, !prefix.contains(where: \.isWhitespace) else { return nil }
        if let exact = named(prefix), exact.rawValue == prefix { return nil }
        return allCases.first { $0.rawValue.hasPrefix(prefix) }
    }
}

/// A parsed palette query: an optional verb and the text to search for.
public struct PaletteQuery: Sendable, Hashable {
    public var raw: String
    public var verb: PaletteVerb?
    /// Text after the verb, or the whole query when there is no verb. Trimmed.
    public var target: String

    public init(raw: String, verb: PaletteVerb?, target: String) {
        self.raw = raw
        self.verb = verb
        self.target = target
    }

    /// True when the person typed a verb with nothing after it.
    public var isVerbOnly: Bool { verb != nil && target.isEmpty }

    /// "stop db" gives verb stop and target "db". "logs   api" gives logs and "api".
    /// An unknown first word is not a verb, so the whole text is searched.
    /// A verb alone ("stop" or "stop ") is a verb with an empty target.
    public static func parse(_ text: String) -> PaletteQuery {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return PaletteQuery(raw: text, verb: nil, target: "") }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let first = String(parts[0])
        guard let verb = PaletteVerb.named(first) else {
            return PaletteQuery(raw: text, verb: nil, target: trimmed)
        }
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return PaletteQuery(raw: text, verb: verb, target: rest)
    }

    /// Tab completion for the whole field: "sto" becomes "stop ". nil when nothing to complete.
    public static func complete(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let verb = PaletteVerb.completion(for: trimmed) { return verb.rawValue + " " }
        // A full verb without the space: add it.
        if let verb = PaletteVerb.named(trimmed), !text.hasSuffix(" ") { return verb.rawValue + " " }
        return nil
    }
}
