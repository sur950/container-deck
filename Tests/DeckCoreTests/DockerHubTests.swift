import XCTest
@testable import DeckCore

private let searchJSON = """
{"count":2,"next":"https://hub.docker.com/v2/search/repositories/?page=2&page_size=25&query=nginx","previous":null,"results":[
 {"repo_name":"nginx","short_description":"Official build of Nginx.","star_count":20765,"pull_count":12345678901,"repo_owner":"","is_automated":false,"is_official":true},
 {"repo_name":"bitnami/nginx","short_description":"Bitnami container image for NGINX","star_count":200,"pull_count":500000000,"repo_owner":"","is_automated":false,"is_official":false},
 {"repo_name":"nginx","short_description":"duplicate","star_count":1,"pull_count":1,"is_official":true},
 {"short_description":"no name"}
]}
"""

private let libraryJSON = """
{"count":178,"next":"https://hub.docker.com/v2/repositories/library/?ordering=-pull_count&page=3&page_size=25","previous":null,"results":[
 {"name":"alpine","namespace":"library","repository_type":"image","status":1,"description":"A minimal Docker image based on Alpine Linux.","is_private":false,"star_count":11000,"pull_count":9000000000,"last_updated":"2025-01-10T18:47:44.418467Z"}
]}
"""

private let tagsJSON = """
{"count":2,"next":null,"previous":null,"results":[
 {"creator":7,"id":1,"images":[
   {"architecture":"amd64","features":"","variant":null,"digest":"sha256:a","os":"linux","os_features":"","os_version":null,"size":72000000,"status":"active"},
   {"architecture":"arm64","features":"","variant":"v8","digest":"sha256:b","os":"linux","os_features":"","os_version":null,"size":70000000,"status":"active"},
   {"architecture":"arm64","variant":"v8","digest":"sha256:c","os":"linux","size":70000001,"status":"active"},
   {"architecture":"unknown","variant":null,"digest":"sha256:d","os":"unknown","size":1000,"status":"active"}
 ],"last_updated":"2025-01-10T18:47:44.418467Z","last_updater":1,"last_updater_username":"doijanky","name":"latest","repository":1,"full_size":72000000,"v2":true,"tag_status":"active","tag_last_pushed":"2025-01-10T18:47:43Z","media_type":"application/vnd.oci.image.index.v1+json","content_type":"image","digest":"sha256:idx"},
 {"name":"1.27-alpine","images":[{"architecture":"arm64","os":"linux","size":20000000}],"tag_last_pushed":"2025-01-09T10:00:00Z"}
]}
"""

final class DockerHubTests: XCTestCase {

    func testParseSearch() throws {
        let page = try DockerHubClient.parseSearch(Data(searchJSON.utf8), page: 1)
        XCTAssertEqual(page.items.map(\.fullName), ["nginx", "bitnami/nginx"])
        XCTAssertEqual(page.nextPage, 2)

        let nginx = page.items[0]
        XCTAssertTrue(nginx.isOfficial)
        XCTAssertEqual(nginx.description, "Official build of Nginx.")
        XCTAssertEqual(nginx.starCount, 20765)
        XCTAssertEqual(nginx.pullCount, 12_345_678_901)
        XCTAssertFalse(page.items[1].isOfficial)
    }

    func testParseLibraryListing() throws {
        let page = try DockerHubClient.parseSearch(Data(libraryJSON.utf8), page: 2)
        XCTAssertEqual(page.items.map(\.fullName), ["alpine"])
        XCTAssertTrue(page.items[0].isOfficial)
        XCTAssertEqual(page.items[0].description, "A minimal Docker image based on Alpine Linux.")
        XCTAssertEqual(page.nextPage, 3)
    }

    func testParseTags() throws {
        let page = try DockerHubClient.parseTags(Data(tagsJSON.utf8), page: 1)
        XCTAssertNil(page.nextPage)
        XCTAssertEqual(page.items.map(\.name), ["latest", "1.27-alpine"])

        let latest = page.items[0]
        XCTAssertEqual(latest.sizeBytes, 72_000_000)
        XCTAssertEqual(latest.platforms, ["linux/amd64", "linux/arm64/v8"])
        XCTAssertEqual(latest.lastUpdated?.timeIntervalSince1970 ?? 0, 1_736_534_864.418467, accuracy: 0.000_01)

        let alpine = page.items[1]
        XCTAssertEqual(alpine.sizeBytes, 20_000_000)
        XCTAssertEqual(alpine.platforms, ["linux/arm64"])
        XCTAssertNotNil(alpine.lastUpdated)
    }

    func testNextPageFromCount() throws {
        let json = #"{"count":120,"results":[{"name":"a"}]}"#
        XCTAssertEqual(try DockerHubClient.parseTags(Data(json.utf8), page: 1).nextPage, 2)
        XCTAssertNil(try DockerHubClient.parseTags(Data(json.utf8), page: 3).nextPage)
    }

    func testBadJSONThrows() {
        XCTAssertThrowsError(try DockerHubClient.parseSearch(Data("<html>".utf8), page: 1))
        XCTAssertThrowsError(try DockerHubClient.parseTags(Data("".utf8), page: 1))
    }

    func testRepositoryPaths() {
        func path(_ text: String) -> String? {
            DockerHubClient.repositoryPath(text).map { "\($0.0)/\($0.1)" }
        }
        XCTAssertEqual(path("nginx"), "library/nginx")
        XCTAssertEqual(path("docker.io/library/nginx:1.27"), "library/nginx")
        XCTAssertEqual(path("grafana/grafana"), "grafana/grafana")
        XCTAssertEqual(path("Grafana/Grafana@sha256:abc"), "grafana/grafana")
        XCTAssertNil(path("ghcr.io/apple/container"))
        XCTAssertNil(path("ghcr.io/apple"))
        XCTAssertNil(path(""))
    }

    func testURLs() {
        XCTAssertEqual(
            DockerHubClient.tagsURL("nginx", page: 2)?.absoluteString,
            "https://hub.docker.com/v2/repositories/library/nginx/tags?page=2&page_size=50"
        )
        let search = DockerHubClient.searchURL("nginx web", page: 1).absoluteString
        XCTAssertTrue(search.hasPrefix("https://hub.docker.com/v2/search/repositories/?"))
        XCTAssertTrue(search.contains("query=nginx%20web"))
        XCTAssertTrue(search.contains("page_size=25"))
        XCTAssertTrue(DockerHubClient.searchURL("  ", page: 1).absoluteString.contains("/v2/repositories/library/"))
    }
}
