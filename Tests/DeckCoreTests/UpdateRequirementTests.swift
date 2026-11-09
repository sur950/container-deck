import XCTest
@testable import DeckCore

final class UpdateRequirementTests: XCTestCase {

    private func v(_ text: String) -> ReleaseVersion {
        guard let version = ReleaseVersion(text) else {
            XCTFail("bad version \(text)")
            return ReleaseVersion(0)
        }
        return version
    }

    private func release(_ version: String, notes: String = "### Fixed\n\n- Something.", prerelease: Bool = false) -> AppRelease {
        AppRelease(
            version: v(version), tagName: "v\(version)", title: "Container Deck \(version)", notes: notes,
            pageURL: URL(string: "https://github.com/sur950/container-deck/releases/tag/v\(version)")!,
            publishedAt: nil, isPrerelease: prerelease,
            assets: [ReleaseAsset(name: "ContainerDeck.dmg", url: URL(string: "https://example.com/ContainerDeck.dmg")!)]
        )
    }

    private func evaluate(_ current: String?, _ releases: [AppRelease], enabled: Bool = true) -> UpdateRequirement? {
        UpdateRequirementRule.evaluate(current: current.flatMap { ReleaseVersion($0) }, releases: releases, enabled: enabled)
    }

    private let required = "<!-- deck-update: required -->\n\n### Fixed\n\n- Critical fix."

    // MARK: Rule

    func testMajorBumpIsBreaking() {
        let result = evaluate("1.2.1", [release("2.0.0")])
        XCTAssertEqual(result?.reason, .breaking)
        XCTAssertEqual(result?.minimumVersion, v("2.0.0"))
        XCTAssertEqual(result?.requiredBy, v("2.0.0"))
        // Any 2.x satisfies the major rule.
        XCTAssertEqual(evaluate("1.9.9", [release("2.3.1")])?.minimumVersion, v("2.0.0"))
    }

    func testMinorAndPatchReleasesAreNotRequired() {
        XCTAssertNil(evaluate("1.2.1", [release("1.3.0"), release("1.2.2")]))
    }

    func testMarkedReleaseIsCritical() {
        let result = evaluate("1.2.1", [release("1.2.2", notes: required)])
        XCTAssertEqual(result?.reason, .critical)
        XCTAssertEqual(result?.minimumVersion, v("1.2.2"))
    }

    func testRequiredBelowOnlyCatchesOlderVersions() {
        let notes = "<!-- deck-update: required-below 1.2.4 -->\n- Fix."
        let releases = [release("1.3.0", notes: notes)]
        let below = evaluate("1.2.1", releases)
        XCTAssertEqual(below?.reason, .critical)
        XCTAssertEqual(below?.minimumVersion, v("1.2.4"))
        XCTAssertNil(evaluate("1.2.4", releases))
        XCTAssertNil(evaluate("1.2.9", releases))
        // A bound above the release itself still only asks for that release.
        XCTAssertEqual(evaluate("1.2.1", [release("1.2.3", notes: "<!-- deck-update: required-below 9.0.0 -->")])?.minimumVersion, v("1.2.3"))
    }

    func testRequiredReleaseFollowedByNewerUnmarkedOne() {
        let releases = [release("1.3.1"), release("1.3.0", notes: required), release("1.2.1")]
        let result = evaluate("1.2.1", releases)
        XCTAssertEqual(result?.reason, .critical)
        XCTAssertEqual(result?.minimumVersion, v("1.3.0"))
        // Once on 1.3.0, the unmarked 1.3.1 is a normal update.
        XCTAssertNil(evaluate("1.3.0", releases))
    }

    func testSameVersionIsNotRequired() {
        XCTAssertNil(evaluate("2.0.0", [release("2.0.0", notes: required)]))
    }

    func testOlderReleaseIsNotRequired() {
        XCTAssertNil(evaluate("2.1.0", [release("2.0.0", notes: required), release("1.0.0")]))
        XCTAssertNil(evaluate("1.3.0", [release("1.2.4", notes: required)]))
    }

    func testBreakingWinsOverCritical() {
        let result = evaluate("1.2.1", [release("2.0.0"), release("1.2.2", notes: required)])
        XCTAssertEqual(result?.reason, .breaking)
        XCTAssertEqual(result?.minimumVersion, v("2.0.0"))
    }

