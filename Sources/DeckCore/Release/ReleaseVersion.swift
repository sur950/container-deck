import Foundation

/// A semantic version such as "1.2.3", "v1.2.0" or "1.3.0-beta.2".
/// Build metadata after "+" is ignored, as the semver rules say.
public struct ReleaseVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot separated pre-release identifiers, for example ["beta", "2"].
    public let prerelease: [String]

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Reads text like "v1.2.3", "1.2" or "1.3.0-rc.1+42". Returns nil for anything else.
    public init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.hasPrefix("v") || core.hasPrefix("V") {
            core.removeFirst()
        }
        if let plus = core.firstIndex(of: "+") {
            core = String(core[..<plus])
        }

        var identifiers: [String] = []
        if let dash = core.firstIndex(of: "-") {
            let tail = core[core.index(after: dash)...]
            identifiers = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if identifiers.isEmpty || identifiers.contains(where: { $0.isEmpty }) {
                return nil
            }
            core = String(core[..<dash])
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 1, parts.count <= 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        while numbers.count < 3 {
            numbers.append(0)
        }
        self.init(numbers[0], numbers[1], numbers[2], prerelease: identifiers)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? base : base + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let left = (lhs.major, lhs.minor, lhs.patch)
        let right = (rhs.major, rhs.minor, rhs.patch)
        if left != right {
            return left < right
        }
        // A normal release is newer than any pre-release of the same number.
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?):
                return x < y
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
