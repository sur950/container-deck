import XCTest
@testable import DeckCore

// Several compose files in one project: merge rules from the Compose
// Specification, !reset and !override, override file discovery, COMPOSE_FILE,
// relative paths, problem file attribution, include and extends.

final class ComposeMergeTests: XCTestCase {

    // MARK: Helpers

    /// Loads in-memory files. `files` maps absolute paths to YAML.
    private func load(
        _ files: [String: String],
        main: [String] = ["/p/compose.yaml", "/p/compose.override.yaml"],
        env: [String: String] = [:],
        projectDirectory: String? = nil
    ) throws -> ComposeProject {
        try ComposeParser.load(
            files: main.map { URL(fileURLWithPath: $0) },
            projectDirectory: projectDirectory.map { URL(fileURLWithPath: $0) },
            processEnvironment: env,
            readFile: { files[$0.standardizedFileURL.path] }
        )
    }

    /// Base and override for one service `web`, then the merged service.
    private func merged(_ base: String, _ override: String, top: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> ComposeService {
        let project = try load([
            "/p/compose.yaml": "services:\n  web:\n    image: nginx\n" + indent(base) + top,
            "/p/compose.override.yaml": "services:\n  web:\n" + indent(override)
        ])
        return try XCTUnwrap(project.service("web"), file: file, line: line)
    }

    private func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    " + $0 }
            .joined(separator: "\n") + "\n"
    }

    private func tree(_ yaml: String) throws -> ComposeNode {
        try XCTUnwrap(ComposeNodeBuilder.parse(yaml, interpolator: ComposeInterpolator(values: [:])).node)
    }

    /// Text items of a merged sequence, by path.
    private func mergedItems(_ base: String, _ override: String, at path: [String]) throws -> [String] {
        let result = ComposeMerge.merge(try tree(base), try tree(override)).cleaned()
        var node: ComposeNode? = result
        for key in path { node = node?[key] }
        return node?.items?.map { $0.text ?? "{map}" } ?? []
    }

    // MARK: Merge rules, table driven

    struct Case {
        let name: String
        let base: String
        let override: String
        var top: String = ""
        let check: (ComposeService) -> Void
    }

