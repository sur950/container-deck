import XCTest
@testable import DeckCore

/// Machines v2: create flags, set flags, boot config, init check and /proc stats.
/// Fixtures recorded from `container` 1.6.1 with an alpine:3.22 machine on Apple M5.
final class PolishMachineTests: XCTestCase {
    private let cli = "/usr/local/bin/container"

    // Recorded: `machine run -- sh -c "<MachineProcStats.script>"`, trimmed (ram and loop devices dropped).
    static let procFixture = """
    __deck_proc__
    cpu  40 0 57 45751 3 0 6 0 0 0
    cpu0 14 0 29 22875 1 0 5 0 0 0
    cpu1 26 0 27 22876 1 0 0 0 0 0
    intr 9921 0 294 2840 0 0 0 0 0 0 0 0 4677 0 0 78 401
    ctxt 13534
    processes 311
    procs_running 1
    MemTotal:        2153056 kB
    MemFree:         1956488 kB
    MemAvailable:    2080232 kB
    0.00 0.00 0.00 1/85 172
    Inter-|   Receive                                                |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        lo:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
      eth0:   25524      92    0    0    0     0          0         0      602       7    0    0    0     0       0          0
       1       0 ram0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
       7       0 loop0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
     254       0 vda 80 31 248338 67 0 0 0 0 0 28 67 0 0 0 0 0 0
     254      16 vdb 4113 176 37610 4652 39 55 752 8 0 16 4663 0 0 0 0 13 2
    """

    // Recorded: plugin-state/machine-apiserver/machines/<id>/boot-config.json after
    // `machine set virtualization=true kernel=<path>`.
    static let bootConfigFixture = #"{"virtualization":true,"kernelPath":"\/Users\/me\/Library\/Application Support\/com.apple.container\/kernels\/vmlinux-6.18.35-197-debug","homeMount":"ro","cpus":2,"memory":"2gb"}"#

    func testCreateArgumentsPutExtrasBeforeImage() {
        let client = ContainerClient(cliPath: cli, runner: MockRunner())
        let options = MachineOptions(name: "dev", image: "alpine:3.22", cpus: 2, memory: "4G", homeMount: "ro", boot: false)
        let extras = MachineCreateExtras(virtualization: true, kernelPath: "/k/vmlinux", user: "dev", uid: 1000, gid: 1000,
                                         home: "/home/dev", platform: "linux/arm64", setDefault: true)
        XCTAssertEqual(client.createMachineArguments(options, extras: extras), [
            "machine", "create", "--name", "dev", "--cpus", "2", "--memory", "4G", "--home-mount", "ro", "--no-boot",
            "--platform", "linux/arm64", "--user", "dev", "--uid", "1000", "--gid", "1000", "--home", "/home/dev",
            "--set-default", "--virtualization", "--kernel", "/k/vmlinux", "alpine:3.22"
        ])
    }

    func testEmptyExtrasAddNothing() {
        let client = ContainerClient(cliPath: cli, runner: MockRunner())
        let options = MachineOptions(name: "a", image: "alpine:3.22")
        XCTAssertEqual(client.createMachineArguments(options, extras: MachineCreateExtras(user: "  ", home: "")),
                       client.createMachineArguments(options))
    }

    func testExtrasProblems() {
        XCTAssertEqual(MachineCreateExtras(kernelPath: "vmlinux").problems, ["The kernel path must start with /."])
        XCTAssertEqual(MachineCreateExtras(home: "home/dev").problems, ["The home folder must start with /."])
        XCTAssertFalse(MachineCreateExtras(user: "Bad User").problems.isEmpty)
        XCTAssertTrue(MachineCreateExtras(user: "1000:20").problems.isEmpty)
        XCTAssertTrue(MachineCreateExtras(user: "dev").problems.isEmpty)
    }

    func testSetArguments() {
        let client = ContainerClient(cliPath: cli, runner: MockRunner())
        let change = MachineConfigChange(cpus: 4, memory: "8G", homeMount: "none", virtualization: false, kernelPath: "/k")
        XCTAssertEqual(client.setMachineArguments("dev", change: change), [
            "machine", "set", "--name", "dev", "cpus=4", "memory=8G", "home-mount=none", "virtualization=false", "kernel=/k"
        ])
        XCTAssertTrue(MachineConfigChange(homeMount: "bad").isEmpty)
    }

    func testApplyAndRestartRunsSetStopBoot() async throws {
        let runner = MockRunner()
        let ok = CommandResult(exitCode: 0, stdout: "dev\n")
        runner.responses["machine set --name dev cpus=3"] = ok
        runner.responses["machine stop dev"] = ok
        runner.responses["machine run --name dev -- true"] = ok
        let client = ContainerClient(cliPath: cli, runner: runner)
        try await client.applyMachineConfig("dev", change: MachineConfigChange(cpus: 3), restart: true)
        XCTAssertEqual(runner.calls.map { $0.dropFirst().joined(separator: " ") }, [
            "machine set --name dev cpus=3", "machine stop dev", "machine run --name dev -- true"
        ])
    }

