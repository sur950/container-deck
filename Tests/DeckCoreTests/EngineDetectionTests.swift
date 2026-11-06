import XCTest
@testable import DeckCore

private let home = "/Users/test"
private let orbSocket = home + "/.orbstack/run/docker.sock"
private let colimaSocket = home + "/.colima/default/docker.sock"

private func engineEnvironment(
    files: Set<String>,
    executables: Set<String> = [],
    dirs: [String: [String]] = [:],
    contents: [String: String] = [:],
    links: [String: String] = [:],
    dockerHost: String? = nil
) -> EngineEnvironment {
    EngineEnvironment(
        home: home,
        dockerHost: dockerHost,
        files: FileSystem(
            fileExists: { files.contains($0) || executables.contains($0) },
            isExecutable: { executables.contains($0) },
            contentsOfDirectory: { dirs[$0] ?? [] }
        ),
        readFile: { contents[$0].map { Data($0.utf8) } },
        resolvePath: { links[$0] ?? $0 }
    )
}

private func curlKey(_ socket: String, _ path: String, _ timeout: Int) -> String {
    DockerAPI.arguments(socket: socket, path: path, timeout: timeout).joined(separator: " ")
}

final class EngineDetectionTests: XCTestCase {

    func testCandidatesAndDedupe() {
        let contextMeta = #"{"Name":"colima","Metadata":{},"Endpoints":{"docker":{"Host":"unix:///Users/test/.colima/default/docker.sock","SkipTLSVerify":false}}}"#
        let env = engineEnvironment(
            files: [orbSocket, colimaSocket, "/var/run/docker.sock", home + "/.lima/dev/sock/docker.sock"],
            dirs: [
                home + "/.colima": ["default", "_lima"],
                home + "/.lima": ["dev", "_config"],
                home + "/.docker/contexts/meta": ["abc123"]
            ],
            contents: [home + "/.docker/contexts/meta/abc123/meta.json": contextMeta],
            links: ["/var/run/docker.sock": orbSocket]
        )
        let detector = EngineDetector(environment: env, runner: MockRunner())
        let candidates = detector.socketCandidates()

        XCTAssertEqual(candidates.first?.kind, .orbStack)
        XCTAssertTrue(candidates.contains { $0.kind == .lima && $0.name == "Lima (dev)" })
        // /var/run/docker.sock points at OrbStack, so it is named after it.
        XCTAssertEqual(candidates.last?.socketPath, "/var/run/docker.sock")
        XCTAssertEqual(candidates.last?.kind, .orbStack)

        let unique = detector.dedupe(candidates)
        XCTAssertEqual(unique.map(\.socketPath), [orbSocket, colimaSocket, home + "/.lima/dev/sock/docker.sock"])
        XCTAssertEqual(unique.map(\.kind), [.orbStack, .colima, .lima])
    }

