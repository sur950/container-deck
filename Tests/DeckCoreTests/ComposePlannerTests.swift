import XCTest
@testable import DeckCore

private let plannerFile = URL(fileURLWithPath: "/work/shop/compose.yaml")

private let shopYAML = """
name: shop
services:
  web:
    image: nginx
    entrypoint: ["/bin/sh", "-c"]
    command: ["nginx -g 'daemon off;'"]
    ports: ["8080:80"]
    volumes:
      - data:/data
      - ./conf:/etc/nginx/conf.d:ro
    depends_on: [db]
    labels:
      team: web
  db:
    image: postgres
    cpus: 2.5
    mem_limit: 2g
    container_name: shop-database
  debug:
    image: busybox
    profiles: [debug]
volumes:
  data:
"""

final class ComposePlannerTests: XCTestCase {

    private func project(_ yaml: String = shopYAML) throws -> ComposeProject {
        try ComposeParser.parse(yaml, file: plannerFile, environment: [:], readFile: { _ in nil })
    }

    func testRunOptions() throws {
        let settings = ComposePlanSettings(defaultCPUs: 2, defaultMemory: "1G")
        let plan = try ComposePlanner.plan(try project(), settings: settings)

        XCTAssertEqual(plan.services.map(\.name), ["db", "web"])
        XCTAssertEqual(plan.skipped, ["debug"])
        XCTAssertEqual(plan.networks.map(\.name), ["shop_default"])
        XCTAssertEqual(plan.volumes.map(\.name), ["shop_data"])
        XCTAssertEqual(plan.volumes.first?.labels[ComposeLabel.project], "shop")

        let web = try XCTUnwrap(plan.service("web"))
        let options = web.options
        XCTAssertEqual(web.containerName, "shop-web")
        XCTAssertEqual(options.name, "shop-web")
        XCTAssertEqual(options.image, "nginx")
        XCTAssertEqual(options.entrypoint, "/bin/sh")
        XCTAssertEqual(options.command, ["-c", "nginx -g 'daemon off;'"])
        XCTAssertEqual(options.ports, [PortMapping(hostPort: 8080, containerPort: 80)])
        XCTAssertEqual(options.mounts.count, 2)
        XCTAssertEqual(options.mounts[0].kind, .volume)
        XCTAssertEqual(options.mounts[0].source, "shop_data")
        XCTAssertEqual(options.mounts[0].destination, "/data")
        XCTAssertEqual(options.mounts[1].kind, .bind)
        XCTAssertEqual(options.mounts[1].source, "/work/shop/conf")
        XCTAssertTrue(options.mounts[1].readOnly)
        XCTAssertEqual(options.cpus, 2)
        XCTAssertEqual(options.memory, "1G")
        XCTAssertEqual(options.network, "shop_default")
        XCTAssertTrue(options.detach)
        XCTAssertEqual(options.labels["team"], "web")
        XCTAssertEqual(options.labels[ComposeLabel.project], "shop")
        XCTAssertEqual(options.labels[ComposeLabel.service], "web")
        XCTAssertEqual(options.labels[ComposeLabel.configHash], web.configHash)
        XCTAssertEqual(options.labels[ComposeLabel.file], plannerFile.path)
        XCTAssertNil(web.build)

        let db = try XCTUnwrap(plan.service("db"))
        XCTAssertEqual(db.options.name, "shop-database")
        XCTAssertEqual(db.options.cpus, 3)
        XCTAssertEqual(db.options.memory, "2G")
        XCTAssertEqual(db.options.command, [])
        XCTAssertNil(db.options.entrypoint)
    }

    func testEmptyEntrypointDropsTheImageEntrypoint() throws {
        let plan = try ComposePlanner.plan(try project("""
        services:
          list:
            image: nginx
            entrypoint: []
            command: ["ls", "-l", "/"]
          blank:
            image: nginx
            entrypoint: ""
            command: echo hi
          kept:
            image: nginx
            command: ["nginx", "-g", "daemon off;"]
        """))
        XCTAssertEqual(plan.service("list")?.options.entrypoint, "ls")
        XCTAssertEqual(plan.service("list")?.options.command, ["-l", "/"])
        XCTAssertEqual(plan.service("blank")?.options.entrypoint, "echo")
        XCTAssertEqual(plan.service("blank")?.options.command, ["hi"])
        XCTAssertNil(plan.service("kept")?.options.entrypoint)
        XCTAssertEqual(plan.service("kept")?.options.command, ["nginx", "-g", "daemon off;"])
    }