    func testPrereleasesUnknownVersionsAndTheSwitch() {
        XCTAssertNil(evaluate("1.2.1", [release("2.0.0-beta.1", prerelease: true)]))
        XCTAssertNil(evaluate(nil, [release("2.0.0")]))
        XCTAssertNil(evaluate("dev", [release("2.0.0")]))
        XCTAssertNil(evaluate("1.2.1", [release("2.0.0")], enabled: false))
        // A pre-release of the running app updates to the final release only when it is required.
        XCTAssertNil(evaluate("1.3.0-beta.1", [release("1.3.0")]))
        XCTAssertNotNil(evaluate("1.3.0-beta.1", [release("1.3.0", notes: required)]))
    }

    func testReleaseListIsReadOnlyWhenNeeded() {
        let current = v("1.2.1")
        XCTAssertFalse(UpdateRequirementRule.needsReleaseList(current: current, latest: release("1.2.1"), enabled: true))
        XCTAssertFalse(UpdateRequirementRule.needsReleaseList(current: current, latest: release("2.0.0"), enabled: true))
        XCTAssertFalse(UpdateRequirementRule.needsReleaseList(current: current, latest: release("1.3.1", notes: required), enabled: true))
        XCTAssertTrue(UpdateRequirementRule.needsReleaseList(current: current, latest: release("1.3.1"), enabled: true))
        XCTAssertFalse(UpdateRequirementRule.needsReleaseList(current: nil, latest: release("1.3.1"), enabled: true))
        XCTAssertFalse(UpdateRequirementRule.needsReleaseList(current: current, latest: release("1.3.1"), enabled: false))
    }

    func testEvaluateAddsTheRequirement() {
        let result = UpdateChecker.evaluate(latest: release("1.3.1"), currentVersion: "1.2.1",
                                            releases: [release("1.3.0", notes: required)])
        XCTAssertTrue(result.isUpdateAvailable)
        XCTAssertEqual(result.requirement?.minimumVersion, v("1.3.0"))
        XCTAssertTrue(result.requirementIsComplete)
        XCTAssertNil(UpdateChecker.evaluate(latest: release("1.3.1"), currentVersion: "1.2.1").requirement)
    }

    // MARK: The setting and Later cannot turn it off

    func testAutomaticCheckSettingCannotTurnItOff() {
        XCTAssertEqual(RequiredUpdatePolicy.launchCheck(automaticChecks: true, enabled: true), .automatic)
        XCTAssertEqual(RequiredUpdatePolicy.launchCheck(automaticChecks: false, enabled: true), .requiredOnly)
        XCTAssertEqual(RequiredUpdatePolicy.launchCheck(automaticChecks: false, enabled: false), .none)
    }

    func testSkippedVersionDoesNotHideARequiredUpdate() {
        let result = UpdateChecker.evaluate(latest: release("2.0.0"), currentVersion: "1.2.1")
        XCTAssertFalse(UpdatePolicy.shouldOffer(result, skippedVersion: "2.0.0"))
        XCTAssertEqual(result.requirement?.reason, AppConfig.requiredUpdatesEnabled ? .breaking : nil)
    }

    // MARK: Marker

    func testMarkerParsing() {
        XCTAssertEqual(UpdateMarker.parse("<!-- deck-update: required -->"), .required)
        XCTAssertEqual(UpdateMarker.parse("<!--deck-update:required-->"), .required)
        XCTAssertEqual(UpdateMarker.parse("x\n  <!-- DECK-UPDATE: Required -->\ny"), .required)
        XCTAssertEqual(UpdateMarker.parse("<!-- deck-update: required-below 1.2.4 -->"), .requiredBelow(v("1.2.4")))
        XCTAssertEqual(UpdateMarker.parse("<!-- deck-update: required-below v2.0 -->"), .requiredBelow(v("2.0.0")))
        XCTAssertNil(UpdateMarker.parse("<!-- deck-update: requird -->"))
        XCTAssertNil(UpdateMarker.parse("<!-- deck-update: required-below soon -->"))
        XCTAssertNil(UpdateMarker.parse("<!-- diagram: overview -->"))
        XCTAssertNil(UpdateMarker.parse("deck-update: required"))
        XCTAssertNil(UpdateMarker.parse(""))
    }

