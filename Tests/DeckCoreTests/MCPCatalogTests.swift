import XCTest
@testable import DeckCore

/// The Featured list: the selection rule data, Docker Hub pull counts, the cache and the order.
final class MCPCatalogTests: XCTestCase {
    /// Ids shipped before the list was ranked by pulls. Installed servers point at them.
    static let earlierIDs = ["time", "fetch", "filesystem", "git", "memory", "sequentialthinking", "github", "playwright", "context7", "everything"]

    // MARK: Selection rule data

    func testEveryFeaturedItemFollowsTheRule() {
        let items = MCPCatalog.items
        XCTAssertTrue((14...18).contains(items.count), "\(items.count) featured")
        XCTAssertEqual(Set(MCPCatalog.all.map(\.id)).count, MCPCatalog.all.count, "ids are unique")
        for item in items {
            XCTAssertTrue(item.arm64Note.contains("arm64"), item.id)
            XCTAssertGreaterThan(item.pullSnapshot, 0, item.id)
            XCTAssertNotNil(item.pullRepository, item.id)
            XCTAssertTrue(item.pullRepository?.hasPrefix("mcp/") == true, "ranked by Docker's mcp/ catalog: \(item.id)")
            XCTAssertTrue(item.configSource.hasPrefix("https://github.com/docker/mcp-registry/blob/main/servers/"), item.id)
            XCTAssertTrue(item.configSource.hasSuffix("/server.yaml"), item.id)
            XCTAssertFalse(item.image.isEmpty, "runs locally as a container: \(item.id)")
            XCTAssertNil(item.remoteURL, item.id)
            XCTAssertFalse(item.homepage.isEmpty, item.id)
            for text in [item.summary, item.title] + item.fields.map(\.label) {
                XCTAssertFalse(text.contains(";"), "\(item.id): \(text)")
                XCTAssertFalse(text.contains("—") || text.contains("–"), "\(item.id): \(text)")
            }
        }
        // Images in Docker's catalog rank by their own count. GitHub runs GitHub's image and ranks by mcp/github.
        for item in items where item.image.hasPrefix("mcp/") {
            XCTAssertEqual(item.pullRepository, item.image, item.id)
        }
        XCTAssertEqual(MCPCatalog.item("github")?.image, "ghcr.io/github/github-mcp-server")
        XCTAssertEqual(MCPCatalog.item("github")?.pullRepository, "mcp/github")
    }

    func testGroupsMatchWhatEachServerNeeds() {
        for item in MCPCatalog.featured(.noAccount) {
            XCTAssertFalse(item.fields.contains { $0.secret }, "no account means no secret: \(item.id)")
        }
        for item in MCPCatalog.featured(.account) {
            XCTAssertTrue(item.fields.contains { $0.secret } || item.mount?.isFile == true, "asks for a token or kubeconfig: \(item.id)")
        }
        XCTAssertFalse(MCPCatalog.featured(.noAccount).isEmpty)
        XCTAssertFalse(MCPCatalog.featured(.account).isEmpty)
        XCTAssertEqual(MCPCatalog.featured(.noAccount).count + MCPCatalog.featured(.account).count, MCPCatalog.items.count)
    }

    func testLeftOutServersAreNotFeatured() {
        let featured = Set(MCPCatalog.items.map(\.id))
        for id in ["puppeteer", "docker", "desktop-commander", "everything", "signatures", "slack", "obsidian"] {
            XCTAssertFalse(featured.contains(id), id)
        }
        for repository in ["mcp/puppeteer", "mcp/docker", "mcp/desktop-commander", "mcp/everything", "mcp/signatures"] {
            XCTAssertFalse(MCPCatalog.pullRepositories.contains(repository), repository)
        }
    }

    func testEarlierIDsStillResolve() {
        for id in Self.earlierIDs {
            XCTAssertNotNil(MCPCatalog.item(id), id)
        }
        XCTAssertNotNil(MCPCatalog.retired.first { $0.id == "everything" })
    }

    func testSettingsFromDockersCatalog() throws {
        let kube = try XCTUnwrap(MCPCatalog.item("kubernetes")?.mount)
        XCTAssertEqual(kube.containerPath, "/home/appuser/.kube/config")
        XCTAssertTrue(kube.isFile)
        XCTAssertTrue(kube.readOnly)
        XCTAssertEqual(MCPCatalog.item("brave-search")?.env, [EnvVar(key: "BRAVE_MCP_TRANSPORT", value: "stdio")])
        XCTAssertEqual(MCPCatalog.item("grafana")?.command, ["--transport=stdio"])
        XCTAssertEqual(MCPCatalog.item("grafana")?.fields.map(\.key), ["GRAFANA_URL", "GRAFANA_API_KEY"])
        XCTAssertEqual(MCPCatalog.item("notion")?.fields.first?.key, "NOTION_TOKEN")
        XCTAssertEqual(MCPCatalog.item("filesystem")?.command, ["/projects"])
        XCTAssertEqual(MCPCatalog.item("markitdown")?.mount?.optional, true)
        let memory = try XCTUnwrap(MCPCatalog.item("memory"))
        XCTAssertEqual(memory.volume?.name(server: "memory"), "deck-mcp-memory-data")
        XCTAssertEqual(memory.env.first?.value, "/data/memory.json")
    }

