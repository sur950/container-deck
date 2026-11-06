import XCTest
@testable import DeckCore

final class DomainsRoutingTests: XCTestCase {

    private func container(_ name: String, ip: String? = "192.168.65.2", ports: [PortMapping] = [], labels: [String: String] = [:], image: String = "nginx", state: ContainerRunState = .running) -> ContainerSummary {
        ContainerSummary(id: name, name: name, image: image, state: state, ipAddress: ip, ports: ports, labels: labels)
    }

    // MARK: Host names

    func testHostNameRules() {
        XCTAssertTrue(HostName.isValidName("web.localhost"))
        XCTAssertTrue(HostName.isValidName("API.Test."))
        XCTAssertFalse(HostName.isValidName("localhost"))
        XCTAssertFalse(HostName.isValidName("-web.test"))
        XCTAssertFalse(HostName.isValidName("we_b.test"))
        XCTAssertFalse(HostName.isValidName("web..test"))
        XCTAssertTrue(HostName.isValidPattern("*.gateway.test"))
        XCTAssertFalse(HostName.isValidPattern("*.test"))
        XCTAssertFalse(HostName.isValidPattern("a.*.test"))
    }

    func testWildcardMatching() {
        XCTAssertTrue(HostName.matches(pattern: "*.gateway.test", host: "a.gateway.test"))
        XCTAssertTrue(HostName.matches(pattern: "*.gateway.test", host: "a.b.gateway.test"))
        XCTAssertFalse(HostName.matches(pattern: "*.gateway.test", host: "gateway.test"))
        XCTAssertFalse(HostName.matches(pattern: "*.gateway.test", host: "xgateway.test"))
        XCTAssertTrue(HostName.matches(pattern: "api.test", host: "API.test"))
    }

    func testResolverNeedsAndDomain() {
        XCTAssertFalse(HostName.needsResolver("api.localhost"))
        XCTAssertFalse(HostName.needsResolver("*.gw.localhost"))
        XCTAssertTrue(HostName.needsResolver("api.test"))
        XCTAssertEqual(HostName.resolverDomain("*.gateway.test"), "gateway.test")
        XCTAssertEqual(HostName.resolverDomain("api.test"), "api.test")
    }

    func testContainerNameToLabel() {
        XCTAssertEqual(HostName.label(for: "deck-demo-web"), "deck-demo-web")
        XCTAssertEqual(HostName.label(for: "My_App.v2"), "my-app-v2")
        XCTAssertEqual(HostName.label(for: "__x__"), "x")
        XCTAssertNil(HostName.label(for: "___"))
        XCTAssertEqual(HostName.label(for: String(repeating: "a", count: 80))?.count, 63)
    }

    // MARK: Ports

    func testPortPriority() {
        let labelled = container("a", ports: [PortMapping(hostPort: 8080, containerPort: 80)], labels: ["deck.port": "3000"])
        XCTAssertEqual(RoutePlanner.port(for: labelled).port, 3000)
        XCTAssertEqual(RoutePlanner.port(for: labelled).source, .label)

        let published = container("b", ports: [PortMapping(hostPort: 5353, containerPort: 53, proto: "udp"), PortMapping(hostPort: 18090, containerPort: 80)])
        XCTAssertEqual(RoutePlanner.port(for: published).port, 80)
        XCTAssertEqual(RoutePlanner.port(for: published).source, .published)

        XCTAssertEqual(RoutePlanner.port(for: container("c"), exposed: [8000]).source, .exposed)
        XCTAssertEqual(RoutePlanner.port(for: container("d")).port, 80)
        XCTAssertEqual(RoutePlanner.port(for: container("d")).source, .fallback)
        // A bad label is ignored.
        XCTAssertEqual(RoutePlanner.port(for: container("e", labels: ["deck.port": "http"])).source, .fallback)
        XCTAssertEqual(RoutePlanner.port(for: container("e", labels: ["deck.port": "70000"])).source, .fallback)
    }

