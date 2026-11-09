import Foundation

/// A version number of a system tool, such as "1.6.1", "v1.35.0", "2026.10.7",
/// "0.0.27-1" (LM Studio's llmster) or "0.4.28,2" (a Homebrew cask with a build).
///
/// Any number of numeric parts. A trailing "-<digits>", "+<digits>" or ",<digits>" is a build
/// revision and counts as one more part, so "0.0.27-1" and "0.0.27+1" are the same and both are
/// newer than "0.0.27". A trailing "-rc.1", "-beta" or "rc1" marks a pre-release, which is older
/// than the same numbers without it. Anything after a space is ignored.
public struct ToolVersion: Sendable, Hashable, Comparable, CustomStringConvertible, Codable {
    public let parts: [Int]
    /// Pre-release text, like "rc.1". nil for a normal release.
    public let prerelease: String?

    public init(_ parts: [Int], prerelease: String? = nil) {
        self.parts = parts.isEmpty ? [0] : parts
        self.prerelease = prerelease
    }

    public init(_ version: SemanticVersion) {
        self.init([version.major, version.minor, version.patch])
    }

    /// Reads a version from the start of `text` (after an optional "v"). nil when there is none.
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        var numbers: [Int] = []
        while true {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty, let value = Int(digits) else { break }
            numbers.append(value)
            rest = rest.dropFirst(digits.count)
            guard rest.first == ".", let next = rest.dropFirst().first, next.isASCII, next.isNumber else { break }
            rest = rest.dropFirst()
        }
        guard !numbers.isEmpty else { return nil }

        var pre: String?
        if let mark = rest.first, "-+,_".contains(mark) {
            let tail = rest.dropFirst()
            let digits = tail.prefix(while: { $0.isASCII && $0.isNumber })
            let after = tail.dropFirst(digits.count).first
            if !digits.isEmpty, after == nil || after == " " || after == "," || after == "(", let build = Int(digits) {
                // Build revision: "0.0.27-1", "0.0.27+1", "0.4.28,2".
                numbers.append(build)
            } else if mark == "-" {
                let label = tail.prefix(while: { !$0.isWhitespace && $0 != "+" })
                // "-g44d37b" is a git build mark (Amp's "0.0.1794196844-g44d37b"), not a pre-release.
                let isGitMark = label.first == "g" && label.count >= 7 && label.dropFirst().allSatisfy(\.isHexDigit)
                if !label.isEmpty, !isGitMark { pre = String(label) }
            }
            // "+g4553a0a" (git build metadata) is ignored.
        } else if let first = rest.first, first.isLetter {
            // PyPI style "0.33.0rc1".
            let label = rest.prefix(while: { !$0.isWhitespace })
            let lower = label.lowercased()
            if ["a", "b", "rc", "alpha", "beta", "dev", "pre"].contains(where: { lower.hasPrefix($0) }) {
                pre = String(label)
            }
        }
        self.init(numbers, prerelease: pre)
    }

    /// The first version number anywhere in `text`, like in "ollama version is 0.16.2".
    public static func firstMatch(in text: String) -> ToolVersion? {
        guard let regex = try? NSRegularExpression(pattern: #"v?\d+(?:\.\d+)+(?:[-+,][0-9A-Za-z.]+)?"#) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ToolVersion(ns.substring(with: match.range))
    }

    public var isPrerelease: Bool { prerelease != nil }

    public var major: Int { parts[0] }
    public var minor: Int { parts.count > 1 ? parts[1] : 0 }

    public var description: String {
        let base = parts.map(String.init).joined(separator: ".")
        return prerelease.map { base + "-" + $0 } ?? base
    }

    public static func < (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let a = index < lhs.parts.count ? lhs.parts[index] : 0
            let b = index < rhs.parts.count ? rhs.parts[index] : 0
            if a != b { return a < b }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, .some): return false
        case (.some, nil): return true
        case let (a?, b?): return a.compare(b, options: .numeric) == .orderedAscending
        }
    }

    public static func == (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(prerelease)
    }
}
