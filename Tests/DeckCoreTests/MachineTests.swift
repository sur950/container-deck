import XCTest
@testable import DeckCore

final class MachineTests: XCTestCase {

    private let listJSON = """
    [{"cpus":4,"createdDate":"2026-10-01T10:00:00Z","default":true,"diskSize":2147483648,"id":"dev","ipAddress":"192.168.64.5","memory":8589934592,"status":"running"},
     {"cpus":2,"default":false,"id":"Box","memory":4294967296,"status":"stopped"}]
    """

    private let inspectJSON = """
    [
      {
        "containerId" : "dev-1a2b3c",
        "cpus" : 4,
        "createdDate" : "2026-10-01T10:00:00Z",
        "diskSize" : 2147483648,
        "homeMount" : "ro",
        "id" : "dev",
        "image" : {
          "descriptor" : {"digest" : "sha256:abc", "mediaType" : "application/vnd.oci.image.index.v1+json", "size" : 100},
          "reference" : "docker.io/library/alpine:3.22"
        },
        "ipAddress" : "192.168.64.5/24",
        "memory" : 8589934592,
        "platform" : {"architecture" : "arm64", "os" : "linux", "variant" : "v8"},
        "startedDate" : "2026-10-02T08:30:00Z",
        "status" : "running",
        "userSetup" : {"gid" : 20, "home" : "/home/me", "uid" : 501, "username" : "me"}
      }
    ]
    """

    func testParseList() throws {
        let machines = try MachineParser.parseList(listJSON)
        XCTAssertEqual(machines.count, 2)
        XCTAssertEqual(machines[0].name, "dev")
        XCTAssertEqual(machines[0].state, .running)
        XCTAssertTrue(machines[0].isDefault)
        XCTAssertEqual(machines[0].cpus, 4)
        XCTAssertEqual(machines[0].memoryBytes, 8_589_934_592)
        XCTAssertEqual(machines[0].hostname, "dev.machine")
        XCTAssertEqual(machines[1].hostname, "box.machine")
        XCTAssertEqual(machines[1].state, .stopped)
        XCTAssertFalse(machines[1].isDefault)
        XCTAssertEqual(try MachineParser.parseList("  \n"), [])
        XCTAssertThrowsError(try MachineParser.parseList("not json"))
    }

    func testParseInspect() throws {
        let detail = try MachineParser.parseInspect(inspectJSON)
        XCTAssertEqual(detail.summary.name, "dev")
        XCTAssertEqual(detail.summary.image, "docker.io/library/alpine:3.22")
        XCTAssertEqual(detail.summary.homeMount, "ro")
        XCTAssertEqual(detail.summary.ipAddress, "192.168.64.5")
        XCTAssertEqual(detail.containerID, "dev-1a2b3c")
        XCTAssertEqual(detail.platform, "linux/arm64/v8")
        XCTAssertEqual(detail.username, "me")
        XCTAssertEqual(detail.diskSizeBytes, 2_147_483_648)
        XCTAssertNotNil(detail.createdAt)
        XCTAssertNotNil(detail.startedAt)
    }

    func testListMachinesMergesInspect() async throws {
        let runner = MockRunner()
        runner.responses["machine list --format json"] = CommandResult(exitCode: 0, stdout: listJSON)
        runner.responses["machine inspect dev"] = CommandResult(exitCode: 0, stdout: inspectJSON)
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: runner)

        let machines = try await client.listMachines()
        XCTAssertEqual(machines.map(\.name), ["Box", "dev"])
        let dev = try XCTUnwrap(machines.first { $0.name == "dev" })
        XCTAssertEqual(dev.image, "docker.io/library/alpine:3.22")
        XCTAssertEqual(dev.homeMount, "ro")
        XCTAssertTrue(dev.isDefault)
        // Inspect for Box is not mocked, so list values stay.
        let box = try XCTUnwrap(machines.first { $0.name == "Box" })
        XCTAssertEqual(box.cpus, 2)
        XCTAssertEqual(box.image, "")
    }

    func testArguments() {
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner())
        let options = MachineOptions(name: "dev", image: "alpine:3.22", cpus: 4, memory: "8G", homeMount: "ro", boot: false)
        XCTAssertEqual(
            client.createMachineArguments(options),
            ["machine", "create", "--name", "dev", "--cpus", "4", "--memory", "8G", "--home-mount", "ro", "--no-boot", "alpine:3.22"]
        )
        XCTAssertEqual(client.bootMachineArguments("dev"), ["machine", "run", "--name", "dev", "--", "true"])
        XCTAssertEqual(
            client.setMachineArguments("dev", cpus: 2, memory: "4G", homeMount: "none"),
            ["machine", "set", "--name", "dev", "cpus=2", "memory=4G", "home-mount=none"]
        )
        XCTAssertEqual(
            client.machineLogArguments("dev", follow: true, boot: true),
            ["machine", "logs", "--boot", "--follow", "-n", "1000", "dev"]
        )
        XCTAssertEqual(client.machineShellCommand("dev"), "/usr/local/bin/container machine run --name dev")
    }

    func testSetMachineConfigRunsCommand() async throws {
        let runner = MockRunner()
        runner.responses["machine set --name dev cpus=6"] = CommandResult(exitCode: 0, stdout: "dev")
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: runner)
        try await client.setMachineConfig("dev", cpus: 6, memory: nil, homeMount: nil)
        XCTAssertEqual(runner.calls.last, ["/usr/local/bin/container", "machine", "set", "--name", "dev", "cpus=6"])
    }

    func testFriendlyErrors() {
        XCTAssertNotNil(MachineParser.friendlyMessage(for: "exec /sbin/init: no such file or directory"))
        XCTAssertNotNil(MachineParser.friendlyMessage(for: "container machine failed to create user"))
        XCTAssertNotNil(MachineParser.friendlyMessage(for: "Error: Unexpected argument 'machine'"))
        XCTAssertNil(MachineParser.friendlyMessage(for: "image not found"))
        let explained = MachineParser.explain(DeckError.commandFailed("/sbin/init: not found"))
        XCTAssertTrue(explained.localizedDescription.contains(MachineImages.recommended))
    }

    func testNames() {
        XCTAssertTrue(MachineImages.isValidName("dev-box_1"))
        XCTAssertFalse(MachineImages.isValidName("-dev"))
        XCTAssertFalse(MachineImages.isValidName("a"))
        XCTAssertFalse(MachineImages.isValidName("has space"))
        XCTAssertEqual(MachineImages.dnsName(for: "Dev"), "dev.machine")
        XCTAssertEqual(MachineImages.suggestedName(for: "alpine:3.22"), "alpine-3.22")
        XCTAssertEqual(MachineImages.suggestedName(for: "ghcr.io/me/dev-box"), "dev-box-latest")
    }
}
