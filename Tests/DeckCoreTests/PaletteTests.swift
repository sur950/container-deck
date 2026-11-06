import XCTest
@testable import DeckCore

final class PaletteTests: XCTestCase {

    // MARK: Fuzzy scorer

    func testNoMatchWhenNotASubsequence() {
        XCTAssertNil(FuzzyMatcher.match("xyz", in: "nginx"))
        XCTAssertNil(FuzzyMatcher.match("gn", in: "gx"))
        XCTAssertNil(FuzzyMatcher.match("nginxx", in: "nginx"))
    }

    func testPrefixBeatsWordStartBeatsSubsequence() throws {
        let prefix = try XCTUnwrap(FuzzyMatcher.match("ng", in: "nginx"))
        let wordStart = try XCTUnwrap(FuzzyMatcher.match("ng", in: "my-nginx"))
        let subsequence = try XCTUnwrap(FuzzyMatcher.match("ng", in: "running"))
        XCTAssertGreaterThan(prefix.score, wordStart.score)
        XCTAssertGreaterThan(wordStart.score, subsequence.score)
    }

    func testExactBeatsPrefix() throws {
        let exact = try XCTUnwrap(FuzzyMatcher.match("web", in: "web"))
        let prefix = try XCTUnwrap(FuzzyMatcher.match("web", in: "webapp"))
        XCTAssertGreaterThan(exact.score, prefix.score)
    }

    func testConsecutiveBeatsScattered() throws {
        let run = try XCTUnwrap(FuzzyMatcher.match("dat", in: "xdatabase"))
        let scattered = try XCTUnwrap(FuzzyMatcher.match("dat", in: "xdxaxt"))
        XCTAssertGreaterThan(run.score, scattered.score)
    }

    func testWordStartsAcrossWords() throws {
        // "gti" should pick the word starts of "Go to Images", not letters inside words.
        let hit = try XCTUnwrap(FuzzyMatcher.match("gti", in: "Go to Images"))
        XCTAssertEqual(hit.indices, [0, 3, 6])
    }

    func testCaseInsensitiveAndCamelCase() throws {
        let hit = try XCTUnwrap(FuzzyMatcher.match("NGX", in: "nginx"))
        XCTAssertEqual(hit.indices.count, 3)
        let camel = try XCTUnwrap(FuzzyMatcher.match("ds", in: "deckService"))
        XCTAssertEqual(camel.indices, [0, 4])
    }

    func testSpacesInQueryAreSkipped() throws {
        let hit = try XCTUnwrap(FuzzyMatcher.match("go img", in: "Go to Images"))
        XCTAssertEqual(hit.indices.first, 0)
    }

    func testHighlightRanges() throws {
        let hit = try XCTUnwrap(FuzzyMatcher.match("ngx", in: "nginx"))
        // n g [i n] x: "ng" is one run, "x" another.
        XCTAssertEqual(hit.ranges, [0..<2, 4..<5])
        let word = try XCTUnwrap(FuzzyMatcher.match("ng", in: "my-nginx"))
        XCTAssertEqual(word.ranges, [3..<5])
        XCTAssertEqual(FuzzyMatch(score: 0, indices: [1, 2, 3, 7]).ranges, [1..<4, 7..<8])
    }

    func testEmptyQueryMatchesEverything() throws {
        let hit = try XCTUnwrap(FuzzyMatcher.match("", in: "anything"))
        XCTAssertEqual(hit.indices, [])
    }

    // MARK: Verb parsing

    func testParseVerbAndTarget() {
        let query = PaletteQuery.parse("stop db")
        XCTAssertEqual(query.verb, .stop)
        XCTAssertEqual(query.target, "db")
    }

    func testParseExtraSpaces() {
        let query = PaletteQuery.parse("  logs   api  ")
        XCTAssertEqual(query.verb, .logs)
        XCTAssertEqual(query.target, "api")
    }

    func testParseAliasesAndCase() {
        XCTAssertEqual(PaletteQuery.parse("RM old-thing").verb, .delete)
        XCTAssertEqual(PaletteQuery.parse("rm old-thing").target, "old-thing")
        XCTAssertEqual(PaletteQuery.parse("exec web").verb, .shell)
        XCTAssertEqual(PaletteQuery.parse("pull nginx:alpine").target, "nginx:alpine")
    }

    func testUnknownVerbFallsBackToSearch() {
        let query = PaletteQuery.parse("redis cache")
        XCTAssertNil(query.verb)
        XCTAssertEqual(query.target, "redis cache")
    }

    func testVerbOnly() {
        let query = PaletteQuery.parse("stop")
        XCTAssertEqual(query.verb, .stop)
        XCTAssertEqual(query.target, "")
        XCTAssertTrue(query.isVerbOnly)
        XCTAssertTrue(PaletteQuery.parse("restart ").isVerbOnly)
        XCTAssertFalse(PaletteQuery.parse("").isVerbOnly)
        XCTAssertNil(PaletteQuery.parse("   ").verb)
    }

