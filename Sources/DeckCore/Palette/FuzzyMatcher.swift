import Foundation

/// Result of a fuzzy match: a score (higher is better) and the matched character offsets.
public struct FuzzyMatch: Sendable, Hashable {
    public var score: Int
    /// Character offsets (into `Array(candidate)`) of the matched characters, ascending.
    public var indices: [Int]

    public init(score: Int, indices: [Int]) {
        self.score = score
        self.indices = indices
    }

    /// Matched offsets merged into runs, for highlighting.
    public var ranges: [Range<Int>] {
        var result: [Range<Int>] = []
        for index in indices {
            if let last = result.last, last.upperBound == index {
                result[result.count - 1] = last.lowerBound..<(index + 1)
            } else {
                result.append(index..<(index + 1))
            }
        }
        return result
    }
}

/// Subsequence matcher in the style of Raycast and Linear.
///
/// Every query character must appear in order. The best placement wins:
/// word starts and runs of consecutive characters score more, a match at the
/// very start scores most. Case is ignored and spaces in the query are skipped.
public enum FuzzyMatcher {
    static let matchScore = 1
    static let firstCharBonus = 12
    static let wordStartBonus = 8
    static let consecutiveBonus = 6
    static let prefixBonus = 30
    static let exactBonus = 100

    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, indices: []) }
        let original = Array(candidate)
        let hay = original.map { Character($0.lowercased()) }
        let m = needle.count
        let n = hay.count
        guard m <= n else { return nil }

        // Fast reject: must be a subsequence at all.
        var probe = 0
        for ch in hay where probe < m && ch == needle[probe] { probe += 1 }
        guard probe == m else { return nil }

        let bonus = (0..<n).map { positionBonus(original, $0) }
        let none = Int.min / 4
        // best[i][j]: best score with needle[i] matched at hay[j]. from[i][j]: where needle[i-1] sat.
        var best = Array(repeating: Array(repeating: none, count: n), count: m)
        var from = Array(repeating: Array(repeating: -1, count: n), count: m)

        for j in 0..<n where hay[j] == needle[0] {
            best[0][j] = matchScore + bonus[j]
        }
        if m > 1 {
            for i in 1..<m {
                // Running max of best[i-1][k] for k < j - 1 (a gap before j).
                var gapBest = none
                var gapFrom = -1
                for j in 1..<n {
                    if j >= 2, best[i - 1][j - 2] > gapBest {
                        gapBest = best[i - 1][j - 2]
                        gapFrom = j - 2
                    }
                    guard hay[j] == needle[i] else { continue }
                    var score = none
                    var source = -1
                    if gapBest > none {
                        score = gapBest + matchScore + bonus[j]
                        source = gapFrom
                    }
                    let adjacent = best[i - 1][j - 1]
                    if adjacent > none {
                        // A consecutive run keeps the word start bonus too.
                        let run = adjacent + matchScore + max(bonus[j], consecutiveBonus)
                        if run >= score {
                            score = run
                            source = j - 1
                        }
                    }
                    best[i][j] = score
                    from[i][j] = source
                }
            }
        }

        var end = -1
        var top = none
        for j in 0..<n where best[m - 1][j] > top {
            top = best[m - 1][j]
            end = j
        }
        guard end >= 0, top > none else { return nil }

        var indices = Array(repeating: 0, count: m)
        var j = end
        var i = m - 1
        while i >= 0 {
            indices[i] = j
            j = from[i][j]
            i -= 1
        }

        var score = top
        let lowered = String(hay)
        let plainQuery = String(needle)
        if lowered == plainQuery {
            score += exactBonus
        } else if lowered.hasPrefix(plainQuery) {
            score += prefixBonus
        }
        // Shorter candidates win ties.
        score -= (n - m) / 8
        return FuzzyMatch(score: score, indices: indices)
    }

    /// Bonus for matching at this position: first character, then any word start.
    static func positionBonus(_ chars: [Character], _ index: Int) -> Int {
        if index == 0 { return firstCharBonus }
        let previous = chars[index - 1]
        let current = chars[index]
        if isSeparator(previous) { return wordStartBonus }
        if previous.isLowercase && current.isUppercase { return wordStartBonus }
        if previous.isLetter && current.isNumber { return wordStartBonus / 2 }
        return 0
    }

    static func isSeparator(_ ch: Character) -> Bool {
        ch.isWhitespace || "-_./:@".contains(ch)
    }
}
