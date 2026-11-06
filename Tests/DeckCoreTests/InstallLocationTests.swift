import XCTest
import Darwin
@testable import DeckCore

final class InstallLocationTests: XCTestCase {
    func testClassifiesCommonPlaces() {
        let home = "/Users/me"
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Applications/Container Deck.app", home: home), .applications)
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Users/me/Applications/Container Deck.app", home: home), .applications)
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Container Deck.app", home: home), .translocated)
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Volumes/Container Deck/Container Deck.app", home: home), .diskImage)
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Users/me/Downloads/Container Deck.app", home: home), .downloads)
        XCTAssertEqual(InstallLocation.classify(bundlePath: "/Users/me/Desktop/build/Container Deck.app", home: home), .other)
    }

    func testOnlyTemporaryPlacesOfferAMove() {
        XCTAssertTrue(InstallLocation.translocated.shouldOfferMove)
        XCTAssertTrue(InstallLocation.diskImage.shouldOfferMove)
        XCTAssertTrue(InstallLocation.downloads.shouldOfferMove)
        XCTAssertFalse(InstallLocation.applications.shouldOfferMove)
        XCTAssertFalse(InstallLocation.other.shouldOfferMove)
    }

    func testRemovesQuarantineFromTheWholeBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deck-qtn-\(UUID().uuidString).app")
        let inner = root.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let binary = inner.appendingPathComponent("ContainerDeck")
        try Data("x".utf8).write(to: binary)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = "0181;6aed86e5;Chrome;"
        for path in [root.path, binary.path] {
            XCTAssertEqual(setxattr(path, InstallLocation.quarantineAttribute, value, value.utf8.count, 0, XATTR_NOFOLLOW), 0)
        }
        XCTAssertTrue(InstallLocation.isQuarantined(root.path))
        XCTAssertEqual(InstallLocation.removeQuarantine(at: root.path), 2)
        XCTAssertFalse(InstallLocation.isQuarantined(root.path))
        XCTAssertFalse(InstallLocation.isQuarantined(binary.path))
        XCTAssertEqual(InstallLocation.removeQuarantine(at: root.path), 0, "nothing left to remove")
    }
}
