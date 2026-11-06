import XCTest
@testable import DeckCore

/// Shapes recorded from the real `container` CLI 1.6.1 on macOS 27.2.
final class RealCLIComposeMachineTests: XCTestCase {

    // MARK: - Machines

    /// `container machine list --format json` with a running machine.
    private let runningList = """
    [{"diskSize":43302912,"createdDate":"2026-11-05T12:24:59Z","default":true,"memory":1073741824,"ipAddress":"192.168.64.3","id":"deck-test-m","cpus":2,"status":"running"}]
    """

    /// The same machine after `container machine stop`. No ipAddress key.
    private let stoppedList = """
    [{"memory":1073741824,"createdDate":"2026-11-05T12:24:59Z","default":true,"cpus":2,"status":"stopped","id":"deck-test-m","diskSize":43745280}]
    """

    /// `container machine inspect deck-test-m` while running (pretty printed, escaped slashes).
    private let runningInspect = """
    [
      {
        "containerId" : "deck-test-m-5fe835",
        "cpus" : 2,
        "createdDate" : "2026-11-05T12:24:59Z",
        "diskSize" : 43302912,
        "homeMount" : "ro",
        "id" : "deck-test-m",
        "image" : {
          "descriptor" : {
            "digest" : "sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f",
            "mediaType" : "application\\/vnd.oci.image.index.v1+json",
            "size" : 9218
          },
          "reference" : "docker.io\\/library\\/alpine:3.22"
        },
        "ipAddress" : "192.168.64.3",
        "memory" : 1073741824,
        "platform" : {
          "architecture" : "arm64",
          "os" : "linux"
        },
        "startedDate" : "2026-11-05T12:25:00Z",
        "status" : "running",
        "userSetup" : {
          "gid" : 20,
          "home" : "\\/home\\/suresh",
          "uid" : 501,
          "username" : "suresh"
        }
      }
    ]
    """

    func testRealMachineListRunningAndStopped() throws {
        let running = try MachineParser.parseList(runningList)
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running[0].name, "deck-test-m")
        XCTAssertEqual(running[0].state, .running)
        XCTAssertEqual(running[0].ipAddress, "192.168.64.3")
        XCTAssertEqual(running[0].cpus, 2)
        XCTAssertEqual(running[0].memoryBytes, 1_073_741_824)
        XCTAssertTrue(running[0].isDefault)

        let stopped = try MachineParser.parseList(stoppedList)
        XCTAssertEqual(stopped[0].state, .stopped)
        XCTAssertNil(stopped[0].ipAddress)