    func testDockerHostAndContexts() {
        XCTAssertEqual(EngineDetector.unixPath(fromHost: "unix:///tmp/d.sock"), "/tmp/d.sock")
        XCTAssertNil(EngineDetector.unixPath(fromHost: "tcp://1.2.3.4:2375"))
        XCTAssertNil(EngineDetector.unixPath(fromHost: "ssh://core@localhost"))

        let meta = EngineDetector.parseContextMeta(Data(#"{"Name":"desktop-linux","Endpoints":{"docker":{"Host":"unix:///Users/test/.docker/run/docker.sock"}}}"#.utf8))
        XCTAssertEqual(meta?.name, "desktop-linux")
        XCTAssertEqual(meta?.host, "unix:///Users/test/.docker/run/docker.sock")
        XCTAssertNil(EngineDetector.parseContextMeta(Data("{}".utf8)))

        let env = engineEnvironment(files: ["/tmp/custom.sock"], dockerHost: "unix:///tmp/custom.sock")
        let candidates = EngineDetector(environment: env, runner: MockRunner()).socketCandidates()
        XCTAssertEqual(candidates.map(\.socketPath), ["/tmp/custom.sock"])
        XCTAssertEqual(candidates.first?.kind, .other)
    }

    func testKindFromPath() {
        XCTAssertEqual(EngineDetector.kind(forSocketPath: "/Users/a/.orbstack/run/docker.sock"), .orbStack)
        XCTAssertEqual(EngineDetector.kind(forSocketPath: "/Users/a/.rd/docker.sock"), .rancherDesktop)
        XCTAssertEqual(EngineDetector.kind(forSocketPath: "/Users/a/.colima/default/docker.sock"), .colima)
        XCTAssertEqual(EngineDetector.kind(forSocketPath: "/var/folders/x/T/podman/podman-machine-default-api.sock"), .podman)
        XCTAssertEqual(EngineDetector.kind(forSocketPath: "/Users/a/.docker/run/docker.sock"), .dockerDesktop)
        XCTAssertEqual(EngineDetector.kind(forSocketPath: "/tmp/other.sock"), .other)
    }

    func testNamingFromInfo() {
        let generic = EngineCandidate(kind: .dockerDesktop, name: "Docker Desktop", socketPath: "/var/run/docker.sock", source: "")
        let orb = EngineDetector.name(for: generic, realPath: "/var/run/docker.sock", version: nil, info: DockerInfo(name: "orbstack", operatingSystem: "OrbStack"))
        XCTAssertEqual(orb.kind, .orbStack)
        let podman = EngineDetector.name(
            for: generic, realPath: "/var/run/docker.sock",
            version: DockerVersion(version: "5.2.0", components: ["Podman Engine"]), info: nil
        )
        XCTAssertEqual(podman.kind, .podman)
        let desktop = EngineDetector.name(for: generic, realPath: "/var/run/docker.sock", version: nil, info: DockerInfo(name: "docker-desktop", operatingSystem: "Docker Desktop"))
        XCTAssertEqual(desktop.kind, .dockerDesktop)
    }

    func testDetectStates() async {
        let env = engineEnvironment(
            files: [orbSocket, colimaSocket, "/var/run/docker.sock", "/Applications/Docker.app"],
            dirs: [home + "/.colima": ["default"]],
            links: ["/var/run/docker.sock": orbSocket]
        )
        let runner = MockRunner()
        runner.responses[curlKey(orbSocket, "/_ping", 3)] = CommandResult(exitCode: 0, stdout: "OK")
        runner.responses[curlKey(orbSocket, "/version", 5)] = CommandResult(exitCode: 0, stdout: #"{"Version":"27.3.1","ApiVersion":"1.47"}"#)
        runner.responses[curlKey(orbSocket, "/info", 8)] = CommandResult(exitCode: 0, stdout: #"{"ID":"abc","Name":"orbstack","OperatingSystem":"OrbStack","Images":12}"#)

        let engines = await EngineDetector(environment: env, runner: runner).detect()

        let orb = engines.first { $0.kind == .orbStack }
        XCTAssertEqual(orb?.state, .running)
        XCTAssertEqual(orb?.version, "27.3.1")
        XCTAssertEqual(orb?.imageCount, 12)
        XCTAssertEqual(engines.first?.kind, .orbStack, "Running engines come first")

        XCTAssertEqual(engines.first { $0.kind == .colima }?.state, .stopped)
        // Docker.app is installed but has no socket.
        XCTAssertEqual(engines.first { $0.kind == .dockerDesktop }?.state, .stopped)
        XCTAssertEqual(engines.first { $0.kind == .podman }?.state, .notFound)
        XCTAssertEqual(engines.first { $0.kind == .rancherDesktop }?.state, .notFound)
        XCTAssertEqual(engines.filter { $0.kind == .orbStack }.count, 1)
    }

    func testPodmanParsing() {
        let inspect = """
        [{"ConfigDir":{"Path":"/x"},"ConnectionInfo":{"PodmanSocket":{"Path":"/var/folders/T/podman/podman-machine-default-api.sock"},"PodmanPipe":null},"Name":"podman-machine-default","State":"running"}]
        """
        let machines = EngineDetector.parsePodmanMachineInspect(inspect)
        XCTAssertEqual(machines.count, 1)
        XCTAssertEqual(machines.first?.name, "podman-machine-default")
        XCTAssertEqual(machines.first?.socketPath, "/var/folders/T/podman/podman-machine-default-api.sock")
        XCTAssertEqual(machines.first?.state, "running")

        let names = EngineDetector.parsePodmanMachineNames(#"[{"Name":"podman-machine-default*","Running":true}]"#)
        XCTAssertEqual(names, ["podman-machine-default"])

        let connections = EngineDetector.parsePodmanConnections(#"[{"Name":"local","URI":"unix:///run/podman.sock","Default":false},{"Name":"vm","URI":"ssh://core@127.0.0.1:5000/run/podman.sock"}]"#)
        XCTAssertEqual(connections.count, 2)
        XCTAssertEqual(EngineDetector.unixPath(fromHost: connections[0].uri), "/run/podman.sock")
        XCTAssertNil(EngineDetector.unixPath(fromHost: connections[1].uri))
    }

    func testPodmanDetectedThroughMachineInspect() async {
        let socket = "/var/folders/T/podman/podman-machine-default-api.sock"
        let env = engineEnvironment(files: [socket], executables: ["/opt/homebrew/bin/podman"])
        let runner = MockRunner()
        runner.responses["machine list --format json"] = CommandResult(exitCode: 0, stdout: #"[{"Name":"podman-machine-default"}]"#)
        runner.responses["machine inspect podman-machine-default"] = CommandResult(exitCode: 0, stdout: """
        [{"ConnectionInfo":{"PodmanSocket":{"Path":"\(socket)"}},"Name":"podman-machine-default","State":"running"}]
        """)
        runner.responses[curlKey(socket, "/_ping", 3)] = CommandResult(exitCode: 0, stdout: "OK")
        runner.responses[curlKey(socket, "/version", 5)] = CommandResult(exitCode: 0, stdout: #"{"Version":"5.2.0","Components":[{"Name":"Podman Engine"}]}"#)

        let engines = await EngineDetector(environment: env, runner: runner).detect()
        let podman = engines.first { $0.kind == .podman }
        XCTAssertEqual(podman?.state, .running)
        XCTAssertEqual(podman?.podmanBinary, "/opt/homebrew/bin/podman")
        XCTAssertEqual(podman?.podmanConnection, "podman-machine-default")
        XCTAssertEqual(podman?.endpoint, .dockerSocket(socket))
    }

    func testImageReferenceNormalize() {
        XCTAssertEqual(ImageReference.normalize("nginx"), "docker.io/library/nginx:latest")
        XCTAssertEqual(ImageReference.normalize("nginx:1.27"), "docker.io/library/nginx:1.27")
        XCTAssertEqual(ImageReference.normalize("me/app:1"), "docker.io/me/app:1")
        XCTAssertEqual(ImageReference.normalize("docker.io/nginx"), "docker.io/library/nginx:latest")
        XCTAssertEqual(ImageReference.normalize("ghcr.io/a/b:tag"), "ghcr.io/a/b:tag")
        XCTAssertEqual(ImageReference.normalize("localhost:5000/app"), "localhost:5000/app:latest")
        XCTAssertEqual(ImageReference.normalize("localhost/app:dev"), "localhost/app:dev")
        XCTAssertEqual(ImageReference.domain(of: "nginx"), "docker.io")
        XCTAssertTrue(ImageReference.isUntagged("<none>:<none>"))
    }
}