    func testMemoryVolumeAndFixedSettingsReachTheAgentCommand() {
        // What the install form makes for Memory: the fixed setting plus the data volume.
        let item = MCPCatalog.item("memory")!
        let server = MCPInstalledServer(name: "memory", catalogID: item.id, image: item.image, transport: .stdio, env: item.env,
                                        mounts: [MountSpec(kind: .volume, source: item.volume!.name(server: "memory"), destination: "/data")])
        let args = MCPLaunch.stdioRunArguments(server)
        XCTAssertTrue(args.contains("deck-mcp-memory-data:/data"), args.joined(separator: " "))
        XCTAssertTrue(args.contains("MEMORY_FILE_PATH"))
        let entry = MCPLaunch.entry(server, cliPath: "/usr/local/bin/container")
        XCTAssertEqual(entry.env["MEMORY_FILE_PATH"], "/data/memory.json")
        XCTAssertEqual(MCPLaunch.managedServerName(in: entry), "memory")
    }

    func testMountSuggestionOnlyWhenItExists() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("deck-mcp-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let mount = try XCTUnwrap(MCPCatalog.item("kubernetes")?.mount)
        XCTAssertNil(mount.existingSuggestion(home: home.path))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".kube"), withIntermediateDirectories: true)
        // A folder where a file is expected does not count.
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".kube/config"), withIntermediateDirectories: true)
        XCTAssertNil(mount.existingSuggestion(home: home.path))
        try FileManager.default.removeItem(at: home.appendingPathComponent(".kube/config"))
        try Data("apiVersion: v1\n".utf8).write(to: home.appendingPathComponent(".kube/config"))
        XCTAssertEqual(mount.existingSuggestion(home: home.path), home.path + "/.kube/config")
    }

    // MARK: Sorting

    func testSnapshotOrderIsMostPulledFirst() {
        for group in MCPCatalogGroup.allCases {
            let pulls = MCPCatalog.featured(group).map(\.pullSnapshot)
            XCTAssertEqual(pulls, pulls.sorted(by: >), group.rawValue)
        }
        XCTAssertEqual(MCPCatalog.featured(.noAccount).first?.id, "playwright")
        XCTAssertEqual(MCPCatalog.featured(.account).first?.id, "grafana")
    }

    func testLiveCountsReorderAndFallBack() {
        // Time overtakes Playwright, Fetch has no live count (snapshot), zero counts are ignored.
        let live = ["mcp/time": 9_000_000, "mcp/playwright": 2_800_000, "mcp/duckduckgo": 0]
        let ids = MCPCatalog.featured(.noAccount, live: live).map(\.id)
        XCTAssertEqual(Array(ids.prefix(4)), ["time", "playwright", "fetch", "duckduckgo"])
        XCTAssertEqual(MCPCatalog.item("duckduckgo")?.pulls(live), 1_036_843)
        XCTAssertEqual(MCPCatalog.item("time")?.pulls(live), 9_000_000)
    }

    func testTiesKeepTitleOrder() {
        let a = MCPCatalogItem(id: "b", title: "Beta", summary: "", image: "mcp/b", transport: .stdio, homepage: "", publisher: "", pullSnapshot: 5)
        let b = MCPCatalogItem(id: "a", title: "Alpha", summary: "", image: "mcp/a", transport: .stdio, homepage: "", publisher: "", pullSnapshot: 5)
        XCTAssertEqual(MCPCatalog.sorted([a, b], live: [:]).map(\.id), ["a", "b"])
        XCTAssertEqual(CountFormat.compact(MCPCatalog.item("playwright")!.pullSnapshot), "2.7M")
        XCTAssertEqual(CountFormat.compact(MCPCatalog.item("github")!.pullSnapshot), "158K")
    }

    // MARK: Docker Hub parsing

    func testParseList() throws {
        let counts = try MCPPullCountClient.parseList(Data(MCPCatalogFixtures.list.utf8))
        XCTAssertEqual(counts["mcp/playwright"], 2_715_289)
        XCTAssertEqual(counts["mcp/fetch"], 1_978_687)
        XCTAssertEqual(counts["mcp/github"], 157_593)
        XCTAssertEqual(counts.count, 5)
        XCTAssertThrowsError(try MCPPullCountClient.parseList(Data(MCPCatalogFixtures.refused.utf8)))
        XCTAssertThrowsError(try MCPPullCountClient.parseList(Data("not json".utf8)))
    }

    func testParseRepository() throws {
        let one = try MCPPullCountClient.parseRepository(Data(MCPCatalogFixtures.repository.utf8))
        XCTAssertEqual(one.repository, "mcp/markitdown")
        XCTAssertEqual(one.pulls, 169_573)
        XCTAssertThrowsError(try MCPPullCountClient.parseRepository(Data(#"{"name": "x"}"#.utf8)))
    }

    func testURLs() {
        XCTAssertEqual(MCPPullCountClient.listURL.absoluteString,
                       "https://hub.docker.com/v2/namespaces/mcp/repositories?page_size=100&ordering=pull_count")
        XCTAssertEqual(MCPPullCountClient.repositoryURL("mcp/youtube-transcript")?.absoluteString,
                       "https://hub.docker.com/v2/namespaces/mcp/repositories/youtube-transcript")
        XCTAssertNil(MCPPullCountClient.repositoryURL("ghcr.io/github"))
        XCTAssertNil(MCPPullCountClient.repositoryURL("mcp/a/b"))
        XCTAssertNil(MCPPullCountClient.repositoryURL("mcp/../x?y"))
    }

    // MARK: Cache and client

    private func tempCache() -> MCPPullCountCache {
        MCPPullCountCache(file: FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-mcp-pulls-\(UUID().uuidString)").appendingPathComponent("pulls.json"))
    }

    func testCacheRoundTripAndFreshness() {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.file.deletingLastPathComponent()) }
        XCTAssertNil(cache.load())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        cache.save(MCPPullCounts(counts: ["mcp/fetch": 10], fetched: now))
        XCTAssertEqual(cache.load(), MCPPullCounts(counts: ["mcp/fetch": 10], fetched: now))
        let saved = cache.load()!
        XCTAssertTrue(MCPPullCountCache.isFresh(saved, now: now.addingTimeInterval(23 * 3600)))
        XCTAssertFalse(MCPPullCountCache.isFresh(saved, now: now.addingTimeInterval(24 * 3600)))
        XCTAssertFalse(MCPPullCountCache.isFresh(saved, now: now.addingTimeInterval(-60)), "a clock moved back does not count as fresh")
    }

    func testFreshCacheSkipsTheNetwork() async {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.file.deletingLastPathComponent()) }
        let now = Date()
        cache.save(MCPPullCounts(counts: ["mcp/fetch": 10, "mcp/time": 20], fetched: now.addingTimeInterval(-3600)))
        let calls = Calls()
        let client = MCPPullCountClient(cache: cache) { url in calls.add(url); throw DeckError.network("offline") }
        let result = await client.counts(for: ["mcp/fetch", "mcp/time"], now: now)
        XCTAssertEqual(result?.counts, ["mcp/fetch": 10, "mcp/time": 20])
        XCTAssertEqual(calls.count, 0)
    }

    func testOfflineKeepsTheLastCountsOrNone() async {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.file.deletingLastPathComponent()) }
        // Whole seconds: the cache keeps ISO 8601 dates.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let offline = MCPPullCountClient(cache: cache) { _ in throw DeckError.network("offline") }
        let nothing = await offline.counts(for: ["mcp/fetch"], now: now)
        XCTAssertNil(nothing, "no cache and no network: the snapshot is used")
        XCTAssertEqual(MCPCatalog.featured(.noAccount, live: nothing?.counts ?? [:]).map(\.id), MCPCatalog.featured(.noAccount).map(\.id))

        let old = MCPPullCounts(counts: ["mcp/fetch": 10], fetched: now.addingTimeInterval(-3 * 86_400))
        cache.save(old)
        let stale = await offline.counts(for: ["mcp/fetch"], now: now)
        XCTAssertEqual(stale, old)
    }

    func testFetchesTheListThenMissingRepositoriesAndSaves() async {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.file.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calls = Calls()
        let client = MCPPullCountClient(cache: cache) { url in
            calls.add(url)
            if url == MCPPullCountClient.listURL { return Data(MCPCatalogFixtures.list.utf8) }
            if url.path.hasSuffix("/markitdown") { return Data(MCPCatalogFixtures.repository.utf8) }
            throw DeckError.network("not found")
        }
        let result = await client.counts(for: ["mcp/playwright", "mcp/github", "mcp/markitdown", "mcp/wikipedia-mcp"], now: now)
        XCTAssertEqual(result?.counts, ["mcp/playwright": 2_715_289, "mcp/github": 157_593, "mcp/markitdown": 169_573])
        XCTAssertEqual(result?.fetched, now)
        // One list request, then one per repository the list did not have.
        XCTAssertEqual(calls.urls.map(\.lastPathComponent), ["repositories", "markitdown", "wikipedia-mcp"])
        XCTAssertEqual(cache.load(), result, "saved for the next day")
        XCTAssertNil(result?.counts["mcp/signatures"], "only the asked repositories are kept")
    }
}

/// Records the URLs a stub fetch was asked for.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func add(_ url: URL) { lock.lock(); list.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list }
    var count: Int { urls.count }
}