    func testProfilesFilter() throws {
        let plan = try ComposePlanner.plan(try project(), settings: ComposePlanSettings(activeProfiles: ["debug"]))
        XCTAssertEqual(Set(plan.services.map(\.name)), ["db", "web", "debug"])
        XCTAssertEqual(plan.skipped, [])
    }

    func testProfileServicePullsInDependencies() throws {
        let yaml = """
        services:
          tool:
            image: x
            profiles: [ops]
            depends_on: [helper]
          helper:
            image: y
            profiles: [other]
        """
        let without = try ComposePlanner.plan(try project(yaml))
        XCTAssertEqual(without.services.map(\.name), [])
        let with = try ComposePlanner.plan(try project(yaml), settings: ComposePlanSettings(activeProfiles: ["ops"]))
        XCTAssertEqual(with.services.map(\.name), ["helper", "tool"])
    }

    func testBuildPlan() throws {
        let yaml = """
        services:
          api:
            build:
              context: ./api
              args:
                MODE: dev
            platform: linux/amd64
        """
        let plan = try ComposePlanner.plan(try project(yaml))
        let api = try XCTUnwrap(plan.service("api"))
        XCTAssertEqual(api.options.image, "shop-api:latest")
        XCTAssertEqual(api.build?.contextDir, "/work/shop/api")
        XCTAssertEqual(api.build?.tags, ["shop-api:latest"])
        XCTAssertEqual(api.build?.buildArgs, [EnvVar(key: "MODE", value: "dev")])
        XCTAssertEqual(api.build?.platform, "linux/amd64")
        XCTAssertEqual(api.options.platform, "linux/amd64")

        let commands = plan.commands(runArguments: { ["run", $0.image] })
        XCTAssertEqual(commands.map(\.id), ["network-shop_default", "build-api", "run-api"])
        XCTAssertEqual(commands.last?.arguments, ["run", "shop-api:latest"])
    }

    func testCommandsIncludeNetworksVolumesAndRuns() throws {
        let plan = try ComposePlanner.plan(try project())
        let commands = plan.commands(runArguments: { _ in ["run"] })
        XCTAssertEqual(commands.map(\.id), ["network-shop_default", "volume-shop_data", "run-db", "run-web"])
        XCTAssertEqual(commands.first?.arguments, ["network", "create", "shop_default"])
    }

    func testCyclePlanThrows() throws {
        let yaml = """
        services:
          a:
            image: x
            depends_on: [b]
          b:
            image: x
            depends_on: [a]
        """
        XCTAssertThrowsError(try ComposePlanner.plan(try project(yaml)))
    }

    // MARK: Hash

    func testHashIsStableAcrossKeyOrder() throws {
        let first = """
        services:
          web:
            image: nginx
            environment:
              A: "1"
              B: "2"
            ports: ["8080:80", "8443:443"]
            labels:
              x: "1"
              y: "2"
        """
        let second = """
        services:
          web:
            labels:
              y: "2"
              x: "1"
            ports: ["8443:443", "8080:80"]
            environment:
              B: "2"
              A: "1"
            image: nginx
        """
        let a = try XCTUnwrap(try ComposePlanner.plan(try project(first)).service("web"))
        let b = try XCTUnwrap(try ComposePlanner.plan(try project(second)).service("web"))
        XCTAssertEqual(a.configHash, b.configHash)
        XCTAssertEqual(a.configHash.count, 64)

        // Same input, same hash, every time.
        let again = try XCTUnwrap(try ComposePlanner.plan(try project(first)).service("web"))
        XCTAssertEqual(a.configHash, again.configHash)
    }

    func testHashChangesWithConfig() throws {
        let base = """
        services:
          web:
            image: nginx
            environment:
              A: "1"
        """
        let changed = base.replacingOccurrences(of: "A: \"1\"", with: "A: \"2\"")
        let a = try XCTUnwrap(try ComposePlanner.plan(try project(base)).service("web"))
        let b = try XCTUnwrap(try ComposePlanner.plan(try project(changed)).service("web"))
        XCTAssertNotEqual(a.configHash, b.configHash)

        let cpus = try XCTUnwrap(try ComposePlanner.plan(try project(base), settings: ComposePlanSettings(defaultCPUs: 4)).service("web"))
        XCTAssertNotEqual(a.configHash, cpus.configHash)
    }