        XCTAssertEqual(try MachineParser.parseList("[]"), [])
    }

    func testRealMachineInspect() throws {
        let detail = try MachineParser.parseInspect(runningInspect)
        XCTAssertEqual(detail.summary.name, "deck-test-m")
        XCTAssertEqual(detail.summary.image, "docker.io/library/alpine:3.22")
        XCTAssertEqual(detail.summary.homeMount, "ro")
        XCTAssertEqual(detail.summary.state, .running)
        // The backing container changes on every boot. `container stats` accepts it.
        XCTAssertEqual(detail.containerID, "deck-test-m-5fe835")
        XCTAssertEqual(detail.platform, "linux/arm64")
        XCTAssertEqual(detail.username, "suresh")
        XCTAssertEqual(detail.guestHome, "/home/suresh")
        XCTAssertEqual(detail.diskSizeBytes, 43_302_912)
        XCTAssertNotNil(detail.startedAt)
        XCTAssertNotNil(detail.createdAt)
    }

    func testMachineArgumentsMatchRealCLI() {
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner())
        let options = MachineOptions(name: "deck-test-m", image: "alpine:3.22", cpus: 2, memory: "1G", homeMount: "ro")
        XCTAssertEqual(
            client.createMachineArguments(options),
            ["machine", "create", "--name", "deck-test-m", "--cpus", "2", "--memory", "1G", "--home-mount", "ro", "alpine:3.22"]
        )
        // No `machine boot` in 1.6.1. `machine run` boots first.
        XCTAssertEqual(client.bootMachineArguments("deck-test-m"), ["machine", "run", "--name", "deck-test-m", "--", "true"])
        XCTAssertEqual(
            client.setMachineArguments("deck-test-m", cpus: 1, memory: "1G", homeMount: "none"),
            ["machine", "set", "--name", "deck-test-m", "cpus=1", "memory=1G", "home-mount=none"]
        )
        XCTAssertEqual(
            client.machineLogArguments("deck-test-m", follow: true, boot: true),
            ["machine", "logs", "--boot", "--follow", "-n", "1000", "deck-test-m"]
        )
    }

    func testMachineUnsupportedDetection() {
        // What a CLI without the machine command prints (recorded with a bad subcommand on 1.6.1).
        let old = """
        Error: unknown command 'machine'

        - If system services are not running, start them with: container system start
        """
        XCTAssertTrue(MachineParser.isUnsupportedText(old))
        XCTAssertTrue(MachineParser.isUnsupported(MachineParser.explain(DeckError.commandFailed(old))))
        let missing = #"Error: failed to get logs for container machine nosuch (cause: "internalError: "failed to open container machine logs: notFound: "container machine with ID nosuch not found""")"#
        XCTAssertFalse(MachineParser.isUnsupportedText(missing))
    }

    // MARK: - Compose

    /// `container inspect` of a stopped container that ran `exit 3`. There is no exit code anywhere.
    private let stoppedInspect = """
    [
      {
        "configuration" : {
          "id" : "deck-probe-exit",
          "labels" : {}
        },
        "id" : "deck-probe-exit",
        "status" : {
          "networks" : [],
          "startedDate" : "2026-11-05T12:26:02Z",
          "state" : "stopped"
        }
      }
    ]
    """

    func testInspectHasNoExitCode() {
        XCTAssertNil(ComposeRunner.exitCode(fromInspectJSON: stoppedInspect))
        // Pretty printed JSON puts a space before the colon.
        XCTAssertEqual(ComposeRunner.exitCode(fromInspectJSON: #"{"exitCode" : 3}"#), 3)
        XCTAssertEqual(ComposeRunner.exitCode(fromInspectJSON: #"{"exitCode":-1}"#), -1)
    }

    /// One `container list --all --format json` item made by ComposeRunner (trimmed).
    private let composeContainerJSON = """
    [{"configuration":{"id":"deck-test-compose-web","image":{"reference":"docker.io/library/nginx:alpine"},"labels":{"com.containerdeck.compose.project":"deck-test-compose","com.containerdeck.compose.service":"web","com.containerdeck.compose.config-hash":"abc","com.containerdeck.compose.file":"/tmp/deck-compose-it/compose.yaml"},"networks":[{"network":"deck-test-compose_backend","options":{"hostname":"deck-test-compose-web","mtu":1280}}],"platform":{"architecture":"arm64","os":"linux","variant":"v8"},"publishedPorts":[{"containerPort":80,"count":1,"hostAddress":"0.0.0.0","hostPort":18089,"proto":"tcp"}],"resources":{"cpus":4,"memoryInBytes":1073741824}},"id":"deck-test-compose-web","status":{"networks":[{"hostname":"deck-test-compose-web","ipv4Address":"192.168.65.2/24","ipv4Gateway":"192.168.65.1","network":"deck-test-compose_backend"}],"startedDate":"2026-11-05T12:27:36Z","state":"running"}}]
    """

    func testComposeStackFromRealListShape() throws {
        let containers = try ContainerOutputParser.containers(composeContainerJSON)
        XCTAssertEqual(containers.first?.id, "deck-test-compose-web")
        let stacks = ComposeStack.group(containers)
        XCTAssertEqual(stacks.map(\.name), ["deck-test-compose"])
        XCTAssertEqual(stacks[0].services.first?.service, "web")
        XCTAssertEqual(stacks[0].file?.path, "/tmp/deck-compose-it/compose.yaml")
        XCTAssertEqual(stacks[0].runningCount, 1)
    }

    func testCompletionTargetsRunAttached() throws {
        let yaml = """
        name: deck-test-compose
        services:
          init:
            image: alpine:3.22
            command: ["sh", "-c", "echo init done"]
          web:
            image: nginx:alpine
            depends_on:
              init:
                condition: service_completed_successfully
          worker:
            image: alpine:3.22
            depends_on: [web]
        """
        let project = try ComposeParser.parse(yaml, file: URL(fileURLWithPath: "/tmp/compose.yaml"))
        let plan = try ComposePlanner.plan(project)
        XCTAssertEqual(ComposeRunner.completionTargets(plan), ["init"])

        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner())
        var options = try XCTUnwrap(plan.service("init")).options
        XCTAssertTrue(client.runArguments(options).contains("--detach"))
        options.detach = false
        XCTAssertFalse(client.runArguments(options).contains("--detach"))
    }
}
