import XCTest
@testable import DeckCore

// MARK: - Helpers

/// A fake engine. Commands go through MockRunner (so tests can read the calls),
/// and a successful start or stop flips the engine on or off for the probe.
private final class SimulatedEngine: CommandRunning, @unchecked Sendable {
    let mock = MockRunner()
    let engine: DetectedEngine
    private let lock = NSLock()
    private var _running: Bool
    /// The start command succeeds, but the engine never answers.
    var startNeverAnswers = false
    /// The stop command succeeds, but the engine keeps answering.
    var stopIgnored = false
    /// Seconds the start command hangs before it returns.
    var startDelay: TimeInterval = 0
    /// Like OrbStack: touching the docker socket after a stop starts the engine again.
    var probeRestarts = false
    /// Comes back up once right after the first stop.
    var bounceOnce = false
    private var stoppedOnce = false
    /// Backend state answers STARTING this many times after the start, then DISABLED.
    var startingAnswers = 0
    private var readyCalls = 0
    private(set) var probesAfterStop = 0

    init(running: Bool, engine: DetectedEngine = orbEngine) {
        self._running = running
        self.engine = engine
        mock.responses["start"] = CommandResult(exitCode: 0, stdout: "")
        mock.responses["stop"] = CommandResult(exitCode: 0, stdout: "")
    }

    var running: Bool {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }

    var calls: [[String]] { mock.calls }

    /// "start", "stop", "pgrep -f ..." style lines without the full path.
    var commandNames: [String] {
        calls.map { call in
            let name = URL(fileURLWithPath: call[0]).lastPathComponent
            return ([name] + call.dropFirst()).joined(separator: " ")
        }
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        if arguments == ["start"], startDelay > 0 {
            try await Task.sleep(for: .seconds(startDelay))
        }
        if arguments == ["api", "/v1/backend_state"] {
            _ = try await mock.run(executable, arguments, stdin: stdin)
            guard running else { return CommandResult(exitCode: 1, stdout: "", stderr: "connection refused") }
            let busy: Bool = lock.withLock {
                readyCalls += 1
                return readyCalls <= startingAnswers
            }
            return CommandResult(exitCode: 0, stdout: busy ? #"{"vmState":"STARTING"}"# : #"{"vmState":"DISABLED"}"#)
        }
        if arguments == ["status"] {
            _ = try await mock.run(executable, arguments, stdin: stdin)  // record the call
            return CommandResult(exitCode: running ? 0 : 1, stdout: running ? "Running" : "Stopped")
        }
        let result = try await mock.run(executable, arguments, stdin: stdin)
        if arguments == ["stop"], result.succeeded, !stopIgnored, bounceOnce {
            let first: Bool = lock.withLock {
                let value = !stoppedOnce
                stoppedOnce = true
                return value
            }
            if first {
                running = false
                Task { try? await Task.sleep(for: .milliseconds(5)); self.running = true }
                return result
            }
        }
        if result.succeeded {
            if arguments == ["start"], !startNeverAnswers { running = true }
            if arguments == ["stop"], !stopIgnored { running = false }
        }
        return result
    }

    var probe: EngineSession.Probe {
        { [self] in
            if !running, stopRequested {
                lock.withLock { probesAfterStop += 1 }
                if probeRestarts { running = true }
            }
            return running ? [engine] : []
        }
    }

    var stopRequested: Bool { calls.contains { $0.last == "stop" } }
}

private let orbEngine = DetectedEngine(
    id: "socket:/Users/test/.orbstack/run/docker.sock", kind: .orbStack, name: "OrbStack", state: .running,
    endpoint: .dockerSocket("/Users/test/.orbstack/run/docker.sock")
)

private let appPattern = #"OrbStack\.app/Contents/MacOS/OrbStack( |$)"#

private func orbPlan(startTimeout: TimeInterval = 2, stopTimeout: TimeInterval = 1) -> EngineControlPlan {
    EngineControlPlan(
        family: .orbStack,
        start: [EngineCommand("/usr/local/bin/orbctl", ["start"])],
        stop: [EngineCommand("/usr/local/bin/orbctl", ["stop"])],
        appProcessPattern: appPattern,
        startTimeout: startTimeout, stopTimeout: stopTimeout, pollInterval: 0.02
    )
}

private func image(_ reference: String, pullable: Bool, size: UInt64 = 1_000) -> EngineImage {
    EngineImage(
        engineID: orbEngine.id, engineName: "OrbStack", imageID: "sha256:\(reference)", reference: reference,
        repoDigests: pullable ? ["\(reference)@sha256:1"] : [], sizeBytes: size
    )
}

/// Collects activity and steps from @Sendable callbacks.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _activities: [EngineActivity] = []
    private var _steps: [String: ImportStep] = [:]
    private var _log: [String] = []

    func activity(_ value: EngineActivity) { lock.lock(); _activities.append(value); lock.unlock() }
    func step(_ id: String, _ value: ImportStep) { lock.lock(); _steps[id] = value; lock.unlock() }
    func note(_ line: String) { lock.lock(); _log.append(line); lock.unlock() }

