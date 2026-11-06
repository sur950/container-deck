import XCTest
import DeckCore
@testable import ContainerDeck

/// App side of the v2 polish work: bulk confirmations, the Mounts tab and paths.
final class PolishAppTests: XCTestCase {
    func testBulkConfirmationRules() {
        XCTAssertTrue(ContainerBulk.needsConfirmation(.stop, count: 2))
        XCTAssertTrue(ContainerBulk.needsConfirmation(.restart, count: 3))
        XCTAssertTrue(ContainerBulk.needsConfirmation(.kill, count: 2))
        XCTAssertFalse(ContainerBulk.needsConfirmation(.stop, count: 1))
        XCTAssertFalse(ContainerBulk.needsConfirmation(.start, count: 5))
        // Delete has its own dialog for any count.
        XCTAssertFalse(ContainerBulk.needsConfirmation(.delete, count: 5))
    }

    func testBulkCopy() {
        XCTAssertEqual(ContainerBulk.title(.stop, count: 3), "Stop 3 containers?")
        let names = (1...7).map { "c\($0)" }
        let message = ContainerBulk.message(.restart, names: names)
        XCTAssertTrue(message.contains("c1, c2, c3, c4, c5 and 2 more"))
        for op in ContainerOp.allCases {
            let text = ContainerBulk.message(op, names: ["a", "b"])
            XCTAssertFalse(text.contains(";") || text.contains("\u{2014}"), text)
        }
    }

    func testMountsTabIsATab() {
        XCTAssertEqual(ContainerDetailTab(rawValue: "mounts"), .mounts)
        XCTAssertEqual(ContainerDetailTab.mounts.title, "Mounts")
    }

    func testMountPaths() {
        let home = NSHomeDirectory()
        XCTAssertEqual(ContainerText.tildePath(home + "/src/app"), "~/src/app")
        XCTAssertEqual(ContainerText.tildePath("/opt/x"), "/opt/x")
        XCTAssertNil(MountPaths.hostURL(for: MountInfo(type: "volume", source: "data", destination: "/d")))
        XCTAssertNil(MountPaths.hostURL(for: MountInfo(type: "bind", source: "/no/such/folder/deck", destination: "/d")))
        XCTAssertEqual(MountPaths.hostURL(for: MountInfo(type: "bind", source: NSTemporaryDirectory(), destination: "/d"))?.path,
                       URL(fileURLWithPath: NSTemporaryDirectory()).path)
    }
}