    func testMergeRulesTable() throws {
        let cases: [Case] = [
            Case(name: "scalars are replaced", base: "user: root", override: "image: nginx:1.27\nuser: app") {
                XCTAssertEqual($0.image, "nginx:1.27")
                XCTAssertEqual($0.user, "app")
            },
            Case(name: "mappings merge recursively", base: "healthcheck:\n  test: [\"CMD\", \"true\"]\n  interval: 10s", override: "healthcheck:\n  retries: 7") {
                XCTAssertEqual($0.healthcheck?.command, ["true"])
                XCTAssertEqual($0.healthcheck?.interval, 10)
                XCTAssertEqual($0.healthcheck?.retries, 7)
            },
            Case(name: "ports are a union without duplicates", base: "ports: [\"8080:80\"]", override: "ports: [\"8080:80\", \"8443:443\"]") {
                XCTAssertEqual($0.ports.map(\.published), [8080, 8443])
            },
            Case(name: "long form ports dedupe by ip, target, published and protocol",
                 base: "ports:\n  - target: 80\n    published: 8080", override: "ports:\n  - target: 80\n    published: 8080\n  - target: 80\n    published: 8080\n    protocol: udp") {
                XCTAssertEqual($0.ports.map(\.proto), ["tcp", "udp"])
            },
            Case(name: "dns is a union", base: "dns: 1.1.1.1", override: "dns: [8.8.8.8, 1.1.1.1]") {
                XCTAssertEqual($0.dns, ["1.1.1.1", "8.8.8.8"])
            },
            Case(name: "dns_search is a union", base: "dns_search: [a.local]", override: "dns_search: [b.local, a.local]") {
                XCTAssertEqual($0.dnsSearch, ["a.local", "b.local"])
            },
            Case(name: "tmpfs is a union", base: "tmpfs: /run", override: "tmpfs: [/tmp, /run]") {
                XCTAssertEqual($0.tmpfs, ["/run", "/tmp"])
            },
            Case(name: "cap_add and profiles are unions", base: "cap_add: [NET_ADMIN]\nprofiles: [a]", override: "cap_add: [SYS_TIME, NET_ADMIN]\nprofiles: [b]") {
                XCTAssertEqual($0.capAdd, ["NET_ADMIN", "SYS_TIME"])
                XCTAssertEqual($0.profiles, ["a", "b"])
            },
            Case(name: "volumes merge by target, at the place of the first",
                 base: "volumes: [\"data:/work\", \"./a:/a\"]", override: "volumes: [\"other:/work\", \"/b\"]",
                 top: "volumes:\n  data: {}\n  other: {}\n") {
                XCTAssertEqual($0.volumes.map(\.target), ["/work", "/a", "/b"])
                XCTAssertEqual($0.volumes.first?.source, "other")
            },
            Case(name: "long and short volumes share the target key",
                 base: "volumes: [\"./a:/a\"]", override: "volumes:\n  - type: bind\n    source: ./b\n    target: /a\n    read_only: true") {
                XCTAssertEqual($0.volumes.count, 1)
                XCTAssertEqual($0.volumes.first?.source, "/p/b")
                XCTAssertEqual($0.volumes.first?.readOnly, true)
            },
            Case(name: "environment merges by key, list over map", base: "environment:\n  A: \"1\"\n  B: \"2\"", override: "environment: [B=3, C=4]") {
                XCTAssertEqual($0.environment, [EnvVar(key: "A", value: "1"), EnvVar(key: "B", value: "3"), EnvVar(key: "C", value: "4")])
            },
            Case(name: "environment merges by key, map over list", base: "environment: [A=1, B=2]", override: "environment:\n  A: x") {
                XCTAssertEqual($0.environment, [EnvVar(key: "A", value: "x"), EnvVar(key: "B", value: "2")])
            },
            Case(name: "labels merge by key", base: "labels: [tier=web, team=a]", override: "labels:\n  team: b\n  extra: \"yes\"") {
                XCTAssertEqual($0.labels, ["tier": "web", "team": "b", "extra": "yes"])
            },
            Case(name: "command is replaced", base: "command: [\"echo\", \"foo\"]", override: "command: [\"echo\", \"bar\"]") {
                XCTAssertEqual($0.command, ["echo", "bar"])
            },
            Case(name: "entrypoint is replaced", base: "entrypoint: [\"/a\", \"-x\"]", override: "entrypoint: /b") {
                XCTAssertEqual($0.entrypoint, ["/b"])
            },
            Case(name: "healthcheck test is replaced", base: "healthcheck:\n  test: [\"CMD\", \"a\", \"b\"]", override: "healthcheck:\n  test: [\"CMD\", \"c\"]") {
                XCTAssertEqual($0.healthcheck?.command, ["c"])
            },
            Case(name: "depends_on merges by service, list and map", base: "depends_on: [db]", override: "depends_on:\n  cache:\n    condition: service_healthy",
                 top: "  db:\n    image: postgres\n  cache:\n    image: redis\n    healthcheck:\n      test: [\"CMD\", \"true\"]\n") {
                XCTAssertEqual($0.dependsOn.map(\.service), ["db", "cache"])
                XCTAssertEqual($0.dependsOn.map(\.condition), [.started, .healthy])
            },
            Case(name: "depends_on condition changes, required stays", base: "depends_on:\n  db:\n    condition: service_started\n    required: false",
                 override: "depends_on:\n  db:\n    condition: service_completed_successfully", top: "  db:\n    image: postgres\n") {
                XCTAssertEqual($0.dependsOn, [ComposeDependency(service: "db", condition: .completed, required: false)])
            },
            Case(name: "service networks merge as a map", base: "networks: [front]", override: "networks:\n  front:\n    aliases: [www]",
                 top: "networks:\n  front: {}\n") {
                XCTAssertEqual($0.networks, ["front"])
                XCTAssertEqual($0.networkAliases, ["www"])
            },
            Case(name: "extra_hosts merge by host", base: "extra_hosts: [\"a:1.1.1.1\", \"b=2.2.2.2\"]", override: "extra_hosts:\n  a: 9.9.9.9\n  c: 3.3.3.3") {
                XCTAssertEqual($0.extraHosts, ["9.9.9.9 a", "2.2.2.2 b", "3.3.3.3 c"])
            },
            Case(name: "build args merge by key, short build reads as context", base: "build:\n  context: ./app\n  args: [X=1, Y=2]", override: "build:\n  args:\n    Y: \"3\"") {
                XCTAssertEqual($0.build?.args, [EnvVar(key: "X", value: "1"), EnvVar(key: "Y", value: "3")])
                XCTAssertEqual($0.build?.context, "/p/app")
            },
            Case(name: "short build string merges with a long build", base: "build: ./app", override: "build:\n  dockerfile: Other.Dockerfile") {
                XCTAssertEqual($0.build?.context, "/p/app")
                XCTAssertEqual($0.build?.dockerfile, "/p/app/Other.Dockerfile")
            },
            Case(name: "a bare key keeps the earlier value", base: "working_dir: /srv", override: "working_dir:\nuser: app") {
                XCTAssertEqual($0.workingDir, "/srv")
            },
            Case(name: "ulimits merge per limit", base: "ulimits:\n  nofile:\n    soft: 10\n    hard: 20\n  nproc: 5", override: "ulimits:\n  nofile:\n    hard: 40") {
                XCTAssertEqual($0.ulimits, ["nofile=10:40", "nproc=5:5"])
            },
            Case(name: "!reset removes values", base: "ports: [\"8080:80\"]\nenvironment:\n  FOO: BAR\n  KEEP: \"1\"", override: "ports: !reset []\nenvironment:\n  FOO: !reset null") {
                XCTAssertEqual($0.ports, [])
                XCTAssertEqual($0.environment, [EnvVar(key: "KEEP", value: "1")])
                XCTAssertEqual($0.image, "nginx")
            },
            Case(name: "!reset on a list environment entry", base: "environment: [FOO=1, BAR=2]", override: "environment:\n  BAR: !reset") {
                XCTAssertEqual($0.environment, [EnvVar(key: "FOO", value: "1")])
            },
            Case(name: "!override replaces instead of merging", base: "ports: [\"8080:80\"]\nlabels: [a=1]", override: "ports: !override\n  - \"8443:443\"\nlabels: !override\n  b: \"2\"") {
                XCTAssertEqual($0.ports.map(\.published), [8443])
                XCTAssertEqual($0.labels, ["b": "2"])
            }
        ]
        for testCase in cases {
            let project = try load([
                "/p/compose.yaml": "services:\n  web:\n    image: nginx\n" + indent(testCase.base) + testCase.top,
                "/p/compose.override.yaml": "services:\n  web:\n" + indent(testCase.override)
            ])
            guard let service = project.service("web") else {
                XCTFail("\(testCase.name): no web service")
                continue
            }
            XCTContext.runActivity(named: testCase.name) { _ in testCase.check(service) }
            let blocking = project.problems.filter { $0.kind == .invalid }
            XCTAssertTrue(blocking.isEmpty, "\(testCase.name): \(blocking.map(\.message))")
        }
    }