    var activities: [EngineActivity] { lock.lock(); defer { lock.unlock() }; return _activities }
    var titles: [String] { activities.map(\.title) }
    var steps: [String: ImportStep] { lock.lock(); defer { lock.unlock() }; return _steps }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
}

private struct Boom: LocalizedError {
    var errorDescription: String? { "boom" }
}

private func fakeEnvironment(executables: Set<String>, files: [String: Data] = [:]) -> EngineEnvironment {
    EngineEnvironment(
        home: "/Users/test",
        dockerHost: nil,
        files: FileSystem(
            fileExists: { executables.contains($0) || files[$0] != nil },
            isExecutable: { executables.contains($0) },
            contentsOfDirectory: { _ in [] }
        ),
        readFile: { files[$0] },
        resolvePath: { $0 }
    )
}

// MARK: - Tests

final class EngineStoppedImportTests: XCTestCase {

    // MARK: Plans and command lines

    func testOrbStackPlan() throws {
        let planner = EngineControlPlanner(environment: fakeEnvironment(executables: ["/usr/local/bin/orbctl"]))
        let stopped = DetectedEngine(id: "missing:orbStack", kind: .orbStack, name: "OrbStack", state: .stopped)
        let plan = try XCTUnwrap(planner.plan(for: stopped))
        XCTAssertEqual(plan.family, .orbStack)
        XCTAssertEqual(plan.start.map(\.commandLine), ["/usr/local/bin/orbctl start"])
        XCTAssertEqual(plan.stop.map(\.commandLine), ["/usr/local/bin/orbctl stop"])
        XCTAssertEqual(plan.status?.commandLine, "/usr/local/bin/orbctl status")
        XCTAssertEqual(plan.beforeStop, [])
        XCTAssertEqual(plan.appProcessPattern, appPattern)
        XCTAssertEqual(plan.name, "OrbStack")
    }

