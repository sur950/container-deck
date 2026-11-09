import XCTest
@testable import DeckCore

/// Answers GET requests from a script. Records every call.
final class ScriptedRegistryHTTP: RegistryHTTP, @unchecked Sendable {
    struct Call { let url: URL; let headers: [String: String] }
    typealias Handler = @Sendable (URL, [String: String]) async throws -> RegistryHTTPResponse

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func get(_ url: URL, headers: [String: String]) async throws -> RegistryHTTPResponse {
        lock.withLock { recorded.append(Call(url: url, headers: headers)) }
        return try await handler(url, headers)
    }
}

/// Keychain stand in. Never touches the real keychain.
struct FakeRegistryCredentials: RegistryCredentialReading {
    var quiet: [String: RegistryCredentialLookup] = [:]
    var prompted: [String: RegistryCredentialLookup] = [:]

    func credential(server: String, interactive: Bool) async -> RegistryCredentialLookup {
        (interactive ? prompted[server] : quiet[server]) ?? .none
    }
}

private func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> RegistryHTTPResponse {
    RegistryHTTPResponse(status: status, headers: headers, data: Data(text.utf8))
}

private let testCredential = RegistryCredential(username: "deck-test-user", secret: "not-a-real-secret")

final class RegistrySearchTests: XCTestCase {

    // MARK: Parsing

    func testQuaySearchParsing() throws {
        let parsed = try QuaySearch.parse(Data(RegistrySearchFixtures.quayFind.utf8))
        XCTAssertEqual(parsed.images.map(\.repository), [
            "prometheus-operator/prometheus-config-reloader", "prometheus/prometheus", "prometheus-operator/prometheus-operator"
        ])
        XCTAssertTrue(parsed.hasMore)
        XCTAssertTrue(parsed.images.allSatisfy { $0.registry == "quay.io" && !$0.isPrivate })
        // The README turns into one plain sentence.
        XCTAssertEqual(parsed.images[1].description, "Visit prometheus.io for the full documentation, examples and guides.")
        XCTAssertEqual(parsed.images[0].description, "")
        XCTAssertEqual(parsed.images[1].reference(tag: "v3"), "quay.io/prometheus/prometheus:v3")
        XCTAssertThrowsError(try QuaySearch.parse(Data("[]".utf8)))
    }

    func testQuayTagsParsing() throws {
        let page = try QuaySearch.parseTags(Data(RegistrySearchFixtures.quayTags.utf8), page: 1)
        XCTAssertEqual(page.items.map(\.name), ["master-distroless", "master", "master-busybox"])
        XCTAssertEqual(page.nextPage, 2)
        XCTAssertEqual(page.items[0].lastUpdated, Date(timeIntervalSince1970: 1792863085))
    }