    func testSequenceRulesAtTheTreeLevel() throws {
        // Keys the runtime cannot use still merge like Docker Compose, so `config` shows the truth.
        let rows: [(name: String, base: String, override: String, path: [String], expected: [String])] = [
            ("expose union", "s:\n  expose: [\"80\", \"443\"]", "s:\n  expose: [\"443\", \"8080\"]", ["s", "expose"], ["80", "443", "8080"]),
            ("external_links union", "s:\n  external_links: [a, b]", "s:\n  external_links: [b, c]", ["s", "external_links"], ["a", "b", "c"]),
            ("unknown lists append without exact duplicates", "s:\n  x: [a, b]", "s:\n  x: [b, c]", ["s", "x"], ["a", "b", "c"])
        ]
        for row in rows {
            XCTAssertEqual(try mergedItems(row.base, row.override, at: row.path), row.expected, row.name)
        }
        // Devices merge by the path inside the container.
        let devices = ComposeMerge.merge(
            try tree("services:\n  web:\n    devices: [\"/dev/a:/dev/x\", \"/dev/y\"]"),
            try tree("services:\n  web:\n    devices: [\"/dev/b:/dev/x\", \"/dev/c\"]")
        )
        XCTAssertEqual(devices["services"]?["web"]?["devices"]?.items?.compactMap(\.text), ["/dev/b:/dev/x", "/dev/y", "/dev/c"])
        // Top level labels on volumes and networks merge by key.
        let labels = ComposeMerge.merge(
            try tree("volumes:\n  data:\n    labels: [a=1, b=2]"),
            try tree("volumes:\n  data:\n    labels:\n      b: \"3\"")
        )
        XCTAssertEqual(ComposeMerge.keyValueEntries(try XCTUnwrap(labels["volumes"]?["data"]?["labels"]))?.map { "\($0.key)=\($0.node.text ?? "")" }, ["a=1", "b=3"])
        // IPAM config merges by subnet.
        let ipam = ComposeMerge.merge(
            try tree("networks:\n  n:\n    ipam:\n      config:\n        - subnet: 10.0.0.0/24\n          gateway: 10.0.0.1"),
            try tree("networks:\n  n:\n    ipam:\n      config:\n        - subnet: 10.0.0.0/24\n          gateway: 10.0.0.254\n        - subnet: 10.1.0.0/24")
        )
        let configs = ipam["networks"]?["n"]?["ipam"]?["config"]?.items ?? []
        XCTAssertEqual(configs.compactMap { $0["subnet"]?.text }, ["10.0.0.0/24", "10.1.0.0/24"])
        XCTAssertEqual(configs.first?["gateway"]?.text, "10.0.0.254")
    }

