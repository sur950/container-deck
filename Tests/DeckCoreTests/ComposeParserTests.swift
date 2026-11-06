import XCTest
@testable import DeckCore

private let composeFile = URL(fileURLWithPath: "/work/shop/compose.yaml")

private func parse(_ yaml: String, env: [String: String] = [:], files: [String: String] = [:]) throws -> ComposeProject {
    try ComposeParser.parse(yaml, file: composeFile, environment: env, readFile: { files[$0.path] })
}

final class ComposeParserTests: XCTestCase {

    // MARK: Short syntax

    func testShortSyntax() throws {
        let yaml = """
        name: Shop
        services:
          web:
            image: nginx:1.27
            command: npm run "start dev"
            entrypoint: /docker-entrypoint.sh
            environment:
              - MODE=prod
              - EMPTY=
            ports:
              - "8080:80"
              - "127.0.0.1:9000:9000/udp"
              - "3000-3001:3000-3001"
            volumes:
              - ./site:/usr/share/nginx/html:ro
              - data:/data
            networks:
              - front
            depends_on:
              - db
            labels:
              - team=web
            working_dir: /app
            cpus: 1.5
            mem_limit: 512m
            platform: linux/amd64
            container_name: shop-web
            restart: "no"
          db:
            image: postgres:16
        volumes:
          data:
        networks:
          front:
        """
        let project = try parse(yaml)
        XCTAssertEqual(project.name, "shop")
        XCTAssertEqual(project.services.map(\.name), ["web", "db"])
        XCTAssertTrue(project.problems.isEmpty, "\(project.problems)")

        let web = try XCTUnwrap(project.service("web"))
        XCTAssertEqual(web.image, "nginx:1.27")
        XCTAssertEqual(web.command, ["npm", "run", "start dev"])
        XCTAssertEqual(web.entrypoint, ["/docker-entrypoint.sh"])
        XCTAssertEqual(web.environment, [EnvVar(key: "MODE", value: "prod"), EnvVar(key: "EMPTY", value: "")])
        XCTAssertEqual(web.ports, [
            ComposePort(published: 8080, target: 80),
            ComposePort(hostIP: "127.0.0.1", published: 9000, target: 9000, proto: "udp"),
            ComposePort(published: 3000, target: 3000),
            ComposePort(published: 3001, target: 3001)
        ])
        XCTAssertEqual(web.volumes, [
            ComposeVolumeMount(kind: .bind, source: "/work/shop/site", target: "/usr/share/nginx/html", readOnly: true),
            ComposeVolumeMount(kind: .volume, source: "data", target: "/data")
        ])
        XCTAssertEqual(web.networks, ["front"])
        XCTAssertEqual(web.dependsOn, [ComposeDependency(service: "db", condition: .started)])
        XCTAssertEqual(web.labels, ["team": "web"])
        XCTAssertEqual(web.workingDir, "/app")
        XCTAssertEqual(web.cpus, 1.5)
        XCTAssertEqual(web.memory, "512M")
        XCTAssertEqual(web.platform, "linux/amd64")
        XCTAssertEqual(web.containerName, "shop-web")
        XCTAssertEqual(project.volumes.map(\.key), ["data"])
        XCTAssertEqual(project.networks.map(\.key), ["front"])
    }

    // MARK: Long syntax