    func testExposedPortParsing() {
        XCTAssertEqual(RoutePlanner.exposedTCPPorts(["80/tcp", "443/TCP", "53/udp", "9000", "x/tcp"]), [80, 443, 9000])
    }

    // MARK: Routes

    func testRoutesFromContainersAndAliases() {
        let containers = [
            container("deck-demo-web", ip: "192.168.65.2", ports: [PortMapping(hostPort: 18090, containerPort: 80)]),
            container("deck-demo-worker", ip: "192.168.65.3", image: "alpine"),
            container("buildkit", ip: "192.168.64.15"),
            container("hidden", labels: ["deck.route": "false"]),
            container("old", ip: nil, state: .stopped),
        ]
        let aliases = [
            ProxyAlias(pattern: "API.test", container: "deck-demo-web"),
            ProxyAlias(pattern: "*.gateway.test", container: "deck-demo-worker", port: 9000),
            ProxyAlias(pattern: "deck-demo-web.localhost", container: "old"), // taken by the automatic route
        ]
        let routes = RoutePlanner.routes(containers: containers, aliases: aliases, exposedPorts: ["alpine": [8080]])
        XCTAssertEqual(routes.map(\.host), [
            "deck-demo-web.localhost", "deck-demo-worker.localhost", "old.localhost", "api.test", "*.gateway.test",
        ])
        let web = routes[0]
        XCTAssertEqual(web.target, "192.168.65.2:80")
        XCTAssertEqual(web.url(port: 8443), "https://deck-demo-web.localhost:8443")
        XCTAssertEqual(web.url(port: 443), "https://deck-demo-web.localhost")
        XCTAssertEqual(web.upstreamURL, "http://192.168.65.2:80")
        XCTAssertEqual(routes[1].targetPort, 8080)
        XCTAssertEqual(routes[1].source, .exposed)
        XCTAssertFalse(routes[2].isReachable)
        XCTAssertEqual(routes[3].targetPort, 80)
        XCTAssertEqual(routes[3].source, .alias)
        XCTAssertEqual(routes[4].targetPort, 9000)
        XCTAssertEqual(routes[4].url(port: 8443), "https://app.gateway.test:8443")
    }

    func testRouteMatchingPrefersExactThenLongestWildcard() {
        let routes = [
            ProxyRoute(host: "*.test.localhost", container: "a", targetHost: "1.1.1.1", targetPort: 1, source: .alias),
            ProxyRoute(host: "*.api.test.localhost", container: "b", targetHost: "1.1.1.2", targetPort: 2, source: .alias),
            ProxyRoute(host: "v1.api.test.localhost", container: "c", targetHost: "1.1.1.3", targetPort: 3, source: .alias),
        ]
        XCTAssertEqual(RoutePlanner.match(host: "v1.api.test.localhost", in: routes)?.container, "c")
        XCTAssertEqual(RoutePlanner.match(host: "v2.api.test.localhost", in: routes)?.container, "b")
        XCTAssertEqual(RoutePlanner.match(host: "web.test.localhost", in: routes)?.container, "a")
        XCTAssertNil(RoutePlanner.match(host: "web.localhost", in: routes))
    }

    func testDuplicateLabelsKeepRunningFirst() {
        let routes = RoutePlanner.routes(containers: [
            container("web_1", ip: nil, state: .stopped),
            container("web-1", ip: "10.0.0.2"),
        ])
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].container, "web-1")
    }

    func testAliasCodableRoundTrip() throws {
        let alias = ProxyAlias(pattern: " *.GW.test. ", container: "web", port: 3000)
        XCTAssertEqual(alias.pattern, "*.gw.test")
        XCTAssertTrue(alias.isWildcard)
        XCTAssertTrue(alias.needsResolver)
        let decoded = try JSONDecoder().decode(ProxyAlias.self, from: JSONEncoder().encode(alias))
        XCTAssertEqual(decoded, alias)
    }
}
