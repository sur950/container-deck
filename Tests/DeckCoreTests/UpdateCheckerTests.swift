import XCTest
@testable import DeckCore

final class UpdateCheckerTests: XCTestCase {

    private let sampleJSON = """
    {
      "tag_name": "v1.2.0",
      "name": "Container Deck 1.2.0",
      "body": "## New\\n- Menu bar panel\\n- Crash alerts",
      "html_url": "https://github.com/sur950/container-deck/releases/tag/v1.2.0",
      "published_at": "2026-11-01T10:00:00Z",
      "prerelease": false,
      "draft": false,
      "assets": [
        {"name": "ContainerDeck-1.2.0.dmg.sha256", "browser_download_url": "https://example.com/a.sha256", "size": 90},
        {"name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/sums.txt", "size": 120},
        {"name": "ContainerDeck-1.2.0.dmg", "browser_download_url": "https://example.com/ContainerDeck-1.2.0.dmg", "size": 12345678}
      ]
    }
    """

    func testParseRelease() throws {
        let release = try UpdateChecker.parseRelease(Data(sampleJSON.utf8))
        XCTAssertEqual(release.version, ReleaseVersion(1, 2, 0))
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.title, "Container Deck 1.2.0")
        XCTAssertTrue(release.notes.contains("Crash alerts"))
        XCTAssertEqual(release.assets.count, 3)
        XCTAssertEqual(release.diskImage?.name, "ContainerDeck-1.2.0.dmg")
        XCTAssertEqual(release.downloadURL.absoluteString, "https://example.com/ContainerDeck-1.2.0.dmg")
        XCTAssertNotNil(release.publishedAt)
        XCTAssertFalse(release.isPrerelease)
    }

    func testReleaseWithoutDiskImageFallsBackToPage() throws {
        let json = """
        {"tag_name":"1.0.0","name":null,"body":null,
         "html_url":"https://github.com/sur950/container-deck/releases/tag/1.0.0",
         "published_at":null,"assets":[]}
        """
        let release = try UpdateChecker.parseRelease(Data(json.utf8))
        XCTAssertNil(release.diskImage)
        XCTAssertEqual(release.downloadURL.absoluteString, "https://github.com/sur950/container-deck/releases/tag/1.0.0")
        XCTAssertEqual(release.title, "Container Deck 1.0.0")
        XCTAssertEqual(release.notes, "")
    }

    func testUnreadableTagThrows() {
        let json = """
        {"tag_name":"nightly","html_url":"https://github.com/sur950/container-deck/releases/tag/nightly","assets":[]}
        """
        XCTAssertThrowsError(try UpdateChecker.parseRelease(Data(json.utf8))) { error in
            XCTAssertEqual(error as? UpdateCheckError, .unreadableVersion("nightly"))
        }
    }

    func testPickDiskImagePrefersAppleSilicon() {
        let url = URL(fileURLWithPath: "/tmp/x")
        let assets = [
            ReleaseAsset(name: "ContainerDeck-1.0.0-x86_64.dmg", url: url),
            ReleaseAsset(name: "ContainerDeck-1.0.0-arm64.dmg", url: url),
            ReleaseAsset(name: "notes.txt", url: url)
        ]
        XCTAssertEqual(UpdateChecker.pickDiskImage(assets)?.name, "ContainerDeck-1.0.0-arm64.dmg")
        XCTAssertNil(UpdateChecker.pickDiskImage([ReleaseAsset(name: "a.zip", url: url)]))
    }

    func testVersionParsing() {
        XCTAssertEqual(ReleaseVersion("v1.2.3"), ReleaseVersion(1, 2, 3))
        XCTAssertEqual(ReleaseVersion("1.2"), ReleaseVersion(1, 2, 0))
        XCTAssertEqual(ReleaseVersion(" 2 "), ReleaseVersion(2, 0, 0))
        XCTAssertEqual(ReleaseVersion("1.3.0-beta.2+77"), ReleaseVersion(1, 3, 0, prerelease: ["beta", "2"]))
        XCTAssertEqual(ReleaseVersion("1.3.0-beta.2")?.description, "1.3.0-beta.2")
        XCTAssertNil(ReleaseVersion("dev"))
        XCTAssertNil(ReleaseVersion("1.2.3.4"))
        XCTAssertNil(ReleaseVersion("1..2"))
        XCTAssertNil(ReleaseVersion("1.2.3-"))
        XCTAssertNil(ReleaseVersion("+1.2"))
    }

    func testVersionOrdering() {
        func v(_ text: String) -> ReleaseVersion {
            guard let version = ReleaseVersion(text) else {
                XCTFail("Could not parse \(text)")
                return ReleaseVersion(0)
            }
            return version
        }
        XCTAssertLessThan(v("0.9.9"), v("1.0.0"))
        XCTAssertLessThan(v("1.0.0"), v("1.0.1"))
        XCTAssertLessThan(v("1.9.0"), v("1.10.0"))
        XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0"))
        XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-alpha.1"))
        XCTAssertLessThan(v("1.0.0-alpha.1"), v("1.0.0-beta"))
        XCTAssertLessThan(v("1.0.0-beta.2"), v("1.0.0-beta.11"))
        XCTAssertLessThan(v("1.0.0-rc.1"), v("1.0.0"))
        XCTAssertFalse(v("1.0.0") < v("1.0.0"))
        XCTAssertEqual(v("v1.0"), v("1.0.0"))
    }

    func testEvaluate() throws {
        let latest = try UpdateChecker.parseRelease(Data(sampleJSON.utf8))
        XCTAssertTrue(UpdateChecker.evaluate(latest: latest, currentVersion: "1.1.9").isUpdateAvailable)
        XCTAssertTrue(UpdateChecker.evaluate(latest: latest, currentVersion: "1.2.0-rc.1").isUpdateAvailable)
        XCTAssertFalse(UpdateChecker.evaluate(latest: latest, currentVersion: "1.2.0").isUpdateAvailable)
        XCTAssertFalse(UpdateChecker.evaluate(latest: latest, currentVersion: "2.0.0").isUpdateAvailable)
        // A build without a version (swift run) never claims an update.
        let unknown = UpdateChecker.evaluate(latest: latest, currentVersion: nil)
        XCTAssertNil(unknown.current)
        XCTAssertFalse(unknown.isUpdateAvailable)
        XCTAssertFalse(UpdateChecker.evaluate(latest: latest, currentVersion: "dev").isUpdateAvailable)
    }
}
