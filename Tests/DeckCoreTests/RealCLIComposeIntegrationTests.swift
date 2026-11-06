import XCTest
@testable import DeckCore

/// Drives ComposeRunner against the real `container` CLI.
/// Runs only with DECK_INTEGRATION=1 (and DECK_COMPOSE_FILE pointing at a compose file).
/// Uses project name deck-test-compose and takes everything down at the end.
final class RealCLIComposeIntegrationTests: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["DECK_INTEGRATION"] == "1" }

    func testComposeLifecycleAgainstRealCLI() async throws {
        try XCTSkipUnless(enabled, "Set DECK_INTEGRATION=1 to run against the real CLI.")
        let path = ProcessInfo.processInfo.environment["DECK_COMPOSE_FILE"] ?? "/tmp/deck-compose-it/compose.yaml"
        let client = ContainerClient(cliPath: "/usr/local/bin/container")
        let runner = ComposeRunner(client: client, pollInterval: 0.5)
        let project = try ComposeParser.load(file: URL(fileURLWithPath: path))
        XCTAssertEqual(project.name, "deck-test-compose")
        let plan = try ComposePlanner.plan(project)
        let log = EventLog()
        let events: ComposeEventHandler = { log.add($0) }

        addTeardownBlock {
            try? await runner.down(project: "deck-test-compose", removeVolumes: true, plan: plan, events: { _ in })
        }

        // Up
        do {
            try await runner.up(plan, events: events)
        } catch {
            XCTFail("up failed: \(error)\n\(log.text)")
            return
        }
        print(log.text)

        // Container id equals --name, labels find project containers.
        let status = try await runner.ps(project: "deck-test-compose", plan: plan)
        XCTAssertEqual(Set(status.map(\.service)), ["init", "web", "worker"])
        for item in status {
            XCTAssertEqual(item.container.id, "deck-test-compose-\(item.service)")
        }
        XCTAssertTrue(status.first { $0.service == "web" }?.container.isRunning ?? false)
        XCTAssertTrue(status.first { $0.service == "worker" }?.container.isRunning ?? false)

        // Network and volume exist.
        let networks = try await client.listNetworks().map(\.name)
        XCTAssertTrue(networks.contains("deck-test-compose_backend"), "\(networks)")
        let volumes = try await client.listVolumes().map(\.name)
        XCTAssertTrue(volumes.contains("deck-test-compose_webdata"), "\(volumes)")

        // Env reached the container, and service discovery wrote /etc/hosts.
        let env = try await client.exec("deck-test-compose-web", ["printenv", "GREETING"])
        XCTAssertEqual(env.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        let hosts = try await client.exec("deck-test-compose-worker", ["cat", "/etc/hosts"])
        XCTAssertTrue(hosts.stdout.contains("web"), hosts.stdout)

        // Second up is a no-op.
        let again = EventLog()
        try await runner.up(plan, events: { again.add($0) })
        XCTAssertTrue(again.text.contains("Up to date"), again.text)

        // Logs
        var got: [ComposeLogLine] = []
        for try await line in runner.logs(project: "deck-test-compose", services: ["worker", "init"], follow: false) {
            got.append(line)
        }
        XCTAssertTrue(got.contains { $0.service == "worker" && $0.text.contains("worker up") }, "\(got)")
        XCTAssertTrue(got.contains { $0.service == "init" && $0.text.contains("init done") }, "\(got)")

        // Stop, start, restart
        try await runner.stop(project: "deck-test-compose", services: ["worker"], plan: plan, events: events)
        var worker = try await runner.ps(project: "deck-test-compose").first { $0.service == "worker" }
        XCTAssertEqual(worker?.container.state, .stopped)
        try await runner.restart(project: "deck-test-compose", services: ["worker"], plan: plan, events: events)
        worker = try await runner.ps(project: "deck-test-compose").first { $0.service == "worker" }
        XCTAssertEqual(worker?.container.state, .running)

        // Down
        try await runner.down(project: "deck-test-compose", removeVolumes: true, plan: plan, events: events)
        let left = try await runner.ps(project: "deck-test-compose")
        XCTAssertTrue(left.isEmpty)
        let networksAfter = try await client.listNetworks().map(\.name)
        XCTAssertFalse(networksAfter.contains("deck-test-compose_backend"))
        let volumesAfter = try await client.listVolumes().map(\.name)
        XCTAssertFalse(volumesAfter.contains("deck-test-compose_webdata"))
    }

    /// A failing one-shot dependency must stop `up`.
    func testCompletedDependencyFailureAgainstRealCLI() async throws {
        try XCTSkipUnless(enabled, "Set DECK_INTEGRATION=1 to run against the real CLI.")
        let yaml = """
        name: deck-test-compose
        services:
          init:
            image: alpine:3.22
            command: ["sh", "-c", "exit 4"]
          app:
            image: alpine:3.22
            command: ["sleep", "60"]
            depends_on:
              init:
                condition: service_completed_successfully
        """
        let client = ContainerClient(cliPath: "/usr/local/bin/container")
        let runner = ComposeRunner(client: client, pollInterval: 0.5)
        let project = try ComposeParser.parse(yaml, file: URL(fileURLWithPath: "/tmp/deck-compose-it/fail.yaml"))
        let plan = try ComposePlanner.plan(project)
        addTeardownBlock {
            try? await runner.down(project: "deck-test-compose", removeVolumes: true, plan: plan, events: { _ in })
        }
        do {
            try await runner.up(plan, events: { _ in })
            XCTFail("up should fail when init exits with 4")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("4"), error.localizedDescription)
        }
        let app = try await runner.ps(project: "deck-test-compose").first { $0.service == "app" }
        XCTAssertNil(app)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ComposeEvent] = []

    func add(_ event: ComposeEvent) {
        lock.lock(); items.append(event); lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return items.map { "[\($0.kind.rawValue)] \($0.service ?? "-") \($0.message)" }.joined(separator: "\n")
    }
}
