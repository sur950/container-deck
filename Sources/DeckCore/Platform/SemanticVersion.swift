import Foundation

public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// Finds the first version number in text such as
    /// "container CLI version 0.5.0 (build: release, commit: 1a2b3c)".
    public static func firstMatch(in text: String) -> SemanticVersion? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\.(\d+)(?:\.(\d+))?"#) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        func group(_ index: Int) -> Int {
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return 0 }
            return Int(ns.substring(with: range)) ?? 0
        }
        return SemanticVersion(group(1), group(2), group(3))
    }
}