    func testHashIgnoresHashAndFileLabels() {
        var options = RunOptions(image: "nginx", name: "web", labels: ["a": "b"])
        let plain = ComposePlanner.configHash(options, build: nil)
        options.labels[ComposeLabel.configHash] = "old"
        options.labels[ComposeLabel.file] = "/somewhere/else.yaml"
        XCTAssertEqual(ComposePlanner.configHash(options, build: nil), plain)
    }

    // MARK: Runner helpers

    func testHostsLines() {
        let lines = ComposeRunner.hostsLines(project: "shop", entries: [
            ComposeHostEntry(service: "web", containerName: "shop-web", ip: "192.168.64.3"),
            ComposeHostEntry(service: "db", containerName: "shop-database", ip: "192.168.64.4", aliases: ["postgres"])
        ])
        XCTAssertEqual(lines, [
            "192.168.64.4 db shop-db shop-database postgres  # deck-compose",
            "192.168.64.3 web shop-web  # deck-compose"
        ])
        XCTAssertEqual(ComposeRunner.cleanIP("192.168.64.3/24"), "192.168.64.3")
        XCTAssertNil(ComposeRunner.cleanIP(""))
    }

    func testImageNamesCompare() {
        XCTAssertEqual(ComposeRunner.normalizeImage("docker.io/library/nginx:latest"), ComposeRunner.normalizeImage("nginx"))
        XCTAssertEqual(ComposeRunner.normalizeImage("docker.io/grafana/grafana"), "grafana/grafana:latest")
        XCTAssertEqual(ComposeRunner.normalizeImage("localhost:5000/app"), "localhost:5000/app:latest")
        XCTAssertEqual(ComposeRunner.normalizeImage("ghcr.io/x/y:1.0"), "ghcr.io/x/y:1.0")
    }

    func testExitCodeFromInspect() {
        XCTAssertEqual(ComposeRunner.exitCode(fromInspectJSON: #"{"status": {"exitCode": 3}}"#), 3)
        XCTAssertEqual(ComposeRunner.exitCode(fromInspectJSON: #"{"exitCode":0}"#), 0)
        XCTAssertNil(ComposeRunner.exitCode(fromInspectJSON: "{}"))
    }

    func testStacksGroupedByLabel() {
        let containers = [
            ContainerSummary(id: "shop-web", name: "shop-web", image: "nginx", state: .running,
                             labels: [ComposeLabel.project: "shop", ComposeLabel.service: "web", ComposeLabel.file: "/work/shop/compose.yaml"]),
            ContainerSummary(id: "shop-db", name: "shop-db", image: "postgres", state: .stopped,
                             labels: [ComposeLabel.project: "shop", ComposeLabel.service: "db"]),
            ContainerSummary(id: "lonely", name: "lonely", image: "alpine", state: .running)
        ]
        let stacks = ComposeStack.group(containers)
        XCTAssertEqual(stacks.map(\.name), ["shop"])
        XCTAssertEqual(stacks.first?.services.map(\.service), ["db", "web"])
        XCTAssertEqual(stacks.first?.runningCount, 1)
        XCTAssertEqual(stacks.first?.file?.path, "/work/shop/compose.yaml")
    }

    func testRecentsKeepNewestFirst() throws {
        let suite = "deck-compose-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = ComposeRecents(defaults: defaults)
        recents.add(URL(fileURLWithPath: "/a/compose.yaml"))
        recents.add(URL(fileURLWithPath: "/b/compose.yaml"))
        recents.add(URL(fileURLWithPath: "/a/compose.yaml"))
        XCTAssertEqual(recents.files.map(\.path), ["/a/compose.yaml", "/b/compose.yaml"])
        recents.remove(URL(fileURLWithPath: "/b/compose.yaml"))
        XCTAssertEqual(recents.files.map(\.path), ["/a/compose.yaml"])
        XCTAssertEqual(ComposeRecents.defaultsKey, "composeRecentFiles")
    }
}