    func testTabCompletion() {
        XCTAssertEqual(PaletteQuery.complete("sto"), "stop ")
        XCTAssertEqual(PaletteQuery.complete("l"), "logs ")
        XCTAssertEqual(PaletteQuery.complete("stop"), "stop ")
        XCTAssertNil(PaletteQuery.complete("stop "))
        XCTAssertNil(PaletteQuery.complete("zzz"))
        XCTAssertNil(PaletteQuery.complete(""))
    }

    func testVerbTargets() {
        XCTAssertTrue(PaletteVerb.logs.targetKinds.contains(.container))
        XCTAssertFalse(PaletteVerb.logs.targetKinds.contains(.image))
        XCTAssertTrue(PaletteVerb.pull.acceptsFreeText)
        XCTAssertFalse(PaletteVerb.stop.acceptsFreeText)
    }

    // MARK: Ranking

    private let entries = [
        PaletteEntry(id: "screen:images", kind: .screen, title: "Go to Images"),
        PaletteEntry(id: "container:web", kind: .container, title: "web", keywords: ["nginx:alpine"]),
        PaletteEntry(id: "container:webapp", kind: .container, title: "webapp"),
        PaletteEntry(id: "image:nginx", kind: .image, title: "nginx", subtitle: "alpine"),
        PaletteEntry(id: "volume:data", kind: .volume, title: "data"),
    ]

    func testRankByScore() {
        let ranked = PaletteRanker.rank(entries, query: "web")
        XCTAssertEqual(ranked.map(\.id), ["container:web", "container:webapp"])
        XCTAssertEqual(ranked.first?.highlights, [0..<3])
    }

    func testKeywordsMatchWithoutHighlight() {
        let ranked = PaletteRanker.rank(entries, query: "nginx")
        // Title hit first, keyword hit after.
        XCTAssertEqual(ranked.map(\.id), ["image:nginx", "container:web"])
        XCTAssertEqual(ranked[1].highlights, [])
    }

    func testEmptyQueryPutsRecentsFirst() {
        let ranked = PaletteRanker.rank(entries, query: "", recents: ["volume:data", "container:webapp"])
        XCTAssertEqual(ranked.map(\.id), ["volume:data", "container:webapp", "screen:images", "container:web", "image:nginx"])
        XCTAssertEqual(ranked.prefix(2).map(\.isRecent), [true, true])
    }

    func testRecentBreaksCloseScores() {
        let plain = PaletteRanker.rank(entries, query: "web")
        XCTAssertEqual(plain.first?.id, "container:web")
        // "wb" scores the same on both, so the recent one wins.
        let boosted = PaletteRanker.rank(entries, query: "wb", recents: ["container:webapp"])
        XCTAssertEqual(boosted.first?.id, "container:webapp")
    }

    func testRecentIgnoredWhenNoMatch() {
        let ranked = PaletteRanker.rank(entries, query: "zzz", recents: ["volume:data"])
        XCTAssertTrue(ranked.isEmpty)
    }

    func testWeakHitsAreDroppedNextToStrongOnes() {
        let list = [
            PaletteEntry(id: "image:nginx", kind: .image, title: "nginx:alpine"),
            PaletteEntry(id: "action:setup", kind: .action, title: "Open setup guide"),
        ]
        XCTAssertEqual(PaletteRanker.rank(list, query: "ng").map(\.id), ["image:nginx"])
        // On its own, a weak hit still shows.
        XCTAssertEqual(PaletteRanker.rank([list[1]], query: "ng").map(\.id), ["action:setup"])
    }

    func testSectionsWithQuery() {
        let ranked = PaletteRanker.rank(entries, query: "web")
        let sections = PaletteRanker.sections(ranked, hasQuery: true)
        XCTAssertEqual(sections.map(\.title), ["Top hit", "Containers"])
        XCTAssertEqual(sections[0].items.map(\.id), ["container:web"])
    }

    func testSectionsWithoutQuery() {
        let ranked = PaletteRanker.rank(entries, query: "", recents: ["image:nginx"])
        let sections = PaletteRanker.sections(ranked, hasQuery: false)
        XCTAssertEqual(sections.map(\.title), ["Recent", "Screens", "Containers", "Volumes"])
    }

    func testLimit() {
        XCTAssertEqual(PaletteRanker.rank(entries, query: "", limit: 2).count, 2)
    }

    func testRecentsStore() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PaletteTests-\(UUID().uuidString)"))
        let recents = PaletteRecents(defaults: defaults)
        recents.add("a")
        recents.add("b")
        recents.add("a")
        XCTAssertEqual(recents.ids, ["a", "b"])
        for index in 0..<20 { recents.add("x\(index)") }
        XCTAssertEqual(recents.ids.count, PaletteRecents.limit)
    }
}
