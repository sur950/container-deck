import XCTest
@testable import DeckCore

final class RepoStatsTests: XCTestCase {
    func testParsesStarsForksAndSumsAllReleaseAssets() throws {
        let repo = Data(#"{"stargazers_count": 128, "forks_count": 9, "open_issues_count": 3, "license": null}"#.utf8)
        let releases = Data(#"""
        [ {"tag_name": "v1.1.0", "assets": [ {"name": "a.dmg", "download_count": 40}, {"name": "a.dmg.sha256", "download_count": 2} ]},
          {"tag_name": "v1.0.0", "assets": [ {"name": "b.dmg", "download_count": 100} ]},
          {"tag_name": "v0.9.0", "assets": [] } ]
        """#.utf8)
        let stats = try RepoStatsClient.parse(repository: repo, releases: releases)
        XCTAssertEqual(stats, RepoStats(stars: 128, forks: 9, downloads: 142, openIssues: 3))
    }

    func testMissingFieldsAndNoReleasesGiveZeros() throws {
        let stats = try RepoStatsClient.parse(repository: Data("{}".utf8), releases: Data("[]".utf8))
        XCTAssertEqual(stats, RepoStats(stars: 0, forks: 0, downloads: 0))
    }

    func testBadReleasesJSONStillGivesRepoNumbers() throws {
        let stats = try RepoStatsClient.parse(repository: Data(#"{"stargazers_count": 5}"#.utf8), releases: Data("oops".utf8))
        XCTAssertEqual(stats.stars, 5)
        XCTAssertEqual(stats.downloads, 0)
    }

    func testRepositoryMustBeAnObject() {
        XCTAssertThrowsError(try RepoStatsClient.parse(repository: Data("[]".utf8), releases: Data("[]".utf8)))
    }

    func testErrorsHavePlainMessages() {
        XCTAssertEqual(RepoStatsError.notPublished.errorDescription, "The repository is not public yet.")
        XCTAssertNotNil(RepoStatsError.rateLimited.errorDescription)
    }
}
