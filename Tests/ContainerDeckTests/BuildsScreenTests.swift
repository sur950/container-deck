import XCTest
import DeckCore
@testable import ContainerDeck

@MainActor
final class BuildsScreenTests: XCTestCase {
    private func record(_ status: BuildStatus, tags: [String] = ["deck-v2-bld-ok:arm64"]) -> BuildRecord {
        BuildRecord(spec: BuildSpec(BuildOptions(contextDir: "/tmp/x", tags: tags)), status: status, origin: .buildsScreen)
    }

    func testDurationText() {
        XCTAssertEqual(BuildText.duration(0.24), "0.2 s")
        XCTAssertEqual(BuildText.duration(42), "42 s")
        XCTAssertEqual(BuildText.duration(60), "1 min")
        XCTAssertEqual(BuildText.duration(125), "2 min 5 s")
        XCTAssertEqual(BuildText.duration(3 * 3600 + 120), "3 h 2 min")
    }

    func testStartedTextNeverReadsInTheFuture() {
        let now = Date()
        XCTAssertEqual(BuildText.started(now.addingTimeInterval(0.3), now: now), "Just now")
        XCTAssertEqual(BuildText.started(now.addingTimeInterval(-2), now: now), "Just now")
    }

    func testOriginText() {
        var compose = record(.succeeded)
        compose.origin = .compose
        compose.originDetail = "web"
        XCTAssertEqual(BuildText.origin(compose), "Compose, web")
        XCTAssertEqual(BuildText.origin(record(.failed)), "Builds")
    }

    func testFilters() {
        XCTAssertTrue(BuildsFilter.all.matches(record(.cancelled)))
        XCTAssertTrue(BuildsFilter.running.matches(record(.running)))
        XCTAssertFalse(BuildsFilter.running.matches(record(.succeeded)))
        XCTAssertTrue(BuildsFilter.failed.matches(record(.failed)))
        XCTAssertFalse(BuildsFilter.failed.matches(record(.interrupted)))
    }

    func testContainersUsingABuild() {
        let containers = [
            ContainerSummary(id: "a", name: "a", image: "docker.io/library/deck-v2-bld-ok:arm64", state: .running),
            ContainerSummary(id: "b", name: "b", image: "docker.io/library/alpine:latest", state: .running)
        ]
        XCTAssertEqual(BuildActions.users(of: record(.succeeded), in: containers).map(\.id), ["a"])
        XCTAssertEqual(BuildActions.users(of: record(.failed), in: containers), [], "A failed build made no image")
    }

    func testRunUsesAmd64ForAmd64Builds() {
        let state = AppState()
        var amd = record(.succeeded)
        amd.spec.platform = "linux/amd64"
        BuildActions.run(amd, state: state)
        XCTAssertEqual(state.runRequest?.options.platform, "linux/amd64")
        BuildActions.run(record(.succeeded), state: state)
        XCTAssertNil(state.runRequest?.options.platform, "Native builds run without a platform")
    }

    func testOpenImageGoesThroughTheDeepLinkRoute() {
        let state = AppState()
        BuildActions.openImage("deck-v2-bld-ok:arm64", state: state)
        XCTAssertEqual(state.selection, .images)
        XCTAssertEqual(state.focusedImageRef, "deck-v2-bld-ok:arm64")
    }

    func testStoreMirrorsTheCenter() async {
        let center = BuildCenter(store: .memoryOnly)
        let store = BuildsStore(center: center)
        XCTAssertEqual(store.records, [])
        let client = ContainerClient(cliPath: "/usr/bin/false")
        let id = store.start(BuildOptions(contextDir: "/nonexistent", tags: ["deck-v2-bld-none:1"]), client: client)
        XCTAssertEqual(store.record(id)?.status, .running)
        let end = Date().addingTimeInterval(5)
        while store.record(id)?.status == .running && Date() < end {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(store.record(id)?.status, .failed, "/usr/bin/false exits 1")
        store.remove([id])
        XCTAssertNil(store.record(id))
    }
}