    func testRancherPlanRestoresStartInBackground() throws {
        let rdctl = "/Users/test/.rd/bin/rdctl"
        let settings = "/Users/test/Library/Preferences/rancher-desktop/settings.json"
        let off = Data(#"{"version":17,"application":{"autoStart":false,"startInBackground":false}}"#.utf8)
        let planner = EngineControlPlanner(environment: fakeEnvironment(executables: [rdctl], files: [settings: off]))
        let stopped = DetectedEngine(id: "missing:rancherDesktop", kind: .rancherDesktop, name: "Rancher Desktop", state: .stopped)
        let plan = try XCTUnwrap(planner.plan(for: stopped))
        XCTAssertEqual(plan.start.map(\.arguments), [["start", "--application.start-in-background", "--no-modal-dialogs"]])
        XCTAssertEqual(plan.beforeStop.map(\.arguments), [["set", "--application.start-in-background=false"]])
        XCTAssertEqual(plan.stop.map(\.arguments), [["shutdown"]])
        XCTAssertNil(plan.appProcessPattern, "rdctl shutdown quits the app itself")

        // Already set to start in the background: nothing to undo.
        let on = Data(#"{"application":{"startInBackground":true}}"#.utf8)
        let planner2 = EngineControlPlanner(environment: fakeEnvironment(executables: [rdctl], files: [settings: on]))
        XCTAssertEqual(planner2.plan(for: stopped)?.beforeStop, [])

        XCTAssertFalse(EngineControlPlanner.rancherStartsInBackground(nil))
        XCTAssertFalse(EngineControlPlanner.rancherStartsInBackground(Data("{oops".utf8)))
    }

    func testRancherContainerdBelongsToRancherFamily() {
        let entry = DetectedEngine(id: "nerdctl:k8s.io", kind: .rancherContainerd, name: "Rancher Desktop (k8s.io)", state: .running)
        XCTAssertTrue(EngineFamily.rancherDesktop.matches(entry))
        XCTAssertFalse(EngineFamily.orbStack.matches(entry))
    }

    func testDockerDesktopPodmanColimaPlans() throws {
        let docker = "/Applications/Docker.app/Contents/Resources/bin/docker"
        let podman = "/opt/homebrew/bin/podman"
        let colima = "/opt/homebrew/bin/colima"
        let planner = EngineControlPlanner(environment: fakeEnvironment(executables: [docker, podman, colima]))

        let desktop = try XCTUnwrap(planner.plan(for: DetectedEngine(id: "missing:dockerDesktop", kind: .dockerDesktop, name: "Docker Desktop", state: .stopped)))
        XCTAssertEqual(desktop.start, [EngineCommand(docker, ["desktop", "start"])])
        XCTAssertEqual(desktop.stop, [EngineCommand(docker, ["desktop", "stop"])])

        let machine = DetectedEngine(id: "podman-machine:dev", kind: .podman, name: "Podman (dev)", state: .stopped, podmanBinary: podman)
        let podmanPlan = try XCTUnwrap(planner.plan(for: machine))
        XCTAssertEqual(podmanPlan.family, .podman(machine: "dev"))
        XCTAssertEqual(podmanPlan.start, [EngineCommand(podman, ["machine", "start", "dev"])])
        XCTAssertEqual(podmanPlan.stop, [EngineCommand(podman, ["machine", "stop", "dev"])])
        XCTAssertEqual(planner.plan(for: DetectedEngine(id: "missing:podman", kind: .podman, name: "Podman", state: .stopped))?.family,
                       .podman(machine: "podman-machine-default"))

        let profile = DetectedEngine(
            id: "socket:/Users/test/.colima/work/docker.sock", kind: .colima, name: "Colima (work)", state: .stopped,
            endpoint: .dockerSocket("/Users/test/.colima/work/docker.sock")
        )
        let colimaPlan = try XCTUnwrap(planner.plan(for: profile))
        XCTAssertEqual(colimaPlan.family, .colima(profile: "work"))
        XCTAssertEqual(colimaPlan.start, [EngineCommand(colima, ["start", "--profile", "work"])])
        XCTAssertEqual(colimaPlan.stop, [EngineCommand(colima, ["stop", "--profile", "work"])])
        XCTAssertEqual(colimaPlan.status, EngineCommand(colima, ["status", "--profile", "work"]))
        XCTAssertEqual(planner.plan(for: DetectedEngine(id: "missing:colima", kind: .colima, name: "Colima", state: .stopped))?.family,
                       .colima(profile: "default"))
        XCTAssertTrue(EngineFamily.colima(profile: "work").matches(profile))
        XCTAssertFalse(EngineFamily.colima(profile: "default").matches(profile))
    }

    func testNoPlanWithoutBinaryOrForUnsupportedEngines() {
        // A wrapper script in ~/.local/bin is not real Colima.
        let planner = EngineControlPlanner(environment: fakeEnvironment(executables: ["/Users/test/.local/bin/colima"]))
        XCTAssertNil(planner.plan(for: DetectedEngine(id: "missing:colima", kind: .colima, name: "Colima", state: .stopped)))
        XCTAssertNil(planner.plan(for: DetectedEngine(id: "missing:orbStack", kind: .orbStack, name: "OrbStack", state: .stopped)))
        XCTAssertNil(planner.plan(for: DetectedEngine(id: "x", kind: .lima, name: "Lima (a)", state: .stopped)))
        XCTAssertNil(planner.plan(for: DetectedEngine(id: "y", kind: .other, name: "Docker context", state: .stopped)))
        let orbPlanner = EngineControlPlanner(environment: fakeEnvironment(executables: ["/usr/local/bin/orbctl"]))
        XCTAssertNil(orbPlanner.plan(for: DetectedEngine(id: "missing:orbStack", kind: .orbStack, name: "OrbStack", state: .notFound)))
    }

    // MARK: Start if stopped, never stop what was running

    func testStartsStoppedEngineListsAndStopsIt() async throws {
        let sim = SimulatedEngine(running: false)
        let recorder = Recorder()
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        let listing = try await workflow.listImages(activity: { recorder.activity($0) }) { engines in
            recorder.note("list while running=\(sim.running)")
            XCTAssertEqual(engines.map(\.id), [orbEngine.id])
            return [image("alpine:latest", pullable: true)]
        }
        XCTAssertEqual(listing.images.count, 1)
        XCTAssertFalse(listing.wasRunning)
        XCTAssertEqual(listing.stop, EngineStopResult(stopped: true))
        XCTAssertEqual(recorder.log, ["list while running=true"])
        XCTAssertFalse(sim.running)
        // pgrep says the app was closed (exit 1), so it is quit again after the stop.
        XCTAssertEqual(sim.commandNames, ["pgrep -f \(appPattern)", "orbctl start", "orbctl stop", "pkill -f \(appPattern)"])
        XCTAssertEqual(recorder.titles, ["Starting OrbStack", "Waiting for OrbStack", "Listing images", "Stopping OrbStack"])
    }

    func testNeverStopsAnEngineThatWasRunning() async throws {
        let sim = SimulatedEngine(running: true)
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        let listing = try await workflow.listImages { _ in [image("alpine:latest", pullable: false)] }
        XCTAssertTrue(listing.wasRunning)
        XCTAssertNil(listing.stop)
        XCTAssertTrue(sim.running)
        XCTAssertEqual(sim.calls, [])

        // Same for an import that needs the engine.
        let outcome = try await workflow.importImages(
            [image("local:dev", pullable: false)], neededBytes: 10, freeBytes: 1_000,
            pull: { _ in XCTFail("nothing to pull") }, export: { _, _ in }
        )
        XCTAssertFalse(outcome.startedEngine)
        XCTAssertNil(outcome.stop)
        XCTAssertTrue(sim.running)
        XCTAssertEqual(sim.calls, [])

        // A session on a running engine has nothing to finish.
        let session = EngineSession(plan: orbPlan(), runner: sim, probe: sim.probe)
        _ = try await session.ensureRunning()
        let finished = await session.finish()
        XCTAssertNil(finished)
    }

    func testAppLeftOpenWhenItWasOpenBefore() async throws {
        let sim = SimulatedEngine(running: false)
        sim.mock.responses["-f \(appPattern)"] = CommandResult(exitCode: 0, stdout: "123\n")
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        _ = try await workflow.listImages { _ in [] }
        XCTAssertFalse(sim.running)
        XCTAssertFalse(sim.calls.contains { $0[0] == EngineControlPlan.pkill }, "Must not quit an app that was open")
        XCTAssertEqual(sim.commandNames.last, "orbctl stop")
    }

    // MARK: Stop on success, failure and cancel

    func testStopsWhenListingFails() async {
        let sim = SimulatedEngine(running: false)
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        do {
            _ = try await workflow.listImages { _ in throw Boom() }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "boom")
        }
        XCTAssertFalse(sim.running)
        XCTAssertTrue(sim.commandNames.contains("orbctl stop"))
    }

    func testStartCommandFailureStillRunsStop() async {
        let sim = SimulatedEngine(running: false)
        sim.mock.responses["start"] = CommandResult(exitCode: 1, stdout: "", stderr: "first line\nVM failed to boot")
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        do {
            _ = try await workflow.listImages { _ in [] }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? EngineControlError, .startFailed("OrbStack", "VM failed to boot"))
            XCTAssertEqual(error.localizedDescription, "Could not start OrbStack. VM failed to boot")
        }
        // A half started engine is cleaned up.
        XCTAssertTrue(sim.commandNames.contains("orbctl stop"))
    }