    func testLongSyntax() throws {
        let yaml = """
        services:
          api:
            build:
              context: ./api
              dockerfile: Dockerfile.dev
              args:
                VERSION: "1.2"
                TOKEN:
              target: dev
            entrypoint: ["/bin/sh", "-c"]
            command: ["echo hi"]
            environment:
              DEBUG: "true"
              PORT: 8080
              FROM_HOST:
            env_file:
              - .env.api
              - path: ./missing.env
                required: false
            ports:
              - target: 80
                published: "8081"
                host_ip: 127.0.0.1
                protocol: tcp
            volumes:
              - type: bind
                source: ./src
                target: /src
                read_only: true
              - type: volume
                source: cache
                target: /cache
            networks:
              back:
                aliases: [api-internal]
            depends_on:
              db:
                condition: service_healthy
              migrate:
                condition: service_completed_successfully
            deploy:
              resources:
                limits:
                  cpus: "0.5"
                  memory: 1g
          db:
            image: postgres
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U postgres"]
              interval: 5s
              timeout: 3s
              retries: 5
              start_period: 1m30s
          migrate:
            image: migrate
            profiles: [tools]
        volumes:
          cache:
            name: shared-cache
        networks:
          back:
            internal: true
        """
        let project = try parse(
            yaml,
            env: ["FROM_HOST": "yes", "TOKEN": "abc"],
            files: ["/work/shop/.env.api": "SHARED=1\nDEBUG=false\n"]
        )
        XCTAssertEqual(project.name, "shop")
        XCTAssertTrue(project.problems.isEmpty, "\(project.problems)")

        let api = try XCTUnwrap(project.service("api"))
        XCTAssertNil(api.image)
        XCTAssertEqual(api.build, ComposeBuild(
            context: "/work/shop/api",
            dockerfile: "/work/shop/api/Dockerfile.dev",
            args: [EnvVar(key: "VERSION", value: "1.2"), EnvVar(key: "TOKEN", value: "abc")],
            target: "dev"
        ))
        XCTAssertEqual(api.entrypoint, ["/bin/sh", "-c"])
        XCTAssertEqual(api.command, ["echo hi"])

        var env: [String: String] = [:]
        for item in api.environment { env[item.key] = item.value }
        XCTAssertEqual(env, ["SHARED": "1", "DEBUG": "true", "PORT": "8080", "FROM_HOST": "yes"])

        XCTAssertEqual(api.ports, [ComposePort(hostIP: "127.0.0.1", published: 8081, target: 80)])
        XCTAssertEqual(api.volumes, [
            ComposeVolumeMount(kind: .bind, source: "/work/shop/src", target: "/src", readOnly: true),
            ComposeVolumeMount(kind: .volume, source: "cache", target: "/cache")
        ])
        XCTAssertEqual(api.networks, ["back"])
        XCTAssertEqual(api.networkAliases, ["api-internal"])
        XCTAssertEqual(api.dependsOn, [
            ComposeDependency(service: "db", condition: .healthy),
            ComposeDependency(service: "migrate", condition: .completed)
        ])
        XCTAssertEqual(api.cpus, 0.5)
        XCTAssertEqual(api.memory, "1G")

        let check = try XCTUnwrap(project.service("db")?.healthcheck)
        XCTAssertEqual(check.command, ["/bin/sh", "-c", "pg_isready -U postgres"])
        XCTAssertEqual(check.interval, 5)
        XCTAssertEqual(check.timeout, 3)
        XCTAssertEqual(check.retries, 5)
        XCTAssertEqual(check.startPeriod, 90)

        XCTAssertEqual(project.service("migrate")?.profiles, ["tools"])
        XCTAssertEqual(project.volumes.first?.name, "shared-cache")
        XCTAssertEqual(project.networks.first?.isInternal, true)
    }

    func testHealthcheckWithoutTestIsReported() throws {
        let project = try parse("""
        services:
          api:
            image: nginx
            healthcheck:
              interval: 5s
          off:
            image: nginx
            healthcheck:
              disable: true
        """)
        let problems = project.problems.filter { $0.key == "services.api.healthcheck" }
        XCTAssertEqual(problems.map(\.kind), [.notBuilt])
        XCTAssertEqual(problems.first?.line, 4)
        XCTAssertFalse(project.problems.contains { $0.service == "off" })
    }

    func testMergeKeysAndExtensions() throws {
        let yaml = """
        x-common: &common
          image: busybox
          environment:
            LEVEL: base
        services:
          one:
            <<: *common
          two:
            <<: *common
            image: alpine
        """
        let project = try parse(yaml)
        XCTAssertTrue(project.problems.isEmpty, "\(project.problems)")
        XCTAssertEqual(project.service("one")?.image, "busybox")
        XCTAssertEqual(project.service("one")?.environment, [EnvVar(key: "LEVEL", value: "base")])
        XCTAssertEqual(project.service("two")?.image, "alpine")
    }

    func testPortSpecs() {
        XCTAssertEqual(ComposeFileReader.parsePortSpec("80").ports, [ComposePort(target: 80)])
        XCTAssertEqual(ComposeFileReader.parsePortSpec("[::1]:8080:80").ports, [ComposePort(hostIP: "::1", published: 8080, target: 80)])
        XCTAssertEqual(ComposeFileReader.parsePortSpec("127.0.0.1::53/udp").ports, [ComposePort(hostIP: "127.0.0.1", target: 53, proto: "udp")])
        XCTAssertNotNil(ComposeFileReader.parsePortSpec("8000-8002:80").error)
        XCTAssertNotNil(ComposeFileReader.parsePortSpec("a:b").error)
        XCTAssertNotNil(ComposeFileReader.parsePortSpec("80/sctp").error)
    }

