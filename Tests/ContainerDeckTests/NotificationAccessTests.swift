import XCTest
import UserNotifications
@testable import ContainerDeck
import DeckCore

final class NotificationAccessTests: XCTestCase {

    func testStatusMapping() {
        XCTAssertEqual(NotificationAccess.from(.notDetermined, bundled: true), .notAsked)
        XCTAssertEqual(NotificationAccess.from(.denied, bundled: true), .denied)
        XCTAssertEqual(NotificationAccess.from(.authorized, bundled: true), .allowed)
        XCTAssertEqual(NotificationAccess.from(.provisional, bundled: true), .allowed)
        // swift run has no bundle: nothing else matters.
        XCTAssertEqual(NotificationAccess.from(.authorized, bundled: false), .unavailable)
        XCTAssertEqual(NotificationAccess.from(.notDetermined, bundled: false), .unavailable)
    }

    func testTitlesMatchSettings() {
        XCTAssertEqual(NotificationAccess.allowed.title, "Allowed")
        XCTAssertEqual(NotificationAccess.denied.title, "Off in System Settings")
        XCTAssertEqual(NotificationAccess.notAsked.title, "Not asked yet")
        XCTAssertTrue(NotificationAccess.unavailable.detail.contains("app bundle"))
        let all: [NotificationAccess] = [.checking, .unavailable, .notAsked, .allowed, .denied]
        for access in all {
            for text in [access.title, access.detail, access.setupState.message] {
                XCTAssertFalse(text.isEmpty)
                XCTAssertFalse(text.contains(";"), text)
                XCTAssertFalse(text.contains("\u{2014}"), text)
            }
        }
        XCTAssertTrue(NotificationAccess.allowed.setupState.isPassing)
        XCTAssertFalse(NotificationAccess.notAsked.setupState.isPassing)
    }

    func testAsksByItselfOnlyOnce() {
        func ask(_ access: NotificationAccess, asked: Bool = false, guide: Bool = false, automation: Bool = false) -> Bool {
            NotificationPolicy.shouldAskAutomatically(access: access, alreadyAsked: asked, guideShowing: guide, automation: automation)
        }
        XCTAssertTrue(ask(.notAsked))
        XCTAssertFalse(ask(.notAsked, asked: true), "never twice")
        XCTAssertFalse(ask(.notAsked, guide: true), "the Setup guide has its own Allow button")
        XCTAssertFalse(ask(.notAsked, automation: true), "scripted runs never prompt")
        XCTAssertFalse(ask(.allowed))
        XCTAssertFalse(ask(.denied))
        XCTAssertFalse(ask(.unavailable))
        XCTAssertFalse(ask(.checking))
    }

    func testPostDecision() {
        XCTAssertEqual(NotificationPolicy.postDecision(access: .allowed, alreadyAsked: true), .send)
        XCTAssertEqual(NotificationPolicy.postDecision(access: .allowed, alreadyAsked: false), .send)
        XCTAssertEqual(NotificationPolicy.postDecision(access: .notAsked, alreadyAsked: false), .askThenSend)
        XCTAssertEqual(NotificationPolicy.postDecision(access: .notAsked, alreadyAsked: true), .drop)
        XCTAssertEqual(NotificationPolicy.postDecision(access: .denied, alreadyAsked: false), .drop)
        XCTAssertEqual(NotificationPolicy.postDecision(access: .unavailable, alreadyAsked: false), .drop)
    }

    func testWillPresentOptions() {
        // In front: lands in Notification Center without a banner over the app.
        XCTAssertEqual(NotificationPolicy.presentationOptions(appIsActive: true), [.list])
        // Behind other apps: banner, list and sound as before.
        XCTAssertEqual(NotificationPolicy.presentationOptions(appIsActive: false), [.banner, .list, .sound])
    }
}