    func testStopsOnCancel() async throws {
        let sim = SimulatedEngine(running: false)
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        let task = Task {
            try await workflow.listImages { _ in
                try await Task.sleep(for: .seconds(30))
                return []
            }
        }
        // Wait until the engine is up and listing has begun.
        for _ in 0..<200 where !sim.running { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(sim.running, "Cancel must stop the engine we started")
        XCTAssertTrue(sim.commandNames.contains("orbctl stop"))
        XCTAssertTrue(sim.commandNames.contains("pkill -f \(appPattern)"))
    }

    func testCancelWhileStartingStillStops() async throws {
        let sim = SimulatedEngine(running: false)
        sim.startDelay = 30
        let workflow = StoppedEngineWorkflow(plan: orbPlan(startTimeout: 60), runner: sim, probe: sim.probe)
        let task = Task { try await workflow.listImages { _ in [] } }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(sim.commandNames.contains("orbctl stop"))
    }

    // MARK: Timeouts

    func testStartTimesOutWhenEngineNeverAnswers() async {
        let sim = SimulatedEngine(running: false)
        sim.startNeverAnswers = true
        let workflow = StoppedEngineWorkflow(plan: orbPlan(startTimeout: 0.3), runner: sim, probe: sim.probe)
        let began = Date()
        do {
            _ = try await workflow.listImages { _ in [] }
            XCTFail("should time out")
        } catch {
            XCTAssertEqual(error as? EngineControlError, .startTimedOut("OrbStack", 1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        XCTAssertTrue(sim.commandNames.contains("orbctl stop"))
    }

    func testStartTimesOutWhenStartCommandHangs() async {
        let sim = SimulatedEngine(running: false)
        sim.startDelay = 30
        let workflow = StoppedEngineWorkflow(plan: orbPlan(startTimeout: 0.3), runner: sim, probe: sim.probe)
        let began = Date()
        do {
            _ = try await workflow.listImages { _ in [] }
            XCTFail("should time out")
        } catch {
            XCTAssertTrue(error is EngineControlError, "\(error)")
            XCTAssertEqual(error.localizedDescription, "OrbStack did not start within 1 seconds.")
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        XCTAssertTrue(sim.commandNames.contains("orbctl stop"))
    }

    func testStopThatDoesNotTakeIsRetriedAndReported() async throws {
        let sim = SimulatedEngine(running: false)
        sim.stopIgnored = true
        let workflow = StoppedEngineWorkflow(plan: orbPlan(stopTimeout: 0.1), runner: sim, probe: sim.probe)
        let listing = try await workflow.listImages { _ in [] }
        XCTAssertEqual(listing.stop?.stopped, false)
        XCTAssertEqual(listing.stop?.warning, "OrbStack is still running. Stop it yourself.")
        XCTAssertEqual(sim.commandNames.filter { $0 == "orbctl stop" }.count, 3)
        XCTAssertFalse(sim.calls.contains { $0[0] == EngineControlPlan.pkill }, "Never quit the app while the engine still runs")
    }

    func testStopIsConfirmedWithStatusNotTheSocket() async throws {
        let sim = SimulatedEngine(running: false)
        sim.probeRestarts = true
        var plan = orbPlan()
        plan.status = EngineCommand("/usr/local/bin/orbctl", ["status"])
        let listing = try await StoppedEngineWorkflow(plan: plan, runner: sim, probe: sim.probe).listImages { _ in [] }
        XCTAssertEqual(listing.stop, EngineStopResult(stopped: true))
        XCTAssertEqual(sim.probesAfterStop, 0, "Never touch the socket while it stops")
        XCTAssertFalse(sim.running)
        XCTAssertEqual(sim.commandNames, [
            "pgrep -f \(appPattern)", "orbctl start", "orbctl stop", "orbctl status", "pkill -f \(appPattern)", "orbctl status"
        ])
    }

    func testEngineThatBouncesBackIsStoppedAgain() async throws {
        let sim = SimulatedEngine(running: false)
        sim.bounceOnce = true
        var plan = orbPlan()
        plan.status = EngineCommand("/usr/local/bin/orbctl", ["status"])
        plan.pollInterval = 0.05
        let listing = try await StoppedEngineWorkflow(plan: plan, runner: sim, probe: sim.probe).listImages { _ in [] }
        XCTAssertEqual(listing.stop?.stopped, true)
        XCTAssertFalse(sim.running)
        XCTAssertEqual(sim.commandNames.filter { $0 == "orbctl stop" }.count, 2)
        XCTAssertEqual(sim.commandNames.last, "orbctl status")
        XCTAssertEqual(sim.commandNames.filter { $0.hasPrefix("pkill") }.count, 2)
    }

    func testStopWaitsForMinimumUptime() async throws {
        let sim = SimulatedEngine(running: false)
        var plan = orbPlan()
        plan.minimumUptime = 0.4
        let began = Date()
        _ = try await StoppedEngineWorkflow(plan: plan, runner: sim, probe: sim.probe).listImages { _ in [] }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 0.4, "A young engine is not stopped at once")
        XCTAssertFalse(sim.running)
    }

    func testWithTimeout() async throws {
        let fast = try await EngineSession.withTimeout(1) { 42 }
        XCTAssertEqual(fast, 42)
        let slow: Int? = try await EngineSession.withTimeout(0.05) {
            try await Task.sleep(for: .seconds(10))
            return 1
        }
        XCTAssertNil(slow)
    }

    // MARK: Rancher settings restore

    func testRancherRestoreRunsBeforeShutdownAndIsRetried() async throws {
        let sim = SimulatedEngine(running: false)
        sim.mock.responses["start"] = nil
        sim.mock.responses["set --application.start-in-background=false"] = CommandResult(exitCode: 0, stdout: "settings updated")
        let rancher = DetectedEngine(id: "socket:/Users/test/.rd/docker.sock", kind: .rancherDesktop, name: "Rancher Desktop", state: .running)
        let plan = EngineControlPlan(
            family: .rancherDesktop,
            start: [EngineCommand("/rd/rdctl", ["start"])],
            beforeStop: [EngineCommand("/rd/rdctl", ["set", "--application.start-in-background=false"])],
            stop: [EngineCommand("/rd/rdctl", ["stop"])],
            startTimeout: 1, stopTimeout: 0.5, pollInterval: 0.01
        )
        sim.mock.responses["start"] = CommandResult(exitCode: 0, stdout: "")
        let probe: EngineSession.Probe = { sim.running ? [rancher] : [] }
        let listing = try await StoppedEngineWorkflow(plan: plan, runner: sim, probe: probe).listImages { _ in [] }
        XCTAssertEqual(listing.stop, EngineStopResult(stopped: true))
        XCTAssertEqual(sim.commandNames, ["rdctl start", "rdctl set --application.start-in-background=false", "rdctl stop"])

        // The API never answers the restore: still shuts down, and says what was left.
        let sim2 = SimulatedEngine(running: false)
        let probe2: EngineSession.Probe = { sim2.running ? [rancher] : [] }
        let listing2 = try await StoppedEngineWorkflow(plan: plan, runner: sim2, probe: probe2).listImages { _ in [] }
        XCTAssertEqual(sim2.commandNames.filter { $0.hasPrefix("rdctl set") }.count, 3)
        XCTAssertEqual(listing2.stop?.stopped, true)
        XCTAssertEqual(listing2.stop?.warning, "Rancher Desktop may now open in the background. Change it in its settings.")
        XCTAssertFalse(sim2.running)
    }

    func testRancherWaitsUntilStartIsDoneBeforeListingAndStopping() async throws {
        let rancher = DetectedEngine(id: "socket:/Users/test/.rd/docker.sock", kind: .rancherDesktop, name: "Rancher Desktop", state: .running)
        let sim = SimulatedEngine(running: false, engine: rancher)
        sim.startingAnswers = 3
        let plan = EngineControlPlan(
            family: .rancherDesktop,
            start: [EngineCommand("/rd/rdctl", ["start"])],
            stop: [EngineCommand("/rd/rdctl", ["stop"])],
            ready: EngineCommand("/rd/rdctl", ["api", "/v1/backend_state"]),
            readyMarkers: ["STARTED", "DISABLED", "ERROR"],
            startTimeout: 2, stopTimeout: 1, pollInterval: 0.01
        )
        let recorder = Recorder()
        _ = try await StoppedEngineWorkflow(plan: plan, runner: sim, probe: sim.probe).listImages { _ in
            recorder.note("listed after \(sim.commandNames.filter { $0.hasPrefix("rdctl api") }.count) state checks")
            return []
        }
        // Three STARTING answers, then DISABLED: listing waits for the fourth.
        XCTAssertEqual(recorder.log, ["listed after 4 state checks"])
        XCTAssertFalse(sim.running)

        // Cancel while it still says STARTING: the stop waits for the start to end.
        let sim2 = SimulatedEngine(running: false, engine: rancher)
        sim2.startingAnswers = 1_000_000
        let session = EngineSession(plan: plan, runner: sim2, probe: sim2.probe)
        let task = Task { try await session.ensureRunning() }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        _ = try? await task.value
        let stop = await session.finish()
        let names = sim2.commandNames
        let firstStop = try XCTUnwrap(names.firstIndex(of: "rdctl stop"))
        XCTAssertTrue(names[..<firstStop].filter { $0.hasPrefix("rdctl api") }.count > 3, "Waited on the start before stopping")
        XCTAssertEqual(stop?.stopped, true)
    }

    // MARK: Disk space

    func testDiskSpaceRefusalStartsNothing() async {
        let sim = SimulatedEngine(running: false)
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        let images = [image("big:1", pullable: false, size: 6_000_000_000)]
        let needed = EngineImporter.requiredBytes(for: images)
        XCTAssertEqual(needed, 12_000_000_000)
        do {
            _ = try await workflow.importImages(
                images, neededBytes: needed, freeBytes: 5_000_000_000,
                pull: { _ in XCTFail("no pull") }, export: { _, _ in XCTFail("no export") }
            )
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? EngineControlError, .notEnoughSpace(needed: 12_000_000_000, free: 5_000_000_000))
            XCTAssertTrue(error.localizedDescription.hasPrefix("Not enough free disk space."))
        }
        XCTAssertEqual(sim.calls, [], "No engine start when space is short")
        XCTAssertFalse(sim.running)

        XCTAssertNoThrow(try DiskSpaceCheck.verify(needed: 10, free: nil))
        XCTAssertNoThrow(try DiskSpaceCheck.verify(needed: 0, free: 0))
        XCTAssertNoThrow(try DiskSpaceCheck.verify(needed: 10, free: 10))
        XCTAssertThrowsError(try DiskSpaceCheck.verify(needed: 11, free: 10))
    }

    // MARK: Import flow

    func testImportPullsFirstAndStartsEngineOnlyForLocalImages() async throws {
        let sim = SimulatedEngine(running: false)
        let recorder = Recorder()
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        let images = [image("alpine:latest", pullable: true), image("app:dev", pullable: false), image("tool:1", pullable: false)]
        let outcome = try await workflow.importImages(
            images, neededBytes: 10, freeBytes: 1_000,
            activity: { recorder.activity($0) },
            step: { recorder.step($0, $1) },
            pull: { image in recorder.note("pull \(image.reference) running=\(sim.running)") },
            export: { image, engine in
                XCTAssertEqual(engine.id, orbEngine.id)
                recorder.note("export \(image.reference) running=\(sim.running)")
            }
        )
        XCTAssertEqual(recorder.log, ["pull alpine:latest running=false", "export app:dev running=true", "export tool:1 running=true"])
        XCTAssertEqual(outcome.moved.count, 3)
        XCTAssertEqual(outcome.moved[images[0].id], "Pulled from the registry")
        XCTAssertEqual(outcome.moved[images[1].id], "Copied from OrbStack")
        XCTAssertTrue(outcome.startedEngine)
        XCTAssertEqual(outcome.stop, EngineStopResult(stopped: true))
        XCTAssertFalse(sim.running)
        XCTAssertEqual(recorder.titles, [
            "Checking free space", "Pulling 1 of 1", "Starting OrbStack", "Waiting for OrbStack",
            "Exporting 1 of 2", "Exporting 2 of 2", "Stopping OrbStack"
        ])
        XCTAssertEqual(recorder.steps[images[2].id], .done(method: "Copied from OrbStack"))
    }

    func testImportOfRegistryImagesNeverStartsEngine() async throws {
        let sim = SimulatedEngine(running: false)
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        let outcome = try await workflow.importImages(
            [image("a:1", pullable: true), image("b:1", pullable: true)], neededBytes: 1, freeBytes: 100,
            pull: { _ in }, export: { _, _ in XCTFail("no export") }
        )
        XCTAssertEqual(outcome.moved.count, 2)
        XCTAssertFalse(outcome.startedEngine)
        XCTAssertNil(outcome.stop)
        XCTAssertEqual(sim.calls, [])
    }

    func testPullFailureFallsBackToExport() async throws {
        let sim = SimulatedEngine(running: false)
        let recorder = Recorder()
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        let alpine = image("alpine:latest", pullable: true)
        let outcome = try await workflow.importImages(
            [alpine], neededBytes: 1, freeBytes: 100,
            pull: { _ in throw Boom() },
            export: { image, _ in recorder.note("export \(image.reference)") }
        )
        XCTAssertEqual(recorder.log, ["export alpine:latest"])
        XCTAssertEqual(outcome.moved[alpine.id], "Copied from OrbStack")
        XCTAssertFalse(sim.running)
    }

    func testExportFailureKeepsGoingAndStops() async throws {
        let sim = SimulatedEngine(running: false)
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        let bad = image("bad:1", pullable: false)
        let good = image("good:1", pullable: false)
        let outcome = try await workflow.importImages(
            [bad, good], neededBytes: 1, freeBytes: 100,
            pull: { _ in }, export: { image, _ in if image.reference == "bad:1" { throw Boom() } }
        )
        XCTAssertEqual(outcome.failed[bad.id], "boom")
        XCTAssertEqual(outcome.moved[good.id], "Copied from OrbStack")
        XCTAssertFalse(outcome.cancelled)
        XCTAssertEqual(outcome.stop?.stopped, true)
        XCTAssertFalse(sim.running)
    }

    func testImportStartFailureFailsEveryLocalImageAndStops() async throws {
        let sim = SimulatedEngine(running: false)
        sim.mock.responses["start"] = CommandResult(exitCode: 2, stdout: "", stderr: "no license")
        let recorder = Recorder()
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        let images = [image("a:1", pullable: false), image("b:1", pullable: false)]
        let outcome = try await workflow.importImages(
            images, neededBytes: 1, freeBytes: 100, step: { recorder.step($0, $1) },
            pull: { _ in }, export: { _, _ in XCTFail("no export") }
        )
        XCTAssertEqual(outcome.failed.count, 2)
        XCTAssertEqual(outcome.failed[images[0].id], "Could not start OrbStack. no license")
        XCTAssertEqual(recorder.steps[images[1].id], .failed("Could not start OrbStack. no license"))
        XCTAssertTrue(sim.commandNames.contains("orbctl stop"))
    }

    func testImportCancelStopsEngineAndMarksTheRest() async throws {
        let sim = SimulatedEngine(running: false)
        let recorder = Recorder()
        let workflow = StoppedEngineWorkflow(plan: orbPlan(), runner: sim, probe: sim.probe)
        let images = [image("a:1", pullable: false), image("b:1", pullable: false), image("c:1", pullable: false)]
        let task = Task {
            try await workflow.importImages(
                images, neededBytes: 1, freeBytes: 100, step: { recorder.step($0, $1) },
                pull: { _ in },
                export: { image, _ in
                    if image.reference == "a:1" { return }
                    try await Task.sleep(for: .seconds(30))
                }
            )
        }
        for _ in 0..<200 where recorder.steps[images[0].id] == nil { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = try await task.value
        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.moved.count, 1)
        XCTAssertEqual(recorder.steps[images[0].id], .done(method: "Copied from OrbStack"))
        XCTAssertEqual(recorder.steps[images[1].id], .cancelled)
        XCTAssertEqual(recorder.steps[images[2].id], .cancelled)
        XCTAssertEqual(outcome.stop?.stopped, true)
        XCTAssertFalse(sim.running, "Cancel must stop the engine we started")
    }

    func testActivityTitles() {
        XCTAssertEqual(EngineActivity.starting("OrbStack").title, "Starting OrbStack")
        XCTAssertEqual(EngineActivity.listing("OrbStack").title, "Listing images")
        XCTAssertEqual(EngineActivity.exporting(index: 2, total: 5).title, "Exporting 2 of 5")
        XCTAssertEqual(EngineActivity.stopping("Rancher Desktop").title, "Stopping Rancher Desktop")
        XCTAssertEqual(EngineFamily.podman(machine: "podman-machine-default").title, "Podman")
        XCTAssertEqual(EngineFamily.colima(profile: "work").title, "Colima (work)")
    }

    // MARK: - Live (DECK_LIVE_ENGINES=1)

    /// Real OrbStack and Rancher Desktop on this Mac. Each must be stopped before the test.
    /// Lists images, imports one small image through the engine export path, checks it in
    /// `container image list`, deletes it again, and checks the engine is stopped as found.
    func testLiveStoppedEngines() async throws {
        guard ProcessInfo.processInfo.environment["DECK_LIVE_ENGINES"] == "1" else {
            throw XCTSkip("Set DECK_LIVE_ENGINES=1 to start and stop real engines.")
        }
        let cli = "/usr/local/bin/container"
        guard FileManager.default.isExecutableFile(atPath: cli) else { throw XCTSkip("container CLI missing") }
        let client = ContainerClient(cliPath: cli)
        let detected = await EngineDetector().detect()
        let planner = EngineControlPlanner()
        var tested = 0

        for family in [EngineFamily.orbStack, .rancherDesktop] {
            guard let entry = detected.first(where: { family.matches($0) && $0.state == .stopped }),
                  let plan = planner.plan(for: entry)
            else { continue }
            tested += 1
            let name = plan.name
            let docker = family == .orbStack ? NSHomeDirectory() + "/.orbstack/bin/docker" : NSHomeDirectory() + "/.rd/bin/docker"
            let socket = family == .orbStack
                ? "unix://" + NSHomeDirectory() + "/.orbstack/run/docker.sock"
                : "unix://" + NSHomeDirectory() + "/.rd/docker.sock"
            let appWasOpen = try await Self.processRunning(plan.appProcessPattern)
            let settingsBefore = FileManager.default.contents(atPath: planner.rancherSettingsPath)
            let workflow = StoppedEngineWorkflow(plan: plan)
            let local = Set(try await client.listImages().map { ImageReference.normalize($0.reference) })
            // Never load over an image that is already in Apple's container.
            func pick(_ images: [EngineImage]) -> EngineImage? {
                images.filter { ($0.shortName == "alpine" || $0.shortName == "hello-world") && !local.contains($0.normalizedReference) }
                    .min(by: { $0.sizeBytes < $1.sizeBytes })
            }

            // 1. List. With no usable small image, pull hello-world into the engine with its own CLI.
            var listing = try await workflow.listImages { engines in
                try await EngineCatalog().images(in: engines[0])
            }
            XCTAssertEqual(listing.stop?.stopped, true, "\(name) stopped after listing")
            print("[live] \(name): started, listed \(listing.images.count) images, stopped")
            var pulledTestImage = false
            if pick(listing.images) == nil {
                let session = EngineSession(plan: plan, probe: StoppedEngineWorkflow.liveProbe(for: family))
                _ = try await session.ensureRunning()
                let pulled = try await ProcessRunner().run(docker, ["--host", socket, "pull", "hello-world"])
                let pullStop = await session.finish()
                XCTAssertEqual(pullStop?.stopped, true, "\(name) stopped after the test pull")
                XCTAssertTrue(pulled.succeeded, pulled.failureMessage)
                pulledTestImage = true
                listing = try await workflow.listImages { engines in try await EngineCatalog().images(in: engines[0]) }
                XCTAssertFalse(listing.wasRunning)
                XCTAssertEqual(listing.stop?.stopped, true, "\(name) stopped after the second listing")
            }
            let small = try XCTUnwrap(pick(listing.images), "\(name) has no usable alpine or hello-world")
            print("[live] \(name): \(listing.images.count) images, importing \(small.reference) (\(small.sizeBytes) bytes)")

            // 2. Import through the engine (skip the registry pull so the export path runs).
            let importer = EngineImporter(client: client)
            let outcome = try await workflow.importImages(
                [small], neededBytes: EngineImporter.requiredBytes(for: [small]), freeBytes: importer.freeBytes,
                pull: { _ in throw DeckError.commandFailed("skip pull in live test") },
                export: { image, engine in try await importer.copy(image, from: engine) { _ in } }
            )
            XCTAssertEqual(outcome.moved[small.id], "Copied from \(name)", "\(outcome.failed)")
            XCTAssertTrue(outcome.startedEngine)
            XCTAssertEqual(outcome.stop?.stopped, true)
            print("[live] \(name): import started the engine=\(outcome.startedEngine), stopped=\(outcome.stop?.stopped ?? false)")

            // 3. It is in Apple's container. Remove it again (it was not there before).
            let here = try await client.listImages().map { ImageReference.normalize($0.reference) }
            XCTAssertTrue(here.contains(small.normalizedReference), "\(small.normalizedReference) not in container image list")
            try await client.deleteImage(small.normalizedReference)
            print("[live] \(name): \(small.normalizedReference) imported, found in container image list, deleted")

            // 4. Remove the test image we pulled into the engine.
            if pulledTestImage {
                let session = EngineSession(plan: plan, probe: StoppedEngineWorkflow.liveProbe(for: family))
                _ = try await session.ensureRunning()
                let removed = try await ProcessRunner().run(docker, ["--host", socket, "rmi", "hello-world"])
                let cleanStop = await session.finish()
                XCTAssertEqual(cleanStop?.stopped, true, "\(name) stopped after removing the test image")
                print("[live] \(name): removed the test image from the engine, stopped again")
                XCTAssertTrue(removed.succeeded, removed.failureMessage)
            }

            // 5. Left as found.
            try await Task.sleep(for: .seconds(3))
            if let status = plan.status {
                let answer = try await ProcessRunner().run(status.executable, status.arguments)
                XCTAssertFalse(answer.succeeded, "\(name) must be stopped again: \(answer.stdout)")
            } else {
                let stillRunning = await StoppedEngineWorkflow.liveProbe(for: family)()
                XCTAssertTrue(stillRunning.isEmpty, "\(name) must be stopped again")
            }
            let appOpenNow = try await Self.processRunning(plan.appProcessPattern)
            XCTAssertEqual(appOpenNow, appWasOpen, "\(name) app process state changed")
            if family == .rancherDesktop {
                XCTAssertEqual(FileManager.default.contents(atPath: planner.rancherSettingsPath), settingsBefore, "Rancher settings changed")
            }
        }
        if tested == 0 { throw XCTSkip("No stopped OrbStack or Rancher Desktop on this Mac") }
    }

    private static func processRunning(_ pattern: String?) async throws -> Bool {
        guard let pattern else { return false }
        return try await ProcessRunner().run(EngineControlPlan.pgrep, ["-f", pattern]).succeeded
    }
}