    func testMarkerFromARealReleaseBody() throws {
        // What scripts/release_notes.sh prints into the GitHub release, as the API returns it.
        let body = """
        <!-- deck-update: required-below 1.2.4 -->

        ### Fixed

        - **Security:** registry passwords are no longer written to the build log.

        ## Install

        **Terminal**, any account, no admin password and no security prompt:

        ```bash
        curl -fsSL https://github.com/sur950/container-deck/releases/latest/download/ContainerDeck.dmg -o /tmp/ContainerDeck.dmg
        ```
        """
        let object: [String: Any] = [
            "tag_name": "v1.3.0", "name": "Container Deck 1.3.0", "body": body.replacingOccurrences(of: "\n", with: "\r\n"),
            "html_url": "https://github.com/sur950/container-deck/releases/tag/v1.3.0",
            "published_at": "2026-12-01T10:00:00Z", "prerelease": false, "draft": false, "assets": [] as [Any]
        ]
        let single = try JSONSerialization.data(withJSONObject: object)
        let parsed = try UpdateChecker.parseRelease(single)
        XCTAssertEqual(UpdateMarker.parse(parsed.notes), .requiredBelow(v("1.2.4")))
        XCTAssertEqual(evaluate("1.2.1", [parsed])?.minimumVersion, v("1.2.4"))

        // The list endpoint: drafts and odd tags are skipped, the marker still reads.
        var draft = object
        draft["tag_name"] = "v1.4.0"
        draft["draft"] = true
        var nightly = object
        nightly["tag_name"] = "nightly"
        let list = try JSONSerialization.data(withJSONObject: [draft, object, nightly])
        let releases = try UpdateChecker.parseReleaseList(list)
        XCTAssertEqual(releases.map(\.version), [v("1.3.0")])
        XCTAssertEqual(UpdateMarker.parse(releases[0].notes), .requiredBelow(v("1.2.4")))
    }

    func testStripRemovesOnlyMarkers() {
        let notes = "<!-- deck-update: required -->\n### Fixed\n\n- A fix.\n<!-- other -->\n"
        XCTAssertEqual(UpdateMarker.strip(notes), "### Fixed\n\n- A fix.\n<!-- other -->\n")
    }

    // MARK: Remembered for offline launches

    private func makeStore() -> (RequiredUpdateStore, UserDefaults) {
        let suite = "deck-required-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (RequiredUpdateStore(defaults: defaults), defaults)
    }

    private func remembered(_ minimum: String = "1.3.0") -> RequiredUpdate {
        RequiredUpdate(minimumVersion: minimum, version: "1.3.1", reason: .critical,
                       pageURL: URL(string: "https://github.com/sur950/container-deck/releases/tag/v1.3.1"), notes: "- Fix.")
    }

    func testRememberedUpdateShowsUntilTheAppIsUpdated() {
        let (store, defaults) = makeStore()
        store.save(remembered())
        // Offline launch on the old version: still blocked, and still remembered.
        XCTAssertEqual(store.load(current: v("1.2.1"), enabled: true), remembered())
        XCTAssertEqual(store.load(current: v("1.2.1"), enabled: true)?.version, "1.3.1")
        // The switch off never blocks, and keeps the record.
        XCTAssertNil(store.load(current: v("1.2.1"), enabled: false))
        // A dev build (no version) is not blocked and does not clear it.
        XCTAssertNil(store.load(current: nil, enabled: true))
        XCTAssertNotNil(defaults.data(forKey: RequiredUpdateStore.defaultsKey))
        // At the minimum version: cleared for good.
        XCTAssertNil(store.load(current: v("1.3.0"), enabled: true))
        XCTAssertNil(defaults.data(forKey: RequiredUpdateStore.defaultsKey))
        XCTAssertNil(store.load(current: v("1.2.1"), enabled: true))
    }

    func testRememberedUpdateClearsAboveTheMinimum() {
        let (store, defaults) = makeStore()
        store.save(remembered())
        XCTAssertNil(store.load(current: v("2.0.0"), enabled: true))
        XCTAssertNil(defaults.data(forKey: RequiredUpdateStore.defaultsKey))
    }

    func testDamagedRecordIsDropped() {
        let (store, defaults) = makeStore()
        defaults.set(Data("nope".utf8), forKey: RequiredUpdateStore.defaultsKey)
        XCTAssertNil(store.load(current: v("1.0.0"), enabled: true))
        XCTAssertNil(defaults.data(forKey: RequiredUpdateStore.defaultsKey))
    }

