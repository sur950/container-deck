import XCTest
@testable import DeckCore

/// Runs the v2 machine, export and diagnostics calls against the real `container` tool.
/// Off unless DECK_LIVE_POLISH=1. Makes and removes `deck-v2-mcc-live*` resources only.
final class PolishLiveTests: XCTestCase {
    private let cliPath = "/usr/local/bin/container"

    private func client() throws -> ContainerClient {
        guard ProcessInfo.processInfo.environment["DECK_LIVE_POLISH"] == "1" else {
            throw XCTSkip("Set DECK_LIVE_POLISH=1 to run against the real container tool.")
        }
        guard FileManager.default.isExecutableFile(atPath: cliPath) else { throw XCTSkip("No container tool.") }
        return ContainerClient(cliPath: cliPath)
    }

    func testLiveMachineFlow() async throws {
        let client = try client()
        let name = "deck-v2-mcc-live"
        try? await client.deleteMachine(name)

        let check = await client.checkMachineImage(MachineImages.recommended)
        XCTAssertEqual(check, .ok)

        let options = MachineOptions(name: name, image: MachineImages.recommended, cpus: 1, memory: "1G", homeMount: "none", boot: true)
        try await client.createMachine(options, extras: MachineCreateExtras(user: "deck", home: "/home/deck"))
        do {
            let detail = try await client.machineDetail(name)
            XCTAssertEqual(detail.username, "deck")
            XCTAssertEqual(detail.guestHome, "/home/deck")

            // Live stats from /proc, two samples for CPU.
            let first = try await client.machineProcSample(name)
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let second = try await client.machineProcSample(name)
            XCTAssertEqual(second.cpuCount, 1)
            XCTAssertGreaterThan(second.memoryTotalBytes, 500_000_000)
            XCTAssertNotNil(second.cpuPercent(since: first))

            // Apply and Restart.
            try await client.applyMachineConfig(name, change: MachineConfigChange(cpus: 2, virtualization: false), restart: true)
            let after = try await client.machineProcSample(name)
            XCTAssertEqual(after.cpuCount, 2)
            let boot = try XCTUnwrap(client.machineBootConfig(name))
            XCTAssertEqual(boot.cpus, 2)
            XCTAssertEqual(boot.virtualization, false)
        } catch {
            try? await client.stopMachine(name)
            try? await client.deleteMachine(name)
            throw error
        }
        try? await client.stopMachine(name)
        try await client.deleteMachine(name)
    }

    func testLiveExportAndDiagnostics() async throws {
        let client = try client()
        let name = "deck-v2-mcc-live-export"
        _ = try? await client.runner.run(cliPath, ["delete", "--force", name])
        _ = try await client.run(["run", "-d", "--name", name, "alpine:latest", "sleep", "300"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).tar")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await client.exportContainer(name, to: file)
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(size, 1_000_000)
        } catch {
            _ = try? await client.runner.run(cliPath, ["delete", "--force", name])
            throw error
        }
        _ = try? await client.runner.run(cliPath, ["delete", "--force", name])

        let report = await DiagnosticsCollector.collect(client: client, context: DiagnosticsContext(appVersion: "test", appBuild: "0", cliPath: cliPath, backend: nil))
        XCTAssertEqual(report.value("Service"), "Running")
        XCTAssertNotEqual(report.compatibility.verdict, .unknown)
        XCTAssertNotNil(report.value("Default kernel"))
        XCTAssertFalse(report.text().contains(NSHomeDirectory()))
    }
}