    func testThreeFilesMergeInOrderAndAddServices() throws {
        let project = try load([
            "/p/a.yaml": "name: shop\nservices:\n  web:\n    image: nginx:1\n    environment: [A=1]\n",
            "/p/b.yaml": "services:\n  web:\n    image: nginx:2\n    environment: [B=2]\n  worker:\n    image: alpine\n",
            "/p/c.yaml": "services:\n  web:\n    environment:\n      A: three\n"
        ], main: ["/p/a.yaml", "/p/b.yaml", "/p/c.yaml"])
        XCTAssertEqual(project.name, "shop")
        XCTAssertEqual(project.services.map(\.name), ["web", "worker"])
        XCTAssertEqual(project.service("web")?.image, "nginx:2")
        XCTAssertEqual(project.service("web")?.environment, [EnvVar(key: "A", value: "three"), EnvVar(key: "B", value: "2")])
        XCTAssertEqual(project.files.map(\.lastPathComponent), ["a.yaml", "b.yaml", "c.yaml"])
        XCTAssertEqual(project.overrideFiles.map(\.lastPathComponent), ["b.yaml", "c.yaml"])
    }

    func testResetOnAWholeServiceAndInTheBaseFile() throws {
        let project = try load([
            "/p/compose.yaml": "services:\n  web:\n    image: nginx\n    dns: !reset [1.1.1.1]\n  debug:\n    image: busybox\n",
            "/p/compose.override.yaml": "services:\n  debug: !reset null\n"
        ])
        XCTAssertEqual(project.services.map(\.name), ["web"])
        XCTAssertEqual(project.service("web")?.dns, [])
    }

    func testOverrideFileVariablesUseTheProjectEnvironment() throws {
        let project = try load([
            "/p/.env": "TAG=1.27\n",
            "/p/compose.yaml": "services:\n  web:\n    image: nginx\n",
            "/p/compose.override.yaml": "services:\n  web:\n    image: nginx:${TAG}\n"
        ])
        XCTAssertEqual(project.service("web")?.image, "nginx:1.27")
    }

    // MARK: Discovery and COMPOSE_FILE

    func testOverrideFileDiscoveryTable() {
        let rows: [(files: Set<String>, expected: [String])] = [
            (["/w/compose.yaml", "/w/compose.override.yaml"], ["/w/compose.yaml", "/w/compose.override.yaml"]),
            (["/w/compose.yml", "/w/compose.override.yml"], ["/w/compose.yml", "/w/compose.override.yml"]),
            (["/w/docker-compose.yml", "/w/docker-compose.override.yml"], ["/w/docker-compose.yml", "/w/docker-compose.override.yml"]),
            (["/w/docker-compose.yaml", "/w/docker-compose.override.yaml"], ["/w/docker-compose.yaml", "/w/docker-compose.override.yaml"]),
            (["/w/compose.yaml", "/w/docker-compose.yml", "/w/compose.override.yaml"], ["/w/compose.yaml", "/w/compose.override.yaml"]),
            (["/w/compose.yaml"], ["/w/compose.yaml"]),
            (["/w/compose.override.yaml"], [])
        ]
        for row in rows {
            let locator = ComposeFileLocator(fileExists: { row.files.contains($0) })
            XCTAssertEqual(locator.locate(from: URL(fileURLWithPath: "/w"), environment: [:]).map(\.path), row.expected, "\(row.files.sorted())")
        }
    }

    func testComposeFileAndPathSeparator() {
        let locator = ComposeFileLocator(fileExists: { _ in true })
        let dir = URL(fileURLWithPath: "/w")
        XCTAssertEqual(locator.locate(from: dir, environment: ["COMPOSE_FILE": "a.yaml:sub/b.yaml"]).map(\.path), ["/w/a.yaml", "/w/sub/b.yaml"])
        XCTAssertEqual(locator.locate(from: dir, environment: ["COMPOSE_FILE": "a.yaml;/abs/b.yaml", "COMPOSE_PATH_SEPARATOR": ";"]).map(\.path),
                       ["/w/a.yaml", "/abs/b.yaml"])
        // With COMPOSE_FILE set, no override file is added on its own.
        XCTAssertEqual(locator.locate(from: dir, environment: ["COMPOSE_FILE": "compose.yaml"]).map(\.path), ["/w/compose.yaml"])
    }