    func testApplyWithoutRestartOnlySets() async throws {
        let runner = MockRunner()
        runner.responses["machine set --name dev virtualization=true"] = CommandResult(exitCode: 0, stdout: "")
        let client = ContainerClient(cliPath: cli, runner: runner)
        try await client.applyMachineConfig("dev", change: MachineConfigChange(virtualization: true), restart: false)
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testBootConfigParse() throws {
        let config = try XCTUnwrap(MachineBootConfig.parse(Self.bootConfigFixture))
        XCTAssertEqual(config.virtualization, true)
        XCTAssertEqual(config.cpus, 2)
        XCTAssertEqual(config.homeMount, "ro")
        XCTAssertFalse(config.usesSystemKernel)
        XCTAssertTrue(MachineBootConfig(kernelPath: "/x/kernels/default.kernel-arm64").usesSystemKernel)
        XCTAssertTrue(MachineBootConfig().usesSystemKernel)
        XCTAssertNil(MachineBootConfig.parse("not json"))
        XCTAssertEqual(MachineBootConfig.fileURL(appRoot: "/r", machine: "m").path,
                       "/r/plugin-state/machine-apiserver/machines/m/boot-config.json")
    }

    func testInitCheckArgumentsAndResults() {
        let args = MachineInitCheck.arguments(image: "alpine:3.22", platform: "linux/amd64")
        XCTAssertEqual(Array(args.prefix(8)), ["run", "--rm", "--progress", "none", "--platform", "linux/amd64", "--entrypoint", "/bin/sh"])
        XCTAssertEqual(args[8], "alpine:3.22")
        XCTAssertEqual(MachineInitCheck.interpret(CommandResult(exitCode: 0, stdout: "")), .ok)
        XCTAssertEqual(MachineInitCheck.interpret(CommandResult(exitCode: 3, stdout: "")), .missing)
        // Recorded stderr for an image without the entrypoint binary.
        let noShell = CommandResult(exitCode: 1, stdout: "", stderr: "Error: failed to find target executable /bin/sh\n")
        XCTAssertEqual(MachineInitCheck.interpret(noShell), .noShell)
        XCTAssertFalse(MachineInitCheck.Result.missing.canCreate)
        let other = MachineInitCheck.interpret(CommandResult(exitCode: 1, stdout: "", stderr: "[1/6] Fetching image\nError: not found\n"))
        XCTAssertEqual(other, .failed("Error: not found"))
        XCTAssertTrue(other.canCreate)
    }

    func testProcParse() throws {
        let sample = try XCTUnwrap(MachineProcStats.parse(Self.procFixture))
        XCTAssertEqual(sample.cpuCount, 2)
        XCTAssertEqual(sample.cpuTotal, 40 + 57 + 45751 + 3 + 6)
        XCTAssertEqual(sample.cpuIdle, 45751 + 3)
        XCTAssertEqual(sample.memoryTotalBytes, 2153056 * 1024)
        XCTAssertEqual(sample.memoryUsedBytes, (2153056 - 2080232) * 1024)
        XCTAssertEqual(sample.processes, 85)
        XCTAssertEqual(sample.netRxBytes, 25524)
        XCTAssertEqual(sample.netTxBytes, 602)
        XCTAssertEqual(sample.diskReadBytes, (248338 + 37610) * 512)
        XCTAssertEqual(sample.diskWriteBytes, 752 * 512)
    }

    func testProcParseIgnoresLinesBeforeMarkerAndWideCounters() throws {
        let text = "noise 1 2 3\n__deck_proc__\ncpu  1 0 1 8 0 0 0 0 0 0\n face |bytes\n  eth0:123456789 5 0 0 0 0 0 0 987654321 3 0 0 0 0 0 0\n"
        let sample = try XCTUnwrap(MachineProcStats.parse(text))
        XCTAssertEqual(sample.netRxBytes, 123456789)
        XCTAssertEqual(sample.netTxBytes, 987654321)
        XCTAssertNil(MachineProcStats.parse("garbage"))
    }

    func testCPUPercentFromTwoSamples() {
        let first = MachineProcSample(cpuTotal: 1000, cpuIdle: 900, cpuCount: 2)
        let second = MachineProcSample(cpuTotal: 1200, cpuIdle: 1000, cpuCount: 2)
        // 100 of 200 jiffies busy on 2 cores = one full core.
        XCTAssertEqual(second.cpuPercent(since: first) ?? -1, 100, accuracy: 0.01)
        XCTAssertNil(second.cpuPercent(since: nil))
        XCTAssertNil(first.cpuPercent(since: second))
    }

    func testProcSampleThroughClient() async throws {
        let runner = MockRunner()
        runner.responses[MachineProcStats.arguments(machine: "m").joined(separator: " ")] = CommandResult(exitCode: 0, stdout: Self.procFixture)
        let client = ContainerClient(cliPath: cli, runner: runner)
        let sample = try await client.machineProcSample("m")
        XCTAssertEqual(sample.cpuCount, 2)
    }

    func testNestedVirtualizationNeedsM3() {
        XCTAssertTrue(MachineHost.supportsNestedVirtualization(chip: "Apple M5"))
        XCTAssertTrue(MachineHost.supportsNestedVirtualization(chip: "Apple M3 Max"))
        XCTAssertFalse(MachineHost.supportsNestedVirtualization(chip: "Apple M2 Pro"))
        XCTAssertFalse(MachineHost.supportsNestedVirtualization(chip: "Intel Core i9"))
    }
}