    func testRecordAfterACheck() {
        let (store, _) = makeStore()
        // A check that finds a compulsory update remembers it.
        let found = UpdateChecker.evaluate(latest: release("1.3.1"), currentVersion: "1.2.1",
                                           releases: [release("1.3.0", notes: required)])
        let shown = store.record(found, enabled: true)
        XCTAssertEqual(shown?.minimumVersion, "1.3.0")
        XCTAssertEqual(shown?.version, "1.3.1")
        XCTAssertEqual(shown?.reason, .critical)
        XCTAssertEqual(store.load(current: v("1.2.1"), enabled: true), shown)

        // The releases list failed: keep what was remembered.
        let partial = UpdateChecker.evaluate(latest: release("1.3.1"), currentVersion: "1.2.1", requirementIsComplete: false)
        XCTAssertEqual(store.record(partial, enabled: true), shown)
        XCTAssertNotNil(store.load(current: v("1.2.1"), enabled: true))

        // A full check that finds nothing required (for example the marker was removed) forgets it.
        let clean = UpdateChecker.evaluate(latest: release("1.3.1"), currentVersion: "1.2.1", releases: [release("1.3.0")])
        XCTAssertNil(store.record(clean, enabled: true))
        XCTAssertNil(store.load(current: v("1.2.1"), enabled: true))
    }

    func testRequiredUpdateBlocks() {
        XCTAssertTrue(remembered().blocks(current: v("1.2.9")))
        XCTAssertFalse(remembered().blocks(current: v("1.3.0")))
        XCTAssertFalse(remembered().blocks(current: nil))
        XCTAssertFalse(remembered("garbage").blocks(current: v("1.0.0")))
    }

    // MARK: scripts/release_notes.sh

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func runReleaseNotes(_ changelog: String, version: String) throws -> (code: Int32, out: String, err: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("CHANGELOG.md")
        try changelog.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repoRoot.appendingPathComponent("scripts/release_notes.sh").path, version]
        var environment = ProcessInfo.processInfo.environment
        environment["CHANGELOG_FILE"] = file.path
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    func testReleaseNotesScriptKeepsTheMarker() throws {
        let script = repoRoot.appendingPathComponent("scripts/release_notes.sh").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script), "scripts/release_notes.sh not found")
        let changelog = """
        # Changelog

        ## [9.1.0] - 2026-12-01

        <!-- deck-update: required-below 9.0.4 -->

        ### Fixed

        - A critical fix.

        ## [9.0.0] - 2026-11-01

        <!-- deck-update: required -->

        - Older.

        [9.1.0]: https://example.com
        """
        let run = try runReleaseNotes(changelog, version: "v9.1.0")
        XCTAssertEqual(run.code, 0, run.err)
        XCTAssertTrue(run.out.hasPrefix("<!-- deck-update: required-below 9.0.4 -->\n"), run.out)
        XCTAssertTrue(run.out.contains("- A critical fix."))
        XCTAssertFalse(run.out.contains("Older"))
        XCTAssertTrue(run.out.contains("## Install"))
        // The body the app gets reads as the same marker.
        XCTAssertEqual(UpdateMarker.parse(run.out), .requiredBelow(v("9.0.4")))

        let unmarked = try runReleaseNotes("## [9.2.0] - x\n\n- Small fix.\n", version: "9.2.0")
        XCTAssertEqual(unmarked.code, 0, unmarked.err)
        XCTAssertNil(UpdateMarker.parse(unmarked.out))
    }

    func testReleaseNotesScriptRejectsATypo() throws {
        let script = repoRoot.appendingPathComponent("scripts/release_notes.sh").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script), "scripts/release_notes.sh not found")
        let run = try runReleaseNotes("## [9.3.0] - x\n\n<!-- deck-update: requird -->\n- Fix.\n", version: "9.3.0")
        XCTAssertNotEqual(run.code, 0)
        XCTAssertTrue(run.err.contains("unknown update marker"), run.err)
    }

    func testCurrentChangelogDoesNotMark121() throws {
        let changelog = try String(contentsOf: repoRoot.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        guard let start = changelog.range(of: "## [1.2.1]") else { throw XCTSkip("no 1.2.1 section") }
        let rest = changelog[start.upperBound...]
        let section = rest.range(of: "\n## [").map { rest[..<$0.lowerBound] } ?? rest
        XCTAssertNil(UpdateMarker.parse(String(section)))
    }
}