    func testLoadFromDiskMergesTheOverrideFileAndDashFDoesNot() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "services:\n  web:\n    image: nginx\n    ports: [\"8080:80\"]\n".write(to: dir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try "services:\n  web:\n    ports: [\"8443:443\"]\n".write(to: dir.appendingPathComponent("compose.override.yaml"), atomically: true, encoding: .utf8)

        let auto = try ComposeParser.load(file: dir.appendingPathComponent("compose.yaml"), processEnvironment: [:])
        XCTAssertEqual(auto.service("web")?.ports.map(\.published), [8080, 8443])
        XCTAssertEqual(auto.files.map(\.lastPathComponent), ["compose.yaml", "compose.override.yaml"])

        // The terminal: no -f finds both, -f compose.yaml reads only that file.
        let found = Captured()
        let code = await ComposeCLI(environment: [:], currentDirectory: dir, out: found.out, err: found.err, cliPath: "/fake").run(["config"])
        XCTAssertEqual(code, 0, found.stderr)
        XCTAssertTrue(found.stdout.contains("8443:443"), found.stdout)

        let only = Captured()
        let onlyCode = await ComposeCLI(environment: [:], currentDirectory: dir, out: only.out, err: only.err, cliPath: "/fake").run(["-f", "compose.yaml", "config"])
        XCTAssertEqual(onlyCode, 0, only.stderr)
        XCTAssertFalse(only.stdout.contains("8443"), only.stdout)

        let env = Captured()
        try "services:\n  web:\n    environment: [MODE=prod]\n".write(to: dir.appendingPathComponent("prod.yaml"), atomically: true, encoding: .utf8)
        let envCode = await ComposeCLI(environment: ["COMPOSE_FILE": "compose.yaml:prod.yaml"], currentDirectory: dir, out: env.out, err: env.err, cliPath: "/fake").run(["config"])
        XCTAssertEqual(envCode, 0, env.stderr)
        XCTAssertTrue(env.stdout.contains("MODE: prod"), env.stdout)
        XCTAssertFalse(env.stdout.contains("8443"), env.stdout)
    }

