import XCTest
@testable import DeckCore

/// Import screen list rules: sections, search, counts, stale states and "In Apple's store".
final class ImportListRulesTests: XCTestCase {
    private func image(_ reference: String, engine: String = "orb", arch: String? = "arm64", here: Bool = false) -> EngineImage {
        EngineImage(engineID: engine, engineName: engine, imageID: "sha256:\(reference)", reference: reference,
                    architecture: arch, alreadyHere: here)
    }

    // MARK: Sections

    func testOneEngineStartsOpen() {
        XCTAssertEqual(ImportListRules.defaultExpanded([(id: "orb", count: 25)]), ["orb"])
        XCTAssertEqual(ImportListRules.defaultExpanded([(id: "orb", count: 25), (id: "docker", count: 0)]), ["orb"])
    }

    func testSeveralSmallEnginesAllStartOpen() {
        XCTAssertEqual(ImportListRules.defaultExpanded([(id: "orb", count: 9), (id: "rancher", count: 3)]), ["orb", "rancher"])
    }

    func testBigEngineStartsClosedSoSmallOnesShow() {
        // The owner's case: OrbStack 25, Rancher 1.
        XCTAssertEqual(ImportListRules.defaultExpanded([(id: "orb", count: 25), (id: "rancher", count: 1)]), ["rancher"])
        XCTAssertEqual(ImportListRules.defaultExpanded([(id: "a", count: 30), (id: "b", count: 8), (id: "c", count: 9)]), ["b"])
    }

    func testAllBigEnginesStartClosed() {
        XCTAssertEqual(ImportListRules.defaultExpanded([(id: "a", count: 20), (id: "b", count: 40)]), [])
    }

    func testSavedChoiceWinsOverDefault() {
        let defaults: Set<String> = ["rancher"]
        XCTAssertTrue(ImportListRules.isExpanded("rancher", saved: [:], defaults: defaults))
        XCTAssertFalse(ImportListRules.isExpanded("orb", saved: [:], defaults: defaults))
        XCTAssertTrue(ImportListRules.isExpanded("orb", saved: ["orb": true], defaults: defaults))
        XCTAssertFalse(ImportListRules.isExpanded("rancher", saved: ["rancher": false], defaults: defaults))
    }

    // MARK: Search

    func testSearchMatchesNameAndTag() {
        let list = [image("nginx:latest"), image("postgres:16-alpine"), image("ghcr.io/acme/api:1.2"), image("redis:7-alpine")]
        XCTAssertEqual(ImportListRules.filter(list, query: "").count, 4)
        XCTAssertEqual(ImportListRules.filter(list, query: "  ").count, 4)
        XCTAssertEqual(ImportListRules.filter(list, query: "NGINX").map(\.reference), ["nginx:latest"])
        XCTAssertEqual(ImportListRules.filter(list, query: "alpine").map(\.reference), ["postgres:16-alpine", "redis:7-alpine"])
        XCTAssertEqual(ImportListRules.filter(list, query: "acme").map(\.reference), ["ghcr.io/acme/api:1.2"])
        XCTAssertEqual(ImportListRules.filter(list, query: "redis 7").map(\.reference), ["redis:7-alpine"])
        XCTAssertTrue(ImportListRules.filter(list, query: "mysql").isEmpty)
    }

    // MARK: Counts

    func testSelectedCountsAndText() {
        let list = [image("a:1"), image("b:1"), image("c:1", here: true)]
        let selection: Set<String> = [list[0].id, list[2].id, "other|x:1"]
        XCTAssertEqual(ImportListRules.selectedCount(list, selection: selection), 2)
        XCTAssertEqual(ImportListRules.selectable(list).map(\.reference), ["a:1", "b:1"])
        XCTAssertEqual(ImportListRules.countText(selected: 0, total: 25), "25 images")
        XCTAssertEqual(ImportListRules.countText(selected: 0, total: 1), "1 image")
        XCTAssertEqual(ImportListRules.countText(selected: 3, total: 25), "3 of 25 selected")
    }

    // MARK: Stale states

    func testCancelledRunKeepsOnlyResults() {
        let steps: [String: ImportStep] = [
            "a": .done(method: "Pulled from the registry"), "b": .failed("No space"), "c": .cancelled,
            "d": .waiting, "e": .exporting(done: 1, total: 2), "f": .pulling("layer")
        ]
        let kept = ImportListRules.keepingResults(steps)
        XCTAssertEqual(Set(kept.keys), ["a", "b"])
    }

    func testDoneGoesAwayWhenImageWasDeleted() {
        let gone = image("node:24-alpine", here: false)
        let still = image("redis:7-alpine", here: true)
        let steps: [String: ImportStep] = [
            gone.id: .done(method: "Pulled from the registry"),
            still.id: .done(method: "Pulled from the registry"),
            "x": .failed("No space")
        ]
        let kept = ImportListRules.droppingGoneResults(steps, images: [gone, still])
        XCTAssertNil(kept[gone.id])
        XCTAssertEqual(kept[still.id], .done(method: "Pulled from the registry"))
        XCTAssertEqual(kept["x"], .failed("No space"))
    }

    // MARK: In Apple's store

    func testPresenceFollowsTheCurrentImageList() {
        let node = image("node:24.22.1-alpine")
        let local = [ImageSummary(reference: "docker.io/library/node:24.22.1-alpine", platforms: ["linux/arm64/v8", "linux/amd64"])]
        XCTAssertTrue(ImportListRules.isInStore(node, local: local))
        XCTAssertTrue(ImportListRules.markPresence([node], local: local)[0].alreadyHere)

        // Deleted from Apple's store afterwards: selectable again, even if it was marked before.
        var marked = node
        marked.alreadyHere = true
        XCTAssertFalse(ImportListRules.markPresence([marked], local: []).first!.alreadyHere)
    }

    func testPresenceChecksTheArchitectureWhenKnown() {
        let intel = image("postgres:16-alpine", arch: "amd64")
        let armOnly = [ImageSummary(reference: "docker.io/library/postgres:16-alpine", platforms: ["linux/arm64/v8"])]
        XCTAssertFalse(ImportListRules.isInStore(intel, local: armOnly))
        let x86 = [ImageSummary(reference: "docker.io/library/postgres:16-alpine", platforms: ["linux/x86_64"])]
        XCTAssertTrue(ImportListRules.isInStore(intel, local: x86))
        // Unknown on either side: the reference decides.
        XCTAssertTrue(ImportListRules.isInStore(image("postgres:16-alpine", arch: nil), local: armOnly))
        let noPlatforms = [ImageSummary(reference: "postgres:16-alpine")]
        XCTAssertTrue(ImportListRules.isInStore(intel, local: noPlatforms))
    }

    func testPresenceNeedsTheSameTag() {
        let local = [ImageSummary(reference: "docker.io/library/redis:7-alpine", platforms: ["linux/arm64"])]
        XCTAssertFalse(ImportListRules.isInStore(image("redis:8-alpine"), local: local))
        XCTAssertTrue(ImportListRules.isInStore(image("library/redis:7-alpine"), local: local))
    }
}
