import XCTest
import DeckCore
@testable import ContainerDeck

/// Explore moved into Images. Old names, links and debug commands must still land there.
@MainActor
final class ImagesExploreMergeTests: XCTestCase {
    private var suiteName = ""

    // Each test gets its own preferences, so parallel runs never race on the saved section.
    override func setUp() {
        suiteName = "images-merge-\(UUID().uuidString)"
        ImagesSection.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    override func tearDown() {
        ImagesSection.defaults.removePersistentDomain(forName: suiteName)
        ImagesSection.defaults = .standard
    }

    func testSidebarHasNoExplore() {
        XCTAssertNil(SidebarItem(rawValue: "explore"))
        XCTAssertFalse(SidebarItem.allCases.map(\.rawValue).contains("explore"))
        XCTAssertTrue(SidebarItem.allCases.contains(.images))
    }

    func testSavedExploreSelectionMapsToImages() {
        XCTAssertEqual(SidebarItem.resolve("explore")?.item, .images)
        XCTAssertEqual(SidebarItem.resolve("explore")?.section, .explore)
        XCTAssertEqual(SidebarItem.resolve(" Explore ")?.item, .images)
        XCTAssertEqual(SidebarItem.resolve("images")?.item, .images)
        XCTAssertNil(SidebarItem.resolve("images")?.section)
        XCTAssertEqual(SidebarItem.resolve("aiModels")?.item, .aiModels)
        XCTAssertNil(SidebarItem.resolve("nope"))
    }

    func testSelectExploreOpensImagesOnExplore() {
        let state = AppState()
        state.selection = .dashboard
        ImagesSection.defaults.set(ImagesSection.local.rawValue, forKey: ImagesSection.storageKey)
        XCTAssertTrue(SidebarItem.open("explore", state: state))
        XCTAssertEqual(state.selection, .images)
        XCTAssertEqual(ImagesSection.saved, .explore)
        XCTAssertFalse(SidebarItem.open("nope", state: state))
    }

    func testOldExploreLinkOpensImagesOnExplore() throws {
        let link = try XCTUnwrap(DeepLink(url: URL(string: "containerdeck://explore")!))
        XCTAssertEqual(link, .explore(""))
        XCTAssertEqual(link.url?.absoluteString, "containerdeck://explore")

        let state = AppState()
        ImagesSection.defaults.set(ImagesSection.local.rawValue, forKey: ImagesSection.storageKey)
        DeepLinkRouter.route(link, state: state)
        XCTAssertEqual(state.selection, .images)
        XCTAssertEqual(ImagesSection.saved, .explore)
    }

    func testExploreLinkWithSearch() throws {
        let link = try XCTUnwrap(DeepLink(url: URL(string: "containerdeck://explore/redis")!))
        XCTAssertEqual(link, .explore("redis"))
        XCTAssertEqual(link.url?.absoluteString, "containerdeck://explore/redis")
        let previous = ImageExploreStore.shared.query
        defer { ImageExploreStore.shared.query = previous }
        DeepLinkRouter.route(link, state: AppState())
        XCTAssertEqual(ImageExploreStore.shared.query, "redis")
    }

    func testImagesLinkStillWorks() {
        XCTAssertEqual(DeepLink(url: URL(string: "containerdeck://images")!), .screen(.images))
        XCTAssertEqual(DeepLink.screen(.images).url?.absoluteString, "containerdeck://images")
    }

    func testExploreLookupNameRules() {
        let store = ImageExploreStore.shared
        let previous = store.query
        defer { store.query = previous }
        store.query = "ghcr.io/astral-sh/uv"
        XCTAssertEqual(store.lookupName, "ghcr.io/astral-sh/uv")
        store.query = "nginx"
        XCTAssertNil(store.lookupName)
        // Docker Hub names are searched, not looked up.
        store.query = "docker.io/library/nginx"
        XCTAssertNil(store.lookupName)
    }
}