    func testConfigPrintsTheMergedResult() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("deploy"), withIntermediateDirectories: true)
        try """
        name: merged
        services:
          web:
            image: nginx:${TAG:-1}
            environment: [A=1, B=2]
            command: ["nginx", "-g", "daemon off;"]
        """.write(to: dir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try """
        services:
          web:
            environment:
              B: two
            command: ["nginx-debug"]
            volumes: ["./logs:/var/log/nginx"]
        """.write(to: dir.appendingPathComponent("deploy/prod.yaml"), atomically: true, encoding: .utf8)
        let output = Captured()
        let code = await ComposeCLI(environment: ["TAG": "1.27"], currentDirectory: dir, out: output.out, err: output.err, cliPath: "/fake")
            .run(["-f", "compose.yaml", "-f", "deploy/prod.yaml", "config"])
        XCTAssertEqual(code, 0, output.stderr)
        XCTAssertTrue(output.stdout.contains("\"nginx:1.27\""), output.stdout)
        XCTAssertTrue(output.stdout.contains("A: \"1\""), output.stdout)
        XCTAssertTrue(output.stdout.contains("B: two"), output.stdout)
        XCTAssertTrue(output.stdout.contains("- nginx-debug"), output.stdout)
        XCTAssertFalse(output.stdout.contains("daemon off"), output.stdout)
        // Paths in -f files resolve against the project directory, like Docker Compose.
        let logs = dir.appendingPathComponent("logs").standardizedFileURL.path
        XCTAssertTrue(output.stdout.contains(logs + ":/var/log/nginx"), output.stdout)
    }

    // MARK: Relative paths

    func testRelativePathsAcrossFolders() throws {
        let files = [
            "/p/compose.yaml": """
            include:
              - sub/compose.yaml
            services:
              web:
                build: ./web
                env_file: web.env
                volumes: ["./data:/data"]
              api:
                extends:
                  file: common/base.yaml
                  service: base
            """,
            "/p/deploy/override.yaml": """
            services:
              web:
                volumes: ["./more:/more"]
                env_file: ./deploy.env
            """,
            "/p/web.env": "A=1\n",
            "/p/deploy.env": "B=2\n",
            "/p/sub/compose.yaml": """
            services:
              db:
                build: .
                volumes: ["./pg:/var/lib/postgresql"]
                env_file: db.env
            """,
            "/p/sub/db.env": "C=3\n",
            "/p/common/base.yaml": """
            services:
              base:
                image: alpine
                env_file: common.env
                volumes: ["./shared:/shared"]
            """,
            "/p/common/common.env": "D=4\n"
        ]
        let project = try load(files, main: ["/p/compose.yaml", "/p/deploy/override.yaml"])
        let web = try XCTUnwrap(project.service("web"))
        XCTAssertEqual(web.build?.context, "/p/web")
        // Override files use the project directory, not their own folder.
        XCTAssertEqual(web.volumes.map(\.source), ["/p/data", "/p/more"])
        XCTAssertEqual(web.envFiles, ["/p/web.env", "/p/deploy.env"])
        XCTAssertEqual(web.environment, [EnvVar(key: "A", value: "1"), EnvVar(key: "B", value: "2")])
        // Included and extended files use their own folders.
        let db = try XCTUnwrap(project.service("db"))
        XCTAssertEqual(db.build?.context, "/p/sub")
        XCTAssertEqual(db.volumes.first?.source, "/p/sub/pg")
        XCTAssertEqual(db.environment, [EnvVar(key: "C", value: "3")])
        let api = try XCTUnwrap(project.service("api"))
        XCTAssertEqual(api.envFiles, ["/p/common/common.env"])
        XCTAssertEqual(api.volumes.first?.source, "/p/common/shared")
        XCTAssertEqual(api.environment, [EnvVar(key: "D", value: "4")])
        XCTAssertEqual(project.includedFiles.map(\.path), ["/p/sub/compose.yaml", "/p/common/base.yaml"])
        XCTAssertTrue(project.problems.filter { $0.kind == .invalid }.isEmpty, "\(project.problems)")
    }

    func testProjectDirectoryMovesTheBaseForPaths() throws {
        let project = try load([
            "/p/files/compose.yaml": "services:\n  web:\n    image: nginx\n    volumes: [\"./data:/data\"]\n"
        ], main: ["/p/files/compose.yaml"], projectDirectory: "/srv/app")
        XCTAssertEqual(project.service("web")?.volumes.first?.source, "/srv/app/data")
        XCTAssertEqual(project.name, "app")
    }

    // MARK: Problem attribution

    func testProblemsPointAtTheRightFileAndLine() throws {
        let project = try load([
            "/p/compose.yaml": "services:\n  web:\n    image: nginx\n    hostname: one\n",
            "/p/compose.override.yaml": "services:\n  web:\n    environment:\n      A: ${BROKEN\n    privileged: true\n"
        ])
        let privileged = try XCTUnwrap(project.problems.first { $0.key == "services.web.privileged" })
        XCTAssertEqual(privileged.file?.lastPathComponent, "compose.override.yaml")
        XCTAssertEqual(privileged.line, 5)
        let hostname = try XCTUnwrap(project.problems.first { $0.key == "services.web.hostname" })
        XCTAssertEqual(hostname.file?.lastPathComponent, "compose.yaml")
        XCTAssertEqual(hostname.line, 4)
        let variable = try XCTUnwrap(project.problems.first { $0.key == "variables" })
        XCTAssertEqual(variable.file?.lastPathComponent, "compose.override.yaml")
        XCTAssertEqual(variable.line, 4)

        XCTAssertEqual(privileged.location(), "compose.override.yaml:5")
        XCTAssertEqual(ComposeCLI.problemLine(privileged, relativeTo: URL(fileURLWithPath: "/")),
                       "not possible: p/compose.override.yaml:5: services.web.privileged: \(privileged.message)")
        XCTAssertTrue(ComposeCLI.problemLine(privileged).hasPrefix("not possible: compose.override.yaml:5: "))
    }

    func testProblemsInIncludedAndExtendedFiles() throws {
        let project = try load([
            "/p/compose.yaml": "include: [sub/compose.yaml]\nservices:\n  web:\n    extends:\n      file: base.yaml\n      service: base\n",
            "/p/base.yaml": "services:\n  base:\n    image: alpine\n    ipc: host\n",
            "/p/sub/compose.yaml": "services:\n  db:\n    image: postgres\n    tty: true\n"
        ], main: ["/p/compose.yaml"])
        let tty = try XCTUnwrap(project.problems.first { $0.key == "services.db.tty" })
        XCTAssertEqual(tty.file?.path, "/p/sub/compose.yaml")
        XCTAssertEqual(tty.line, 4)
        let ipc = try XCTUnwrap(project.problems.first { $0.key == "services.web.ipc" })
        XCTAssertEqual(ipc.file?.path, "/p/base.yaml")
        XCTAssertEqual(ipc.line, 4)
    }

    func testYAMLErrorInAnOverrideFileNamesThatFile() {
        XCTAssertThrowsError(try load([
            "/p/compose.yaml": "services:\n  web:\n    image: nginx\n",
            "/p/compose.override.yaml": "services:\n  web:\n   image: [\n"
        ])) { error in
            let fileError = error as? ComposeFileYAMLError
            XCTAssertEqual(fileError?.file.lastPathComponent, "compose.override.yaml")
            XCTAssertTrue(error.localizedDescription.contains("compose.override.yaml"), error.localizedDescription)
        }
    }

    // MARK: include

    func testIncludeLoadsSubProjectsWithTheirOwnEnv() throws {
        let project = try load([
            "/p/compose.yaml": """
            include:
              - path: ../shared/db.yaml
                env_file: ../shared/db.env
              - other/compose.yaml
            services:
              web:
                image: nginx
                depends_on: [db]
            """,
            "/shared/db.yaml": "services:\n  db:\n    image: postgres:${PG}\n    volumes: [\"pg:/var/lib/postgresql\"]\nvolumes:\n  pg: {}\n",
            "/shared/db.env": "PG=17\n",
            "/p/other/compose.yaml": "include: [nested.yaml]\nservices:\n  cache:\n    image: redis:${REDIS}\n",
            "/p/other/.env": "REDIS=8\n",
            "/p/other/nested.yaml": "services:\n  mail:\n    image: mailpit\n"
        ], main: ["/p/compose.yaml"])
        XCTAssertEqual(project.services.map(\.name).sorted(), ["cache", "db", "mail", "web"])
        XCTAssertEqual(project.service("db")?.image, "postgres:17")
        XCTAssertEqual(project.service("cache")?.image, "redis:8")
        XCTAssertEqual(project.volumes.map(\.key), ["pg"])
        XCTAssertTrue(project.problems.filter { $0.kind == .invalid }.isEmpty, "\(project.problems)")
    }

    func testIncludeConflictsMissingFilesAndLoops() throws {
        let project = try load([
            "/p/compose.yaml": "include: [a.yaml, missing.yaml, loop.yaml]\nservices:\n  web:\n    image: nginx:1\n",
            "/p/a.yaml": "services:\n  web:\n    image: nginx:2\n",
            "/p/loop.yaml": "include: [loop.yaml]\nservices:\n  looped:\n    image: alpine\n"
        ], main: ["/p/compose.yaml"])
        XCTAssertEqual(project.service("web")?.image, "nginx:1")
        let messages = project.problems.filter { $0.kind == .invalid }.map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("also defined in the included file a.yaml") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("missing.yaml was not found") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("loop") }, "\(messages)")
        XCTAssertFalse(project.problems.contains { $0.message.contains("include is not built yet") })
    }

    // MARK: extends

    func testExtendsInTheSameFileUsesTheMergeRules() throws {
        let project = try load([
            "/p/compose.yaml": """
            services:
              base:
                image: alpine
                command: ["sleep", "1"]
                ports: ["8080:80"]
                environment: [A=1, B=2]
              middle:
                extends: base
                environment:
                  B: middle
              web:
                extends:
                  service: middle
                command: ["sleep", "2"]
                ports: ["8443:443"]
                environment: [C=3]
            """
        ], main: ["/p/compose.yaml"])
        let web = try XCTUnwrap(project.service("web"))
        XCTAssertEqual(web.image, "alpine")
        XCTAssertEqual(web.command, ["sleep", "2"])
        XCTAssertEqual(web.ports.map(\.published), [8080, 8443])
        XCTAssertEqual(web.environment, [EnvVar(key: "A", value: "1"), EnvVar(key: "B", value: "middle"), EnvVar(key: "C", value: "3")])
        XCTAssertFalse(project.problems.contains { $0.key.hasSuffix("extends") }, "\(project.problems)")
    }

    func testExtendsWithResetAndProblems() throws {
        let project = try load([
            "/p/compose.yaml": """
            services:
              base:
                image: alpine
                ports: ["8080:80"]
              web:
                extends: base
                ports: !reset []
              lost:
                image: alpine
                extends: nowhere
              a:
                extends: b
              b:
                extends: a
              far:
                extends:
                  file: nope.yaml
                  service: x
            """
        ], main: ["/p/compose.yaml"])
        XCTAssertEqual(project.service("web")?.ports, [])
        let messages = project.problems.filter { $0.kind == .invalid }.map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("service nowhere was not found") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("loop") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("nope.yaml") }, "\(messages)")
        XCTAssertFalse(project.problems.contains { $0.message.contains("extends is not built yet") })
    }

    // MARK: App support

    func testRecentsRememberTheFileList() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "deck-merge-\(UUID().uuidString)"))
        let recents = ComposeRecents(defaults: defaults)
        let main = URL(fileURLWithPath: "/w/compose.yaml")
        let prod = URL(fileURLWithPath: "/w/prod.yaml")
        recents.add(main, extraFiles: [prod])
        XCTAssertEqual(recents.files, [main])
        XCTAssertEqual(recents.fileList(for: main), [main, prod])
        recents.add(main)
        XCTAssertEqual(recents.extraFiles(for: main), [])
        recents.add(main, extraFiles: [prod])
        recents.remove(main)
        XCTAssertEqual(recents.extraFiles(for: main), [])
    }

    func testPickedFilesAreSortedIntoMergeOrder() {
        let picked = ["/w/compose.override.yaml", "/w/prod.yaml", "/w/compose.yaml"].map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(ComposeFileOrder.sorted(picked).map(\.lastPathComponent), ["compose.yaml", "prod.yaml", "compose.override.yaml"])
    }

    func testStacksRememberEveryFile() throws {
        let project = try load([
            "/p/compose.yaml": "name: shop\nservices:\n  web:\n    image: nginx\n",
            "/p/compose.override.yaml": "services:\n  web:\n    environment: [A=1]\n"
        ])
        let plan = try ComposePlanner.plan(project)
        let labels = try XCTUnwrap(plan.services.first?.options.labels)
        XCTAssertEqual(labels[ComposeLabel.files], "/p/compose.yaml,/p/compose.override.yaml")
        XCTAssertEqual(labels[ComposeLabel.file], "/p/compose.yaml")
        XCTAssertEqual(ComposeLabel.filePaths(labels), ["/p/compose.yaml", "/p/compose.override.yaml"])

        // One file: no list label, and the label never changes the config hash.
        let single = try load(["/p/compose.yaml": "name: shop\nservices:\n  web:\n    image: nginx\n    environment: [A=1]\n"], main: ["/p/compose.yaml"])
        let singlePlan = try ComposePlanner.plan(single)
        XCTAssertNil(singlePlan.services.first?.options.labels[ComposeLabel.files])
        XCTAssertEqual(singlePlan.services.first?.configHash, plan.services.first?.configHash)

        XCTAssertEqual(ComposeLabel.filePaths([ComposeLabel.dockerConfigFiles: "compose.yaml,compose.override.yaml", ComposeLabel.dockerWorkingDir: "/w"]),
                       ["/w/compose.yaml", "/w/compose.override.yaml"])
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Live

/// A base file plus `compose.override.yaml` through the built plugin binary
/// against the real CLI, from a temp folder. DECK_LIVE_COMPOSE=1 or DECK_INTEGRATION=1.
/// Uses project deck-compose-merge and removes everything at the end.
final class ComposeMergeLiveTests: XCTestCase {

    private var enabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["DECK_INTEGRATION"] == "1" || env["DECK_LIVE_COMPOSE"] == "1"
    }

    private func pluginBinary() -> String? {
        var dir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<3 {
            let candidate = dir.appendingPathComponent(ComposePlugin.executableName).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func run(_ binary: String, _ args: [String], in dir: URL) throws -> (code: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.currentDirectoryURL = dir
        var environment = ProcessInfo.processInfo.environment
        environment["COMPOSE_FILE"] = nil
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    func testBaseAndOverrideStackFromATempFolder() throws {
        try XCTSkipUnless(enabled, "Set DECK_LIVE_COMPOSE=1 or DECK_INTEGRATION=1 to run against the real CLI.")
        guard let binary = pluginBinary() else {
            throw XCTSkip("Build the plugin first: swift build --product container-compose")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deck-compose-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("deploy"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "from the override\n".write(to: root.appendingPathComponent("data/hello.txt"), atomically: true, encoding: .utf8)
        try """
        name: deck-compose-merge
        services:
          app:
            image: alpine:3.22
            command: ["sleep", "5"]
            stop_grace_period: 2s
            environment:
              A: base
              B: base
        """.write(to: root.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try """
        services:
          app:
            command: ["sleep", "300"]
            environment: [B=override]
            labels:
              deck.merge: "yes"
            volumes: ["./data:/data:ro"]
        """.write(to: root.appendingPathComponent("compose.override.yaml"), atomically: true, encoding: .utf8)
        try """
        services:
          app:
            environment:
              C: prod
        """.write(to: root.appendingPathComponent("deploy/prod.yaml"), atomically: true, encoding: .utf8)

        addTeardownBlock { [self] in
            _ = try? self.run(binary, ["down", "-v"], in: root)
        }

        let config = try run(binary, ["config"], in: root)
        XCTAssertEqual(config.code, 0, config.err)
        XCTAssertTrue(config.out.contains("B: override") && config.out.contains("A: base"), config.out)
        XCTAssertTrue(config.out.contains("\"300\""), config.out)

        let up = try run(binary, ["up", "-d"], in: root)
        XCTAssertEqual(up.code, 0, "\(up.out)\n\(up.err)")

        let env = try run(binary, ["exec", "-T", "app", "sh", "-c", "echo $A $B; cat /data/hello.txt"], in: root)
        XCTAssertEqual(env.code, 0, env.err)
        XCTAssertEqual(env.out.trimmingCharacters(in: .whitespacesAndNewlines), "base override\nfrom the override")

        // The stack remembers both files.
        let inspect = try run("/usr/local/bin/container", ["inspect", "deck-compose-merge-app"], in: root)
        XCTAssertTrue(inspect.out.contains("compose.override.yaml"), inspect.out)
        XCTAssertTrue(inspect.out.contains("deck.merge"), inspect.out)

        // A third file with -f: only the files given, the service changes and is recreated.
        let prod = try run(binary, ["-f", "compose.yaml", "-f", "compose.override.yaml", "-f", "deploy/prod.yaml", "up", "-d"], in: root)
        XCTAssertEqual(prod.code, 0, "\(prod.out)\n\(prod.err)")
        let three = try run(binary, ["exec", "-T", "app", "sh", "-c", "echo $A $B $C"], in: root)
        XCTAssertEqual(three.out.trimmingCharacters(in: .whitespacesAndNewlines), "base override prod", three.err)

        let down = try run(binary, ["down", "-v"], in: root)
        XCTAssertEqual(down.code, 0, down.err)
        let left = try run(binary, ["ps", "-q"], in: root)
        XCTAssertEqual(left.out.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
}