    func testHarborSearchParsing() throws {
        let images = try XCTUnwrap(HarborSearch.parse(Data(RegistrySearchFixtures.harborSearch.utf8), registry: "demo.goharbor.io"))
        XCTAssertEqual(images.map(\.repository), ["test-2244/nginx", "frzdoc/library/nginx", "frz/nginx"])
        XCTAssertEqual(images[1].pullCount, 20138)
        XCTAssertEqual(images[1].description, "54 artifacts")
        XCTAssertEqual(images[0].description, "1 artifact")
        XCTAssertEqual(images[2].reference, "demo.goharbor.io/frz/nginx")
        // A plain registry's answer is not Harbor's.
        XCTAssertNil(HarborSearch.parse(Data(#"{"repositories":[]}"#.utf8), registry: "x"))
    }

    func testGitHubPackagesParsing() throws {
        let images = try GitHubPackages.parsePackages(Data(RegistrySearchFixtures.githubPackages.utf8))
        XCTAssertEqual(images.map(\.repository), ["monalisa/hello_docker", "monalisa/tools/prometheus-exporter"])
        XCTAssertEqual(images[0].description, "Private, 3 versions")
        XCTAssertTrue(images[0].isPrivate)
        XCTAssertFalse(images[1].isPrivate)
        XCTAssertEqual(images[0].reference, "ghcr.io/monalisa/hello_docker")
        XCTAssertEqual(images[0].webURL?.absoluteString, "https://github.com/users/monalisa/packages/container/package/hello_docker")
        XCTAssertEqual(GitHubPackages.parseOrgs(Data(RegistrySearchFixtures.githubOrgs.utf8)), ["octo-org"])
        XCTAssertEqual(GitHubPackages.filter(images, query: "prometheus").map(\.repository), ["monalisa/tools/prometheus-exporter"])
    }

    func testCatalogParsingAndLocalFilter() {
        XCTAssertEqual(RegistryCatalog.parse(Data(#"{"repositories":["team/api","team/web","api"]}"#.utf8)), ["team/api", "team/web", "api"])
        XCTAssertNil(RegistryCatalog.parse(Data(#"{"errors":[]}"#.utf8)))
        let names = ["team/web", "team/api-gateway", "api", "tools/apish", "other/thing"]
        // Exact name first, then names that start with it, then the rest.
        XCTAssertEqual(RegistryCatalog.filter(names, query: "api"), ["api", "team/api-gateway", "tools/apish"])
        XCTAssertEqual(RegistryCatalog.filter(names, query: "team web"), ["team/web"])
        XCTAssertEqual(RegistryCatalog.filter(names, query: "nothing"), [])
    }

    func testTagListParsingAndSort() {
        XCTAssertEqual(RegistryTagList.parse(Data(RegistrySearchFixtures.ghcrTags.utf8)), ["initial", "latest", "0.1.37", "0.1.38", "0.1.39"])
        XCTAssertEqual(RegistryTagList.parse(Data(#"{"name":"x","tags":null}"#.utf8)), [])
        XCTAssertEqual(RegistryTagList.sorted(["1.9", "latest", "1.10", "1.10", "0.2"]), ["latest", "1.10", "1.9", "0.2"])
        XCTAssertEqual(RegistryTagList.sorted(["trixie", "0.9.9", "alpine", "v1.0", "0.9.10", "latest"]), ["latest", "v1.0", "0.9.10", "0.9.9", "alpine", "trixie"])
        XCTAssertTrue(RegistryTagList.isCapped(5000))
        XCTAssertFalse(RegistryTagList.isCapped(4999))
    }

    func testDescriptionSummary() {
        XCTAssertEqual(RegistryText.summary("# Title\n\n[![CI](https://x/badge.svg)](https://x)\n\nA small [web](https://w) server for *static* files."),
                       "A small web server for static files.")
        XCTAssertEqual(RegistryText.summary(nil), "")
        XCTAssertEqual(RegistryText.summary(#"Metrics exposed by \*NIX kernels, written in Go \(fast\)."#), "Metrics exposed by *NIX kernels, written in Go (fast).")
        XCTAssertEqual(RegistryText.summary(String(repeating: "word ", count: 100), limit: 20).count, 20)
    }

    // MARK: Auth

    func testChallengeParsing() throws {
        let ghcr = try XCTUnwrap(RegistryAuthChallenge.parse(RegistrySearchFixtures.ghcrChallenge))
        XCTAssertEqual(ghcr, RegistryAuthChallenge(scheme: .bearer, realm: "https://ghcr.io/token", service: "ghcr.io", scope: "repository:astral-sh/uv:pull"))
        XCTAssertEqual(ghcr.tokenURL(scope: nil)?.absoluteString, "https://ghcr.io/token?service=ghcr.io&scope=repository:astral-sh/uv:pull")

        let hub = try XCTUnwrap(RegistryAuthChallenge.parse(RegistrySearchFixtures.hubCatalogChallenge))
        XCTAssertEqual(hub.scope, "registry:catalog:*")

        let comma = try XCTUnwrap(RegistryAuthChallenge.parse(#"Bearer realm="https://r/t",scope="repository:a/b:pull,push""#))
        XCTAssertEqual(comma.scope, "repository:a/b:pull,push")
        XCTAssertNil(comma.service)

        XCTAssertEqual(RegistryAuthChallenge.parse(#"Basic realm="Registry Realm""#)?.scheme, .basic)
        XCTAssertNil(RegistryAuthChallenge.parse("Negotiate abc"))
        XCTAssertNil(RegistryAuthChallenge(scheme: .bearer, realm: "file:///etc/passwd").tokenURL(scope: nil))
        XCTAssertEqual(RegistryAuthChallenge.parseToken(Data(#"{"token":"abc"}"#.utf8)), "abc")
        XCTAssertEqual(RegistryAuthChallenge.parseToken(Data(#"{"access_token":"xyz"}"#.utf8)), "xyz")
    }

    func testBearerFlowAnonymousTags() async throws {
        let http = ScriptedRegistryHTTP { url, headers in
            if url.host == "ghcr.io", url.path == "/token" { return json(#"{"token":"anon-token"}"#) }
            if url.path == "/v2/astral-sh/uv/tags/list" {
                if headers["Authorization"] == "Bearer anon-token" { return json(RegistrySearchFixtures.ghcrTags) }
                return json(#"{"errors":[]}"#, status: 401, headers: ["WWW-Authenticate": RegistrySearchFixtures.ghcrChallenge])
            }
            return json("", status: 404)
        }
        let service = RegistrySearchService(http: http, credentials: FakeRegistryCredentials())
        let lookup = try await service.lookup("ghcr.io/astral-sh/uv:latest", in: nil)
        XCTAssertEqual(lookup.image.reference, "ghcr.io/astral-sh/uv")
        XCTAssertEqual(lookup.tags.items.map(\.name), ["latest", "0.1.39", "0.1.38", "0.1.37", "initial"])
        let calls = http.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertNil(calls[0].headers["Authorization"])
        // Not signed in: the token request carries no credentials.
        XCTAssertNil(calls[1].headers["Authorization"])
        XCTAssertEqual(calls[1].url.absoluteString, "https://ghcr.io/token?service=ghcr.io&scope=repository:astral-sh/uv:pull")
        XCTAssertEqual(calls[2].headers["Authorization"], "Bearer anon-token")
    }

    func testBearerFlowSendsBasicCredentialsToTokenService() async throws {
        let expectedBasic = "Basic " + Data("deck-test-user:not-a-real-secret".utf8).base64EncodedString()
        let http = ScriptedRegistryHTTP { url, headers in
            if url.path == "/auth" {
                return headers["Authorization"] == expectedBasic ? json(#"{"access_token":"user-token"}"#) : json("{}", status: 401)
            }
            if url.path == "/v2/team/app/tags/list" {
                if headers["Authorization"] == "Bearer user-token" { return json(#"{"name":"team/app","tags":["v1","v2"]}"#) }
                return json("{}", status: 401, headers: ["www-authenticate": #"Bearer realm="https://registry.example.com/auth",service="example""#])
            }
            return json("", status: 404)
        }
        let source = RegistrySource(host: "registry.example.com", keychainServer: "registry.example.com", username: "deck-test-user")
        let service = RegistrySearchService(http: http, credentials: FakeRegistryCredentials(quiet: ["registry.example.com": .found(testCredential)]))
        let tags = try await service.tags(RegistryImage(registry: "registry.example.com", repository: "team/app"), in: source)
        XCTAssertEqual(tags.items.map(\.name), ["v2", "v1"])
        // The challenge had no scope, so the app asked for pull on this image.
        XCTAssertEqual(http.calls[1].url.absoluteString, "https://registry.example.com/auth?service=example&scope=repository:team/app:pull")
    }

    func testBasicChallengeRetriesWithCredentials() async throws {
        let http = ScriptedRegistryHTTP { _, headers in
            headers["Authorization"]?.hasPrefix("Basic ") == true
                ? json(#"{"name":"a","tags":["1"]}"#)
                : json("", status: 401, headers: ["WWW-Authenticate": #"Basic realm="Registry""#])
        }
        let session = RegistryAPISession(http: http, credential: testCredential)
        let reply = try await session.get(URL(string: "https://r.example/v2/a/tags/list")!, scope: nil)
        XCTAssertEqual(reply.status, 200)
        let anonymous = try await RegistryAPISession(http: http, credential: nil).get(URL(string: "https://r.example/v2/a/tags/list")!, scope: nil)
        XCTAssertEqual(anonymous.status, 401)
    }

    func testCredentialNeverPrintsSecret() {
        XCTAssertFalse(String(describing: testCredential).contains("not-a-real-secret"))
        XCTAssertFalse(String(reflecting: testCredential).contains("not-a-real-secret"))
        XCTAssertFalse("\(RegistryCredentialLookup.found(testCredential))".contains("not-a-real-secret"))
    }

    func testNextLink() {
        let base = URL(string: "https://ghcr.io/v2/astral-sh/uv/tags/list?n=5")!
        XCTAssertEqual(RegistryAPISession.nextLink(#"</v2/astral-sh/uv/tags/list?last=0.1.39&n=5>; rel="next""#, base: base)?.absoluteString,
                       "https://ghcr.io/v2/astral-sh/uv/tags/list?last=0.1.39&n=5")
        XCTAssertNil(RegistryAPISession.nextLink(nil, base: base))
        XCTAssertNil(RegistryAPISession.nextLink(#"<https://x/prev>; rel="prev""#, base: base))
    }

    // MARK: Sources

    func testSourcesFromLogins() {
        let logins = [
            RegistryLogin(server: "ghcr.io", username: "me"),
            RegistryLogin(server: "registry-1.docker.io", username: "hubber"),
            RegistryLogin(server: "123456789012.dkr.ecr.us-east-1.amazonaws.com"),
            RegistryLogin(server: "harbor.example.com")
        ]
        let sources = RegistrySource.sources(logins: logins)
        XCTAssertEqual(sources.map(\.host), ["docker.io", "quay.io", "123456789012.dkr.ecr.us-east-1.amazonaws.com", "ghcr.io", "harbor.example.com"])
        XCTAssertEqual(sources.map(\.kind), [.dockerHub, .quay, .amazon, .github, .generic])
        XCTAssertEqual(sources[0].keychainServer, "registry-1.docker.io")
        XCTAssertFalse(sources[1].isSignedIn)
        XCTAssertEqual(sources[3].displayName, "GitHub")
        XCTAssertEqual(RegistryKind.classify(host: "europe-west1-docker.pkg.dev"), .google)
        XCTAssertEqual(RegistryKind.classify(host: "public.ecr.aws"), .amazon)
        XCTAssertEqual(RegistryKind.classify(host: "myteam.azurecr.io"), .generic)
        XCTAssertEqual(RegistrySource(host: "localhost:5000").scheme, "http")
        XCTAssertEqual(RegistrySource.dockerHub.apiHost, "registry-1.docker.io")
    }

    // MARK: Service

    func testGenericCatalogWithBearerAndLocalFilter() async throws {
        let expectedBasic = testCredential.basicHeader
        let http = ScriptedRegistryHTTP { url, headers in
            switch url.path {
            case "/api/v2.0/search": return json("404 page not found", status: 404)
            case "/token":
                XCTAssertEqual(headers["Authorization"], expectedBasic)
                return json(#"{"token":"cat-token"}"#)
            case "/v2/_catalog":
                guard headers["Authorization"] == "Bearer cat-token" else {
                    return json("{}", status: 401, headers: ["WWW-Authenticate": #"Bearer realm="https://registry.example.com/token",service="reg",scope="registry:catalog:*""#])
                }
                if url.query?.contains("last=") == true { return json(#"{"repositories":["tools/api-cli"]}"#) }
                return json(#"{"repositories":["team/web","team/api"]}"#, headers: ["Link": #"</v2/_catalog?last=team%2Fapi&n=1000>; rel="next""#])
            default: return json("", status: 404)
            }
        }
        let source = RegistrySource(host: "registry.example.com", keychainServer: "registry.example.com")
        let service = RegistrySearchService(http: http, credentials: FakeRegistryCredentials(quiet: ["registry.example.com": .found(testCredential)]))
        let results = await service.search("api", in: [source])
        XCTAssertEqual(results.first?.status, .ok)
        XCTAssertEqual(results.first?.images.map(\.reference), ["registry.example.com/team/api", "registry.example.com/tools/api-cli"])

        // The second search uses the cached list and skips the Harbor probe.
        let before = http.calls.count
        let again = await service.search("web", in: [source])
        XCTAssertEqual(again.first?.images.map(\.repository), ["team/web"])
        XCTAssertEqual(http.calls.count, before)
    }

    func testCatalogRefusedShowsListingNote() async {
        let http = ScriptedRegistryHTTP { url, _ in
            url.path == "/v2/_catalog"
                ? json(#"{"errors":[{"code":"UNSUPPORTED"}]}"#, status: 404)
                : json("", status: 404)
        }
        let gitlab = RegistrySource(host: "registry.gitlab.com", keychainServer: "registry.gitlab.com")
        let service = RegistrySearchService(http: http, credentials: FakeRegistryCredentials(quiet: ["registry.gitlab.com": .found(testCredential)]))
        let results = await service.search("app", in: [gitlab])
        XCTAssertEqual(results.first?.status, .listingRefused)
        XCTAssertEqual(RegistrySearchCopy.listingRefused, "This registry does not allow listing. Enter a full image name to see its tags.")

        // Without keychain access the anonymous try is refused too: say why.
        let locked = RegistrySearchService(http: http, credentials: FakeRegistryCredentials(quiet: ["registry.gitlab.com": .needsPermission]))
        let lockedResults = await locked.search("app", in: [gitlab])
        XCTAssertEqual(lockedResults.first?.status, .needsKeychainAccess)
    }

    func testHarborSearchThroughService() async {
        let http = ScriptedRegistryHTTP { url, headers in
            XCTAssertNil(headers["Authorization"])
            if url.path == "/api/v2.0/search" {
                XCTAssertEqual(url.query, "q=nginx")
                return json(RegistrySearchFixtures.harborSearch)
            }
            XCTFail("Harbor search should be enough, not \(url)")
            return json("", status: 500)
        }
        let harbor = RegistrySource(host: "demo.goharbor.io")
        let results = await RegistrySearchService(http: http, credentials: FakeRegistryCredentials()).search("nginx", in: [harbor])
        XCTAssertEqual(results.first?.images.count, 3)
        XCTAssertEqual(results.first?.status, .ok)
    }

    func testGitHubSearchWithToken() async {
        let http = ScriptedRegistryHTTP { url, headers in
            XCTAssertEqual(headers["Authorization"], "Bearer not-a-real-secret")
            switch url.path {
            case "/user/packages": return json(RegistrySearchFixtures.githubPackages)
            case "/user/orgs": return json(RegistrySearchFixtures.githubOrgs)
            case "/orgs/octo-org/packages": return json(RegistrySearchFixtures.githubOrgPackages)
            default: return json("", status: 404)
            }
        }
        let ghcr = RegistrySource(host: "ghcr.io", keychainServer: "ghcr.io", username: "deck-test-user")
        let service = RegistrySearchService(http: http, credentials: FakeRegistryCredentials(quiet: ["ghcr.io": .found(testCredential)]))
        let results = await service.search("prometheus", in: [ghcr])
        XCTAssertEqual(results.first?.status, .ok)
        XCTAssertEqual(results.first?.images.map(\.reference), ["ghcr.io/monalisa/tools/prometheus-exporter", "ghcr.io/octo-org/prometheus-agent"])
    }

    func testGitHubWithoutTokenOffersLookup() async {
        let http = ScriptedRegistryHTTP { url, _ in
            XCTFail("No call expected, got \(url)")
            return json("", status: 500)
        }
        let signedIn = RegistrySource(host: "ghcr.io", keychainServer: "ghcr.io")
        let locked = RegistrySearchService(http: http, credentials: FakeRegistryCredentials(quiet: ["ghcr.io": .needsPermission]))
        let lockedResult = await locked.search("x", in: [signedIn])
        XCTAssertEqual(lockedResult.first?.status, .needsKeychainAccess)

        let missing = RegistrySearchService(http: http, credentials: FakeRegistryCredentials())
        let missingResult = await missing.search("x", in: [signedIn, RegistrySource(host: "public.ecr.aws")])
        XCTAssertEqual(missingResult.map(\.status), [
            .lookupOnly(RegistrySearchCopy.lookupNote(for: .github)),
            .lookupOnly(RegistrySearchCopy.lookupNote(for: .amazon))
        ])
    }

    func testAllowingAccessKeepsTheLoginForTheNextSearch() async {
        let http = ScriptedRegistryHTTP { url, _ in
            url.path == "/user/orgs" ? json("[]") : json(RegistrySearchFixtures.githubPackages)
        }
        let ghcr = RegistrySource(host: "ghcr.io", keychainServer: "ghcr.io")
        let service = RegistrySearchService(http: http, credentials: FakeRegistryCredentials(
            quiet: ["ghcr.io": .needsPermission], prompted: ["ghcr.io": .found(testCredential)]))
        let first = await service.search("hello", in: [ghcr])
        XCTAssertEqual(first.first?.status, .needsKeychainAccess)
        let allowed = await service.requestAccess(ghcr)
        XCTAssertEqual(allowed, .found(testCredential))
        let second = await service.search("hello", in: [ghcr])
        XCTAssertEqual(second.first?.images.map(\.repository), ["monalisa/hello_docker"])
    }

    func testOneSlowOrBrokenRegistryDoesNotBlockTheOthers() async {
        let http = ScriptedRegistryHTTP { url, _ in
            switch url.host {
            case "quay.io":
                try await Task.sleep(for: .seconds(10))
                return json(RegistrySearchFixtures.quayFind)
            case "broken.example.com":
                return json("oops", status: 503)
            default:
                if url.path == "/v2/_catalog" { return json(#"{"repositories":["team/prometheus"]}"#) }
                return json("", status: 404)
            }
        }
        let sources = [RegistrySource.quay, RegistrySource(host: "broken.example.com"), RegistrySource(host: "fine.example.com")]
        let service = RegistrySearchService(http: http, credentials: FakeRegistryCredentials(), timeout: .milliseconds(400))
        let started = Date()
        let results = await service.search("prometheus", in: sources)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(results.map(\.source.host), ["quay.io", "broken.example.com", "fine.example.com"])
        XCTAssertEqual(results[0].status, .failed("No answer in time."))
        XCTAssertEqual(results[1].status, .failed("broken.example.com is having trouble (status 503)."))
        XCTAssertEqual(results[2].status, .ok)
        XCTAssertEqual(results[2].images.map(\.repository), ["team/prometheus"])
    }

    // MARK: Merge

    func testMergeAndSortAcrossRegistries() throws {
        let hub = try DockerHubClient.parseSearch(Data(RegistrySearchFixtures.hubSearch.utf8), page: 1).items.map(RegistryImage.init(hub:))
        let quay = try QuaySearch.parse(Data(RegistrySearchFixtures.quayFind.utf8)).images
        let results = [
            RegistrySearchResult(source: .dockerHub, images: hub),
            RegistrySearchResult(source: .quay, images: quay + [quay[0]]),
            RegistrySearchResult(source: RegistrySource(host: "ghcr.io"), status: .lookupOnly("x"))
        ]
        let merged = RegistrySearchMerge.merge(results, query: "prometheus")
        XCTAssertEqual(merged.map(\.id), [
            // Exact names first, taking turns between registries.
            "docker.io/prom/prometheus",
            "quay.io/prometheus/prometheus",
            "docker.io/bitnami/prometheus",
            // Then names that start with the query, in each registry's order.
            "quay.io/prometheus-operator/prometheus-config-reloader",
            "quay.io/prometheus-operator/prometheus-operator"
        ])
        XCTAssertEqual(RegistrySearchMerge.tier(repository: "library/nginx", query: "NGINX"), 0)
        XCTAssertEqual(RegistrySearchMerge.tier(repository: "a/b", query: ""), 3)
    }
}

/// Real public registries. Opt in with DECK_LIVE_REGISTRY=1. No sign in, no credentials.
final class RegistrySearchLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_LIVE_REGISTRY"] == "1", "Set DECK_LIVE_REGISTRY=1 to call real registries.")
    }

    func testDockerHubQuayAndAnonymousGhcr() async throws {
        let service = RegistrySearchService(credentials: FakeRegistryCredentials())
        let results = await service.search("prometheus", in: [.dockerHub, .quay])
        XCTAssertEqual(results.map(\.status), [.ok, .ok])
        XCTAssertFalse(results[0].images.isEmpty)
        XCTAssertFalse(results[1].images.isEmpty)
        let lookup = try await service.lookup("ghcr.io/astral-sh/uv", in: nil)
        XCTAssertTrue(lookup.tags.items.contains { $0.name == "latest" })
        let quayTags = try await service.tags(RegistryImage(registry: "quay.io", repository: "prometheus/node-exporter"))
        XCTAssertFalse(quayTags.items.isEmpty)
    }
}