    func testUnits() {
        XCTAssertEqual(ComposeUnits.memory("512m"), "512M")
        XCTAssertEqual(ComposeUnits.memory("1g"), "1G")
        XCTAssertEqual(ComposeUnits.memory("2gb"), "2G")
        XCTAssertEqual(ComposeUnits.memory("1.5g"), "1536M")
        XCTAssertEqual(ComposeUnits.memory("1073741824"), "1G")
        XCTAssertNil(ComposeUnits.memory("lots"))
        XCTAssertEqual(ComposeUnits.duration("1m30s"), 90)
        XCTAssertEqual(ComposeUnits.duration("500ms") ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(ComposeUnits.duration("10"), 10)
        XCTAssertNil(ComposeUnits.duration("soon"))
    }

    func testShellWords() {
        XCTAssertEqual(ShellWords.split(#"sh -c "echo 'hi there'" x\ y"#), ["sh", "-c", "echo 'hi there'", "x y"])
        XCTAssertEqual(ShellWords.split("  "), [])
        XCTAssertEqual(ShellWords.split("a ''"), ["a", ""])
    }

    // MARK: Interpolation

    func testInterpolation() {
        let interpolator = ComposeInterpolator(values: ["NAME": "deck", "EMPTY": ""])
        func text(_ input: String) -> String { interpolator.interpolate(input).text }

        XCTAssertEqual(text("${NAME}"), "deck")
        XCTAssertEqual(text("$NAME-x"), "deck-x")
        XCTAssertEqual(text("${MISSING:-def}"), "def")
        XCTAssertEqual(text("${EMPTY:-def}"), "def")
        XCTAssertEqual(text("${EMPTY-def}"), "")
        XCTAssertEqual(text("${MISSING-def}"), "def")
        XCTAssertEqual(text("${MISSING:-${NAME}}"), "deck")
        XCTAssertEqual(text("${NAME:+set}"), "set")
        XCTAssertEqual(text("${MISSING:+set}"), "")
        XCTAssertEqual(text("$$NAME"), "$NAME")
        XCTAssertEqual(text("cost $$5 and $5"), "cost $5 and $5")
        XCTAssertEqual(text("${MISSING}"), "")
        XCTAssertEqual(interpolator.interpolate("${MISSING:?need it}").errors, ["need it"])
        XCTAssertEqual(interpolator.interpolate("${NAME:?need it}").errors, [])
    }

    func testInterpolationInFile() throws {
        let yaml = """
        services:
          web:
            image: "nginx:${TAG:-latest}"
            ports:
              - "${PORT}:80"
            environment:
              PRICE: "$$5"
        """
        let project = try parse(yaml, env: ["PORT": "8088"])
        let web = try XCTUnwrap(project.service("web"))
        XCTAssertEqual(web.image, "nginx:latest")
        XCTAssertEqual(web.ports, [ComposePort(published: 8088, target: 80)])
        XCTAssertEqual(web.environment, [EnvVar(key: "PRICE", value: "$5")])
    }

    func testDotEnv() {
        let text = """
        A=1
        # comment
        export B='two words'
        C="x ${A}"
        D=plain # note
        """
        XCTAssertEqual(DotEnvParser.dictionary(text), ["A": "1", "B": "two words", "C": "x 1", "D": "plain"])
    }

    func testLoadReadsSiblingDotEnvThenProcess() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-compose-\(UUID().uuidString)")
            .appendingPathComponent("My App")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let file = dir.appendingPathComponent("compose.yaml")
        try """
        services:
          web:
            image: "nginx:${TAG}"
            environment:
              MODE: ${MODE}
        """.write(to: file, atomically: true, encoding: .utf8)
        try "TAG=1.25\nMODE=dev\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let project = try ComposeParser.load(file: file, processEnvironment: ["MODE": "prod"])
        XCTAssertEqual(project.name, "myapp")
        XCTAssertEqual(project.service("web")?.image, "nginx:1.25")
        XCTAssertEqual(project.service("web")?.environment, [EnvVar(key: "MODE", value: "prod")])
    }

    // MARK: Problems

    func testProblemsWithLineNumbers() throws {
        let yaml = """
        services:
          web:
            image: nginx
            privileged: true
            restart: always
            hostname: web1
            ports:
              - "80"
            volumes:
              - data
          worker:
            build: .
            depends_on:
              cache:
                condition: service_healthy
          cache:
            image: redis
        secrets:
          key:
            file: ./key
        """
        let project = try parse(yaml)
        func problem(_ key: String) -> ComposeProblem? { project.problems.first { $0.key == key } }

        XCTAssertEqual(problem("services.web.privileged")?.kind, .notPossible)
        XCTAssertEqual(problem("services.web.privileged")?.line, 4)
        XCTAssertEqual(problem("services.web.restart")?.kind, .notPossible)
        XCTAssertEqual(problem("services.web.restart")?.line, 5)
        XCTAssertEqual(problem("services.web.hostname")?.kind, .notBuilt)
        XCTAssertEqual(problem("services.web.hostname")?.line, 6)
        XCTAssertEqual(problem("services.web.ports")?.kind, .notBuilt)
        XCTAssertEqual(problem("services.web.ports")?.line, 8)
        XCTAssertEqual(problem("services.web.volumes")?.kind, .invalid)
        XCTAssertEqual(problem("services.web.volumes")?.line, 10)
        XCTAssertEqual(problem("services.worker.depends_on")?.kind, .invalid)
        XCTAssertEqual(problem("services.worker.depends_on")?.line, 11)
        XCTAssertEqual(problem("secrets")?.kind, .notBuilt)
        XCTAssertEqual(problem("secrets")?.line, 18)
        XCTAssertTrue(project.hasBlockingProblems)
        XCTAssertEqual(project.problems.map(\.line), project.problems.map(\.line).sorted())
    }

    func testInvalidReferences() throws {
        let yaml = """
        services:
          web:
            volumes:
              - missing:/data
            networks: [nowhere]
            depends_on: [ghost]
        """
        let project = try parse(yaml)
        let invalid = project.problems.filter { $0.kind == .invalid }
        XCTAssertTrue(invalid.contains { $0.message.contains("needs an image or a build") })
        XCTAssertTrue(invalid.contains { $0.message.contains("Volume missing") })
        XCTAssertTrue(invalid.contains { $0.message.contains("Network nowhere") })
        XCTAssertTrue(invalid.contains { $0.message.contains("ghost") })
    }

    func testInvalidYAMLThrows() {
        XCTAssertThrowsError(try parse("services: [unclosed"))
        XCTAssertThrowsError(try parse("just text"))
    }

    // MARK: Order

    func testOrderFollowsDependsOn() throws {
        let services = [
            ComposeService(name: "web", image: "a", dependsOn: [ComposeDependency(service: "api")]),
            ComposeService(name: "cache", image: "a"),
            ComposeService(name: "api", image: "a", dependsOn: [ComposeDependency(service: "db")]),
            ComposeService(name: "db", image: "a")
        ]
        XCTAssertEqual(try ComposeOrder.sorted(services).map(\.name), ["cache", "db", "api", "web"])
    }

    func testCycleIsDetected() {
        let services = [
            ComposeService(name: "a", image: "x", dependsOn: [ComposeDependency(service: "b")]),
            ComposeService(name: "b", image: "x", dependsOn: [ComposeDependency(service: "c")]),
            ComposeService(name: "c", image: "x", dependsOn: [ComposeDependency(service: "a")]),
            ComposeService(name: "d", image: "x")
        ]
        XCTAssertThrowsError(try ComposeOrder.sorted(services)) { error in
            XCTAssertEqual(error as? ComposeError, .cycle(["a", "b", "c"]))
        }
    }

    func testCycleBecomesProblem() throws {
        let yaml = """
        services:
          a:
            image: x
            depends_on: [b]
          b:
            image: x
            depends_on: [a]
        """
        let project = try parse(yaml)
        XCTAssertTrue(project.problems.contains { $0.kind == .invalid && $0.message.contains("loop") })
    }

    // MARK: File discovery

    func testLocatorWalksUpAndFindsOverride() {
        let files: Set<String> = ["/a/b/docker-compose.yml", "/a/b/docker-compose.override.yml", "/a/compose.yaml"]
        let locator = ComposeFileLocator(fileExists: { files.contains($0) })
        let found = locator.locate(from: URL(fileURLWithPath: "/a/b/c/d"), environment: [:])
        XCTAssertEqual(found.map(\.path), ["/a/b/docker-compose.yml", "/a/b/docker-compose.override.yml"])
    }

    func testLocatorPrefersComposeYamlAndComposeFileEnv() {
        let files: Set<String> = ["/p/compose.yaml", "/p/docker-compose.yml"]
        let locator = ComposeFileLocator(fileExists: { files.contains($0) })
        XCTAssertEqual(locator.locate(from: URL(fileURLWithPath: "/p"), environment: [:]).map(\.path), ["/p/compose.yaml"])
        XCTAssertEqual(
            locator.locate(from: URL(fileURLWithPath: "/p"), environment: ["COMPOSE_FILE": "other.yml:/abs/extra.yml"]).map(\.path),
            ["/p/other.yml", "/abs/extra.yml"]
        )
        XCTAssertEqual(locator.locate(from: URL(fileURLWithPath: "/elsewhere"), environment: [:]), [])
    }

    func testProjectNameNormalised() {
        XCTAssertEqual(ComposeParser.normalizeProjectName("My App!"), "myapp")
        XCTAssertEqual(ComposeParser.normalizeProjectName("__x-1"), "x-1")
        XCTAssertEqual(ComposeParser.normalizeProjectName("!!!"), "compose")
    }
}
