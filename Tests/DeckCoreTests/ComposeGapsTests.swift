import XCTest
import Yams
@testable import DeckCore

// Compose keys and Up options added to close the gaps with other compose tools:
// lifecycle hooks, DNS, anonymous volumes, orphans, dry run, pull policies, the
// run flags that map to RunOptions, and stop signals.

private let gapsFile = URL(fileURLWithPath: "/work/gaps/compose.yaml")

private func parseGaps(_ yaml: String, env: [String: String] = [:]) throws -> ComposeProject {
    try ComposeParser.parse(yaml, file: gapsFile, environment: env, readFile: { _ in nil })
}

private let fullYAML = """
name: gaps
services:
  web:
    image: nginx:alpine
    user: "101:101"
    read_only: true
    init: true
    tmpfs:
      - /run
      - /tmp:size=64m
    cap_add: [NET_ADMIN]
    cap_drop: [ALL]
    dns:
      - 1.1.1.1
      - 8.8.8.8
    dns_search: example.com
    dns_opt: ["ndots:2", "timeout:3"]
    shm_size: 128m
    ulimits:
      nproc: 512
      nofile:
        soft: 1024
        hard: 2048
    mac_address: "02:42:ac:11:00:02"
    stop_signal: SIGQUIT
    stop_grace_period: 1m30s
    pull_policy: always
    volumes:
      - /data
      - type: volume
        target: /cache
        read_only: true
      - type: tmpfs
        target: /scratch
        tmpfs:
          size: 10m
          mode: 1777
    post_start:
      - command: echo started
        user: root
        working_dir: /app
        environment:
          STAGE: boot
      - command: ["sh", "-c", "touch /tmp/ready"]
    pre_stop:
      - command: nginx -s quit
"""

final class ComposeGapsTests: XCTestCase {

    // MARK: Parser

    func testParserMapsEveryNewKey() throws {
        let project = try parseGaps(fullYAML)
        XCTAssertTrue(project.problems.isEmpty, "\(project.problems)")
        let web = try XCTUnwrap(project.service("web"))
        XCTAssertEqual(web.user, "101:101")
        XCTAssertTrue(web.readOnly)
        XCTAssertTrue(web.initProcess)
        XCTAssertEqual(web.tmpfs, ["/run", "/tmp:size=64m"])
        XCTAssertEqual(web.capAdd, ["NET_ADMIN"])
        XCTAssertEqual(web.capDrop, ["ALL"])
        XCTAssertEqual(web.dns, ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(web.dnsSearch, ["example.com"])
        XCTAssertEqual(web.dnsOptions, ["ndots:2", "timeout:3"])
        XCTAssertEqual(web.shmSize, "128M")
        XCTAssertEqual(web.ulimits, ["nproc=512:512", "nofile=1024:2048"])
        XCTAssertEqual(web.macAddress, "02:42:ac:11:00:02")
        XCTAssertEqual(web.stopSignal, "SIGQUIT")
        XCTAssertEqual(web.stopGracePeriod, 90)
        XCTAssertEqual(web.pullPolicy, .always)

        XCTAssertEqual(web.volumes.count, 3)
        XCTAssertEqual(web.volumes[0], ComposeVolumeMount(kind: .anonymous, source: "", target: "/data"))
        XCTAssertEqual(web.volumes[1], ComposeVolumeMount(kind: .anonymous, source: "", target: "/cache", readOnly: true))
        XCTAssertEqual(web.volumes[2].kind, .tmpfs)
        XCTAssertEqual(web.volumes[2].target, "/scratch")
        XCTAssertEqual(web.volumes[2].source, "size=10m,mode=1777")

        XCTAssertEqual(web.postStart, [
            ComposeHook(command: ["echo", "started"], environment: [EnvVar(key: "STAGE", value: "boot")], workingDir: "/app", user: "root"),
            ComposeHook(command: ["sh", "-c", "touch /tmp/ready"])
        ])
        XCTAssertEqual(web.preStop, [ComposeHook(command: ["nginx", "-s", "quit"])])
    }

    func testDNSKeysAcceptOneValueOrAList() throws {
        let project = try parseGaps("""
        services:
          a:
            image: alpine
            dns: 9.9.9.9
            dns_search: [one.test, two.test]
        """)
        let a = try XCTUnwrap(project.service("a"))
        XCTAssertEqual(a.dns, ["9.9.9.9"])
        XCTAssertEqual(a.dnsSearch, ["one.test", "two.test"])
        let options = try XCTUnwrap(ComposePlanner.plan(project).service("a")).options
        XCTAssertEqual(options.dnsServers, ["9.9.9.9"])
        XCTAssertEqual(options.dnsSearch, ["one.test", "two.test"])
    }

    func testNewKeysAreNoLongerReportedAsNotBuilt() throws {
        let project = try parseGaps(fullYAML)
        for key in ["user", "tmpfs", "read_only", "init", "cap_add", "cap_drop", "dns", "dns_search", "dns_opt",
                    "shm_size", "ulimits", "mac_address", "stop_signal", "stop_grace_period", "pull_policy", "post_start", "pre_stop"] {
            XCTAssertFalse(project.problems.contains { $0.key == "services.web.\(key)" }, key)
        }
    }

    func testBadValuesAreFlaggedWithLines() throws {
        let project = try parseGaps("""
        services:
          web:
            image: nginx
            shm_size: lots
            stop_grace_period: soon
            tmpfs: relative/path
            pull_policy: sometimes
            ulimits:
              nofile: many
        """)
        func kind(_ key: String) -> ComposeProblem.Kind? { project.problems.first { $0.key == key }?.kind }
        XCTAssertEqual(kind("services.web.shm_size"), .invalid)
        XCTAssertEqual(kind("services.web.stop_grace_period"), .invalid)
        XCTAssertEqual(kind("services.web.tmpfs"), .invalid)
        XCTAssertEqual(kind("services.web.pull_policy"), .invalid)
        XCTAssertEqual(kind("services.web.ulimits.nofile"), .invalid)
        XCTAssertEqual(project.problems.first { $0.key == "services.web.shm_size" }?.line, 4)
    }

    func testPullPolicyValues() throws {
        let project = try parseGaps("""
        services:
          a: {image: alpine, pull_policy: if_not_present}
          b: {image: alpine, pull_policy: never}
          c: {image: alpine, pull_policy: daily}
          d: {image: alpine, pull_policy: build}
          e: {build: ., pull_policy: build}
        """)
        XCTAssertEqual(project.service("a")?.pullPolicy, .missing)
        XCTAssertEqual(project.service("b")?.pullPolicy, .never)
        XCTAssertEqual(project.service("c")?.pullPolicy, .missing)
        XCTAssertEqual(project.problems.first { $0.key == "services.c.pull_policy" }?.kind, .notBuilt)
        XCTAssertEqual(project.problems.first { $0.key == "services.d.pull_policy" }?.kind, .invalid)
        XCTAssertNil(project.problems.first { $0.key == "services.e.pull_policy" })
    }

    func testPrivilegedHooksAreRefused() throws {
        let project = try parseGaps("""
        services:
          web:
            image: nginx
            post_start:
              - command: id
                privileged: true
            pre_stop:
              - user: root
        """)
        let privileged = try XCTUnwrap(project.problems.first { $0.key == "services.web.post_start.privileged" })
        XCTAssertEqual(privileged.kind, .invalid)
        XCTAssertEqual(privileged.line, 6)
        XCTAssertTrue(project.problems.contains { $0.key == "services.web.pre_stop" && $0.kind == .invalid })
        XCTAssertTrue(project.hasBlockingProblems)
    }

    func testNetworkMacAddressOnFirstNetwork() throws {
        let project = try parseGaps("""
        services:
          web:
            image: nginx
            networks:
              front:
                mac_address: "02:00:00:00:00:01"
        networks:
          front: {}
        """)
        XCTAssertTrue(project.problems.isEmpty, "\(project.problems)")
        XCTAssertEqual(project.service("web")?.macAddress, "02:00:00:00:00:01")
    }

    // MARK: Planner

    func testPlannerMapsRunOptionsAndFlags() throws {
        let plan = try ComposePlanner.plan(try parseGaps(fullYAML))
        let web = try XCTUnwrap(plan.service("web"))
        let o = web.options
        XCTAssertEqual(o.user, "101:101")
        XCTAssertTrue(o.readOnlyRootfs)
        XCTAssertTrue(o.useInit)
        XCTAssertEqual(o.tmpfs, ["/run", "/tmp:size=64m", "/scratch:size=10m,mode=1777"])
        XCTAssertEqual(o.capAdd, ["NET_ADMIN"])
        XCTAssertEqual(o.capDrop, ["ALL"])
        XCTAssertEqual(o.dnsServers, ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(o.dnsSearch, ["example.com"])
        XCTAssertEqual(o.dnsOptions, ["ndots:2", "timeout:3"])
        XCTAssertEqual(o.shmSize, "128M")
        XCTAssertEqual(o.ulimits, ["nproc=512:512", "nofile=1024:2048"])
        XCTAssertEqual(o.macAddress, "02:42:ac:11:00:02")
        XCTAssertEqual(o.labels[ComposeLabel.stopSignal], "SIGQUIT")
        XCTAssertEqual(o.labels[ComposeLabel.stopTimeout], "90")
        XCTAssertEqual(web.stopSignal, "SIGQUIT")
        XCTAssertEqual(web.stopTimeout, 90)

        let args = ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner()).runArguments(o)
        let joined = args.joined(separator: " ")
        for flag in ["--user 101:101", "--read-only", "--init", "--tmpfs /run", "--tmpfs /tmp:size=64m",
                     "--tmpfs /scratch:size=10m,mode=1777", "--cap-add NET_ADMIN", "--cap-drop ALL",
                     "--dns 1.1.1.1", "--dns 8.8.8.8", "--dns-search example.com", "--dns-option ndots:2",
                     "--shm-size 128M", "--ulimit nproc=512:512", "--ulimit nofile=1024:2048",
                     "--network gaps_default,mac=02:42:ac:11:00:02"] {
            XCTAssertTrue(joined.contains(flag), "missing \(flag) in \(joined)")
        }
    }

    func testAnonymousVolumeNaming() throws {
        let name = ComposePlanner.anonymousVolumeName(project: "shop", service: "db", target: "/var/lib/data")
        XCTAssertEqual(name, ComposePlanner.anonymousVolumeName(project: "shop", service: "db", target: "/var/lib/data"))
        XCTAssertTrue(name.hasPrefix("shop_db_anon_"))
        XCTAssertEqual(name.count, "shop_db_anon_".count + 8)
        XCTAssertNotEqual(name, ComposePlanner.anonymousVolumeName(project: "shop", service: "db", target: "/other"))
        XCTAssertNotEqual(name, ComposePlanner.anonymousVolumeName(project: "shop", service: "web", target: "/var/lib/data"))
        XCTAssertNotEqual(name, ComposePlanner.anonymousVolumeName(project: "shop2", service: "db", target: "/var/lib/data"))
        // Apple's volume name rule.
        XCTAssertNotNil(name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression))
        XCTAssertNotNil(ComposePlanner.anonymousVolumeName(project: "p", service: "Web.App", target: "/x")
            .range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression))
    }

    func testAnonymousVolumesArePlannedAndMounted() throws {
        let plan = try ComposePlanner.plan(try parseGaps(fullYAML))
        let data = ComposePlanner.anonymousVolumeName(project: "gaps", service: "web", target: "/data")
        let cache = ComposePlanner.anonymousVolumeName(project: "gaps", service: "web", target: "/cache")
        XCTAssertEqual(Set(plan.volumes.map(\.name)), [data, cache])
        let volume = try XCTUnwrap(plan.volumes.first { $0.name == data })
        XCTAssertFalse(volume.external)
        XCTAssertEqual(volume.labels[ComposeLabel.project], "gaps")
        XCTAssertEqual(volume.labels[ComposeLabel.anonymousVolume], "web")
        let mounts = try XCTUnwrap(plan.service("web")).options.mounts
        XCTAssertEqual(mounts.map(\.source), [data, cache])
        XCTAssertEqual(mounts.map(\.destination), ["/data", "/cache"])
        XCTAssertEqual(mounts.map(\.kind), [.volume, .volume])
        XCTAssertEqual(mounts.map(\.readOnly), [false, true])
        // The same file planned again gives the same names, so a second Up reuses them.
        let again = try ComposePlanner.plan(try parseGaps(fullYAML))
        XCTAssertEqual(again.volumes.map(\.name), plan.volumes.map(\.name))
    }

    func testConfigHashCountsRunFlagsButNotStopSettings() throws {
        func hash(_ extra: String) throws -> String {
            let project = try parseGaps("services:\n  web:\n    image: nginx\n" + extra)
            return try XCTUnwrap(ComposePlanner.plan(project).service("web")).configHash
        }
        let base = try hash("")
        XCTAssertNotEqual(base, try hash("    user: \"1000\"\n"))
        XCTAssertNotEqual(base, try hash("    dns: [1.1.1.1]\n"))
        XCTAssertNotEqual(base, try hash("    read_only: true\n"))
        XCTAssertEqual(base, try hash("    stop_signal: SIGINT\n"))
        XCTAssertEqual(base, try hash("    stop_grace_period: 20s\n"))
        XCTAssertEqual(base, try hash("    post_start:\n      - command: echo hi\n"))
    }

    func testPlanCommandsIncludePostStartHooksAfterRun() throws {
        let plan = try ComposePlanner.plan(try parseGaps(fullYAML))
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner())
        let commands = plan.commands(runArguments: client.runArguments)
        let ids = commands.map(\.id)
        let run = try XCTUnwrap(ids.firstIndex(of: "run-web"))
        XCTAssertEqual(ids[run + 1], "post-start-web-0")
        XCTAssertEqual(ids[run + 2], "post-start-web-1")
        XCTAssertEqual(commands[run + 1].arguments,
                       ["exec", "--env", "STAGE=boot", "--workdir", "/app", "--user", "root", "gaps-web", "echo", "started"])
    }

    func testServiceSubsetBringsDependencies() throws {
        let project = try parseGaps("""
        services:
          db: {image: postgres}
          cache: {image: redis}
          api: {image: api, depends_on: [db]}
          web: {image: web, depends_on: [api]}
        """)
        let plan = try ComposePlanner.plan(project, settings: ComposePlanSettings(services: ["web"]))
        XCTAssertEqual(plan.services.map(\.name), ["db", "api", "web"])
        XCTAssertThrowsError(try ComposePlanner.plan(project, settings: ComposePlanSettings(services: ["nope"]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("nope"))
        }
    }

    // MARK: Runner decisions

    func testStopArguments() throws {
        let plan = try ComposePlanner.plan(try parseGaps(fullYAML))
        let web = try XCTUnwrap(plan.service("web"))
        let container = ContainerSummary(id: "gaps-web", name: "gaps-web", image: "nginx", state: .running)
        XCTAssertEqual(ComposeRunner.stopArguments(container, plan: web), ["stop", "--signal", "SIGQUIT", "--time", "90", "gaps-web"])

        let labelled = ContainerSummary(id: "x", name: "x", image: "i", state: .running,
                                        labels: [ComposeLabel.stopSignal: "SIGTERM", ComposeLabel.stopTimeout: "3"])
        XCTAssertEqual(ComposeRunner.stopArguments(labelled, plan: nil), ["stop", "--signal", "SIGTERM", "--time", "3", "x"])
        let plain = ContainerSummary(id: "y", name: "y", image: "i", state: .running)
        XCTAssertNil(ComposeRunner.stopArguments(plain, plan: nil))
    }

    func testImageActionHonoursPolicies() throws {
        let project = try parseGaps("""
        services:
          plain: {image: a}
          always: {image: b, pull_policy: always}
          never: {image: c, pull_policy: never}
          built: {build: .}
          rebuilt: {build: ., pull_policy: build}
        """)
        let plan = try ComposePlanner.plan(project)
        func action(_ name: String, has: Bool, _ options: ComposeRunner.UpOptions = .init()) throws -> ComposeRunner.ImageAction {
            ComposeRunner.imageAction(for: try XCTUnwrap(plan.service(name)), hasImage: has, options: options)
        }
        XCTAssertEqual(try action("plain", has: false), .pull)
        XCTAssertEqual(try action("plain", has: true), ComposeRunner.ImageAction.none)
        XCTAssertEqual(try action("always", has: true), .pull)
        XCTAssertEqual(try action("never", has: true), ComposeRunner.ImageAction.none)
        XCTAssertEqual(try action("never", has: false), .missingNeverPull)
        XCTAssertEqual(try action("built", has: false), .build)
        XCTAssertEqual(try action("built", has: true), ComposeRunner.ImageAction.none)
        XCTAssertEqual(try action("rebuilt", has: true), .build)
        // --pull for the whole Up wins over pull_policy.
        XCTAssertEqual(try action("never", has: true, .init(pull: .always)), .pull)
        XCTAssertEqual(try action("always", has: true, .init(pull: .never)), ComposeRunner.ImageAction.none)
        XCTAssertEqual(try action("plain", has: false, .init(pull: .never)), .missingNeverPull)
    }

    func testOrphanDetection() throws {
        let plan = try ComposePlanner.plan(try parseGaps("services:\n  web: {image: nginx}\n"))
        let containers = [
            fakeContainer("gaps-web", project: "gaps", service: "web"),
            fakeContainer("gaps-old", project: "gaps", service: "old"),
            fakeContainer("other-old", project: "other", service: "old"),
            ContainerSummary(id: "loose", name: "loose", image: "x", state: .running)
        ]
        XCTAssertEqual(ComposeRunner.orphans(plan, containers: containers).map(\.id), ["gaps-old"])
    }

    func testDryRunEventsDescribeThePlan() throws {
        let plan = try ComposePlanner.plan(try parseGaps(fullYAML))
        let runner = ComposeRunner(client: ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner()))
        let orphan = fakeContainer("gaps-old", project: "gaps", service: "old")
        let events = runner.dryRunEvents(plan, options: .init(dryRun: true), containers: [orphan], networks: [], volumes: [], images: [])
        let text = events.map(\.message).joined(separator: "\n")
        XCTAssertTrue(text.contains("Dry run for gaps"), text)
        XCTAssertTrue(text.contains("Would create network gaps_default"), text)
        XCTAssertTrue(text.contains("Would create volume gaps_web_anon_"), text)
        XCTAssertTrue(text.contains("Would pull nginx:alpine"), text)
        XCTAssertTrue(text.contains("Would remove orphan gaps-old"), text)
        XCTAssertTrue(text.contains("Would create and start gaps-web"), text)
        XCTAssertTrue(text.contains("container run --detach --name gaps-web"), text)
        XCTAssertTrue(text.contains("Would run post_start hook: echo started"), text)
        XCTAssertTrue(text.contains("container exec --env STAGE=boot"), text)
        XCTAssertEqual(events.last?.kind, .success)
        // Orphan removal comes before the containers are made.
        let orphanIndex = try XCTUnwrap(events.firstIndex { $0.message.contains("Would remove orphan") })
        let createIndex = try XCTUnwrap(events.firstIndex { $0.message.contains("Would create and start") })
        XCTAssertLessThan(orphanIndex, createIndex)

        let kept = runner.dryRunEvents(plan, options: .init(dryRun: true, removeOrphans: false), containers: [orphan], networks: [], volumes: [], images: [])
        XCTAssertTrue(kept.contains { $0.message == "Would keep orphan gaps-old" })
    }

    func testDryRunOfAnUpToDateStack() throws {
        let plan = try ComposePlanner.plan(try parseGaps("services:\n  web: {image: nginx}\n"))
        let web = try XCTUnwrap(plan.service("web"))
        let runner = ComposeRunner(client: ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner()))
        let running = fakeContainer("gaps-web", project: "gaps", service: "web", hash: web.configHash)
        let events = runner.dryRunEvents(plan, options: .init(dryRun: true), containers: [running],
                                         networks: ["gaps_default"], volumes: [], images: ["nginx:latest"])
        XCTAssertEqual(events.filter { $0.kind == .step }.map(\.message), ["Dry run for gaps. Nothing is changed."])
        XCTAssertTrue(events.contains { $0.message == "Up to date" && $0.service == "web" })
    }

    // MARK: Runner against a fake CLI

    func testDryRunChangesNothing() async throws {
        let cli = FakeContainerCLI()
        cli.addContainer("gaps-old", labels: [ComposeLabel.project: "gaps", ComposeLabel.service: "old"])
        let runner = ComposeRunner(client: cli.client, pollInterval: 0.01)
        let plan = try ComposePlanner.plan(try parseGaps(fullYAML))
        let log = GapsEventLog()
        try await runner.up(plan, options: .init(dryRun: true), events: { log.add($0) })
        let verbs = cli.calls.map { $0.first ?? "" }
        XCTAssertTrue(verbs.allSatisfy { ["list", "inspect", "network", "volume", "image"].contains($0) }, "\(cli.calls)")
        XCTAssertFalse(cli.calls.contains { $0.contains("create") || $0.contains("pull") }, "\(cli.calls)")
        XCTAssertTrue(log.text.contains("Would remove orphan gaps-old"), log.text)
        XCTAssertEqual(cli.containerNames, ["gaps-old"])
    }

    func testUpOrderOrphansThenRunThenPostStart() async throws {
        let cli = FakeContainerCLI()
        cli.images = ["docker.io/library/alpine:latest"]
        cli.addContainer("hooks-gone", labels: [ComposeLabel.project: "hooks", ComposeLabel.service: "gone"])
        let project = try parseGaps("""
        name: hooks
        services:
          db:
            image: alpine
            post_start:
              - command: echo db-ready
          web:
            image: alpine
            depends_on: [db]
            volumes: [/data]
            post_start:
              - command: echo web-one
              - command: echo web-two
        """)
        let plan = try ComposePlanner.plan(project)
        let log = GapsEventLog()
        try await ComposeRunner(client: cli.client, pollInterval: 0.01).up(plan, events: { log.add($0) })

        let calls = cli.calls.map { $0.joined(separator: " ") }
        func index(_ prefix: String) throws -> Int {
            try XCTUnwrap(calls.firstIndex { $0.hasPrefix(prefix) }, "no call \(prefix) in\n\(calls.joined(separator: "\n"))")
        }
        let deleteOrphan = try index("delete --force hooks-gone")
        let runDB = try index("run --detach --name hooks-db")
        let hookDB = try index("exec hooks-db echo db-ready")
        let runWeb = try index("run --detach --name hooks-web")
        let hookOne = try index("exec hooks-web echo web-one")
        let hookTwo = try index("exec hooks-web echo web-two")
        XCTAssertLessThan(deleteOrphan, runDB)
        XCTAssertLessThan(runDB, hookDB)
        XCTAssertLessThan(hookDB, runWeb)
        XCTAssertLessThan(runWeb, hookOne)
        XCTAssertLessThan(hookOne, hookTwo)
        // Anonymous volume made once with the project label.
        let anon = ComposePlanner.anonymousVolumeName(project: "hooks", service: "web", target: "/data")
        XCTAssertTrue(calls.contains { $0.hasPrefix("volume create") && $0.hasSuffix(anon) && $0.contains("com.containerdeck.compose.project=hooks") }, calls.joined(separator: "\n"))
        XCTAssertTrue(log.events.contains { $0.kind == .output && $0.message == "ran echo web-two" && $0.service == "web" })
        XCTAssertEqual(Set(cli.containerNames), ["hooks-db", "hooks-web"])

        // Second Up reuses the volume and runs no hooks for running services.
        let before = cli.calls.count
        try await ComposeRunner(client: cli.client, pollInterval: 0.01).up(plan, events: { _ in })
        let second = cli.calls.dropFirst(before).map { $0.joined(separator: " ") }
        XCTAssertFalse(second.contains { $0.hasPrefix("volume create") }, second.joined(separator: "\n"))
        XCTAssertFalse(second.contains { $0.contains("echo web-one") }, second.joined(separator: "\n"))
    }

    func testKeepOrphansLeavesThem() async throws {
        let cli = FakeContainerCLI()
        cli.images = ["docker.io/library/alpine:latest"]
        cli.addContainer("keep-gone", labels: [ComposeLabel.project: "keep", ComposeLabel.service: "gone"])
        let plan = try ComposePlanner.plan(try parseGaps("name: keep\nservices:\n  web: {image: alpine}\n"))
        let log = GapsEventLog()
        try await ComposeRunner(client: cli.client, pollInterval: 0.01).up(plan, options: .init(removeOrphans: false), events: { log.add($0) })
        XCTAssertTrue(cli.containerNames.contains("keep-gone"))
        XCTAssertTrue(log.events.contains { $0.kind == .warning && $0.message.contains("keep-gone") })
    }

    func testFailedPostStartHookFailsUp() async throws {
        let cli = FakeContainerCLI()
        cli.images = ["docker.io/library/alpine:latest"]
        cli.failingCommands = ["false"]
        let plan = try ComposePlanner.plan(try parseGaps("""
        name: fail
        services:
          web:
            image: alpine
            post_start:
              - command: "false"
          later:
            image: alpine
            depends_on: [web]
        """))
        let log = GapsEventLog()
        do {
            try await ComposeRunner(client: cli.client, pollInterval: 0.01).up(plan, events: { log.add($0) })
            XCTFail("Up should fail when a post_start hook fails")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("post_start hook of web failed with exit code 3"), error.localizedDescription)
        }
        XCTAssertFalse(cli.containerNames.contains("fail-later"))
        XCTAssertEqual(log.events.last?.kind, .failure)
    }

    func testNeverPullFailsWhenTheImageIsMissing() async throws {
        let cli = FakeContainerCLI()
        let plan = try ComposePlanner.plan(try parseGaps("name: np\nservices:\n  web: {image: alpine, pull_policy: never}\n"))
        do {
            try await ComposeRunner(client: cli.client, pollInterval: 0.01).up(plan, events: { _ in })
            XCTFail("Up should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("pull policy is never"), error.localizedDescription)
        }
        XCTAssertFalse(cli.calls.contains { $0.first == "run" })
    }

    func testDownRunsPreStopThenStopsWithSignal() async throws {
        let cli = FakeContainerCLI()
        cli.images = ["docker.io/library/nginx:alpine"]
        let plan = try ComposePlanner.plan(try parseGaps(fullYAML))
        let runner = ComposeRunner(client: cli.client, pollInterval: 0.01)
        try await runner.up(plan, events: { _ in })
        XCTAssertTrue(cli.networks.contains("gaps_default"))

        let before = cli.calls.count
        try await runner.down(project: "gaps", removeVolumes: true, keepNetworks: true, plan: plan, events: { _ in })
        let calls = cli.calls.dropFirst(before).map { $0.joined(separator: " ") }
        let preStop = try XCTUnwrap(calls.firstIndex { $0 == "exec gaps-web nginx -s quit" }, calls.joined(separator: "\n"))
        let stop = try XCTUnwrap(calls.firstIndex { $0 == "stop --signal SIGQUIT --time 90 gaps-web" }, calls.joined(separator: "\n"))
        XCTAssertLessThan(preStop, stop)
        XCTAssertTrue(cli.networks.contains("gaps_default"), "keepNetworks keeps the network")
        XCTAssertTrue(cli.volumes.isEmpty, "down -v removes anonymous volumes: \(cli.volumes)")
        XCTAssertTrue(cli.containerNames.isEmpty)
    }

    func testStopAndRestartUseHooksAndSignal() async throws {
        let cli = FakeContainerCLI()
        cli.images = ["docker.io/library/nginx:alpine"]
        let plan = try ComposePlanner.plan(try parseGaps(fullYAML))
        let runner = ComposeRunner(client: cli.client, pollInterval: 0.01)
        try await runner.up(plan, events: { _ in })

        var before = cli.calls.count
        try await runner.restart(project: "gaps", plan: plan, events: { _ in })
        var calls = cli.calls.dropFirst(before).map { $0.joined(separator: " ") }
        let order = ["exec gaps-web nginx -s quit", "stop --signal SIGQUIT --time 90 gaps-web", "start gaps-web",
                     "exec --env STAGE=boot --workdir /app --user root gaps-web echo started"]
        let positions = try order.map { step in try XCTUnwrap(calls.firstIndex(of: step), "\(step) missing in\n\(calls.joined(separator: "\n"))") }
        XCTAssertEqual(positions, positions.sorted())

        before = cli.calls.count
        try await runner.stop(project: "gaps", plan: nil, events: { _ in })
        calls = cli.calls.dropFirst(before).map { $0.joined(separator: " ") }
        // Without a plan the labels still carry the stop settings.
        XCTAssertTrue(calls.contains("stop --signal SIGQUIT --time 90 gaps-web"), calls.joined(separator: "\n"))
    }

    // MARK: config and env files

    func testConfigWriterRoundTrips() throws {
        let project = try parseGaps(fullYAML)
        let yaml = ComposeConfigWriter.yaml(project)
        XCTAssertNotNil(try Yams.load(yaml: yaml))
        let again = try parseGaps(yaml)
        let problems = again.problems.filter { $0.key != "services.web.x-network-aliases" }
        XCTAssertTrue(problems.isEmpty, "\(problems)\n\(yaml)")
        let a = try XCTUnwrap(project.service("web"))
        let b = try XCTUnwrap(again.service("web"))
        XCTAssertEqual(b.user, a.user)
        XCTAssertEqual(b.dns, a.dns)
        XCTAssertEqual(b.dnsOptions, a.dnsOptions)
        XCTAssertEqual(b.capAdd, a.capAdd)
        XCTAssertEqual(b.postStart, a.postStart)
        XCTAssertEqual(b.preStop, a.preStop)
        XCTAssertEqual(b.stopGracePeriod, a.stopGracePeriod)
        XCTAssertEqual(b.containerName, "gaps-web")
        XCTAssertTrue(yaml.contains("gaps_web_anon_"), yaml)
    }

    func testEnvFilesReplaceDotEnv() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-compose-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "services:\n  web:\n    image: nginx:${TAG:-latest}\n".write(to: dir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try "TAG=from-dotenv\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "TAG=from-flag\n".write(to: dir.appendingPathComponent("prod.env"), atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("compose.yaml")
        XCTAssertEqual(try ComposeParser.load(file: file, processEnvironment: [:]).service("web")?.image, "nginx:from-dotenv")
        XCTAssertEqual(try ComposeParser.load(file: file, processEnvironment: [:], envFiles: [dir.appendingPathComponent("prod.env")]).service("web")?.image, "nginx:from-flag")
        XCTAssertThrowsError(try ComposeParser.load(file: file, processEnvironment: [:], envFiles: [dir.appendingPathComponent("missing.env")]))
    }
}

// MARK: - Helpers

func fakeContainer(_ id: String, project: String, service: String, hash: String? = nil, running: Bool = true) -> ContainerSummary {
    var labels = [ComposeLabel.project: project, ComposeLabel.service: service]
    if let hash { labels[ComposeLabel.configHash] = hash }
    return ContainerSummary(id: id, name: id, image: "nginx", state: running ? .running : .stopped, labels: labels)
}

final class GapsEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ComposeEvent] = []
    func add(_ event: ComposeEvent) { lock.lock(); items.append(event); lock.unlock() }
    var events: [ComposeEvent] { lock.lock(); defer { lock.unlock() }; return items }
    var text: String { events.map { "[\($0.kind.rawValue)] \($0.service.map { "\($0): " } ?? "")\($0.message)" }.joined(separator: "\n") }
}

/// A tiny stand-in for Apple's `container` CLI. Keeps containers, networks,
/// volumes and images in memory and answers with the JSON shapes the parser reads.
final class FakeContainerCLI: CommandRunning, CommandStreaming, @unchecked Sendable {
    struct FakeContainer {
        var id: String
        var image: String
        var labels: [String: String]
        var running: Bool
    }

    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var containers: [FakeContainer] = []
    var networks: Set<String> = ["default"]
    var volumes: Set<String> = []
    var volumeLabels: [String: [String: String]] = [:]
    var images: [String] = []
    /// Hook commands (joined with spaces) that exit with 3.
    var failingCommands: Set<String> = []

    var client: ContainerClient { ContainerClient(cliPath: "/fake/container", runner: self, streamer: self) }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    var containerNames: [String] { lock.lock(); defer { lock.unlock() }; return containers.map(\.id) }

    func addContainer(_ id: String, image: String = "docker.io/library/alpine:latest", labels: [String: String], running: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        containers.append(FakeContainer(id: id, image: image, labels: labels, running: running))
    }

    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        lock.lock(); recorded.append(arguments)
        if arguments.starts(with: ["image", "pull"]), let ref = arguments.last { images.append(ref) }
        lock.unlock()
        return AsyncThrowingStream { $0.finish() }
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        recorded.append(arguments)
        let ok = CommandResult(exitCode: 0, stdout: "", stderr: "")
        guard let verb = arguments.first else { return ok }
        switch verb {
        case "list":
            return CommandResult(exitCode: 0, stdout: containersJSON(), stderr: "")
        case "network":
            if arguments.dropFirst().first == "list" { return CommandResult(exitCode: 0, stdout: namesJSON(networks.sorted(), labels: [:]), stderr: "") }
            if arguments.dropFirst().first == "create", let name = arguments.last { networks.insert(name) }
            if arguments.dropFirst().first == "delete", let name = arguments.last { networks.remove(name) }
            return ok
        case "volume":
            switch arguments.dropFirst().first {
            case "list": return CommandResult(exitCode: 0, stdout: namesJSON(volumes.sorted(), labels: volumeLabels), stderr: "")
            case "create":
                if let name = arguments.last {
                    volumes.insert(name)
                    var labels: [String: String] = [:]
                    for (i, arg) in arguments.enumerated() where arg == "--label" && i + 1 < arguments.count {
                        let pair = arguments[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
                        if pair.count == 2 { labels[pair[0]] = pair[1] }
                    }
                    volumeLabels[name] = labels
                }
            case "delete", "rm":
                if let name = arguments.last { volumes.remove(name); volumeLabels[name] = nil }
            default: break
            }
            return ok
        case "image":
            if arguments.dropFirst().first == "list" { return CommandResult(exitCode: 0, stdout: imagesJSON(), stderr: "") }
            return ok
        case "run":
            var labels: [String: String] = [:]
            var name = ""
            var i = 1
            var image = ""
            let valueFlags: Set<String> = ["--name", "--label", "--env", "--publish", "--volume", "--mount", "--cpus", "--memory",
                                           "--network", "--workdir", "--entrypoint", "--platform", "--user", "--tmpfs", "--cap-add",
                                           "--cap-drop", "--dns", "--dns-search", "--dns-option", "--dns-domain", "--ulimit", "--shm-size"]
            while i < arguments.count {
                let arg = arguments[i]
                if arg == "--name" { name = arguments[i + 1] }
                if arg == "--label" {
                    let pair = arguments[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
                    if pair.count == 2 { labels[pair[0]] = pair[1] }
                }
                if valueFlags.contains(arg) { i += 2; continue }
                if arg.hasPrefix("-") { i += 1; continue }
                image = arg
                break
            }
            containers.append(FakeContainer(id: name, image: image, labels: labels, running: true))
            return CommandResult(exitCode: 0, stdout: name + "\n", stderr: "")
        case "start":
            if let id = arguments.last, let index = containers.firstIndex(where: { $0.id == id }) { containers[index].running = true }
            return ok
        case "stop":
            if let id = arguments.last, let index = containers.firstIndex(where: { $0.id == id }) { containers[index].running = false }
            return ok
        case "delete", "rm":
            if let id = arguments.last { containers.removeAll { $0.id == id } }
            return ok
        case "exec":
            // exec [--env X] [--workdir D] [--user U] <id> command...
            var i = 1
            while i < arguments.count, arguments[i].hasPrefix("-") { i += 2 }
            let command = arguments.dropFirst(i + 1)
            if command.first == "/bin/sh" { return ok }  // /etc/hosts update
            let text = command.joined(separator: " ")
            if failingCommands.contains(text) { return CommandResult(exitCode: 3, stdout: "", stderr: "boom") }
            return CommandResult(exitCode: 0, stdout: "ran \(text)\n", stderr: "")
        default:
            return ok
        }
    }

    private func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func containersJSON() -> String {
        json(containers.map { c -> [String: Any] in
            [
                "id": c.id,
                "configuration": [
                    "id": c.id,
                    "image": ["reference": c.image],
                    "labels": c.labels,
                    "platform": ["architecture": "arm64", "os": "linux"]
                ] as [String: Any],
                "status": [
                    "state": c.running ? "running" : "stopped",
                    "networks": c.running ? [["network": "default", "ipv4Address": "192.168.64.9/24", "hostname": c.id]] : []
                ] as [String: Any]
            ]
        })
    }

    private func namesJSON(_ names: [String], labels: [String: [String: String]]) -> String {
        json(names.map { name -> [String: Any] in
            ["id": name, "configuration": ["name": name, "labels": labels[name] ?? [:]] as [String: Any], "status": [String: Any]()]
        })
    }

    private func imagesJSON() -> String {
        json(images.map { ref -> [String: Any] in
            ["id": "abc", "configuration": ["name": ref, "descriptor": ["digest": "sha256:abc", "mediaType": "x", "size": 1] as [String: Any]] as [String: Any], "variants": [Any]()]
        })
    }
}

// MARK: - Live

/// The new compose features against the real `container` CLI: a post_start
/// hook, an anonymous volume, dns servers, and orphan removal on a second Up.
/// DECK_INTEGRATION=1 or DECK_LIVE_COMPOSE=1. Uses project deck-compose-live.
final class ComposeGapsLiveTests: XCTestCase {

    private var enabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["DECK_INTEGRATION"] == "1" || env["DECK_LIVE_COMPOSE"] == "1"
    }

    func testHooksAnonymousVolumeDNSAndOrphansAgainstRealCLI() async throws {
        try XCTSkipUnless(enabled, "Set DECK_INTEGRATION=1 or DECK_LIVE_COMPOSE=1 to run against the real CLI.")
        let client = ContainerClient(cliPath: "/usr/local/bin/container")
        let runner = ComposeRunner(client: client, pollInterval: 0.5)
        let file = URL(fileURLWithPath: "/tmp/deck-compose-live/compose.yaml")
        let first = try ComposeParser.parse("""
        name: deck-compose-live
        services:
          app:
            image: alpine:3.22
            command: ["sleep", "300"]
            dns: [9.9.9.9]
            dns_search: deck.test
            init: true
            stop_signal: SIGTERM
            stop_grace_period: 2s
            volumes:
              - /data
            post_start:
              - command: ["sh", "-c", "echo $$GREETING > /data/hook.txt"]
                environment:
                  GREETING: hello-hook
            pre_stop:
              - command: ["sh", "-c", "echo bye > /data/bye.txt"]
          extra:
            image: alpine:3.22
            command: ["sleep", "300"]
        """, file: file)
        XCTAssertTrue(first.problems.isEmpty, "\(first.problems)")
        let plan = try ComposePlanner.plan(first)
        let anon = ComposePlanner.anonymousVolumeName(project: "deck-compose-live", service: "app", target: "/data")

        addTeardownBlock {
            try? await runner.down(project: "deck-compose-live", removeVolumes: true, plan: plan, events: { _ in })
        }

        let log = GapsEventLog()
        do {
            try await runner.up(plan, events: { log.add($0) })
        } catch {
            XCTFail("up failed: \(error)\n\(log.text)")
            return
        }
        XCTAssertTrue(log.text.contains("post_start"), log.text)

        let hook = try await client.exec("deck-compose-live-app", ["cat", "/data/hook.txt"])
        XCTAssertEqual(hook.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello-hook")
        let resolv = try await client.exec("deck-compose-live-app", ["cat", "/etc/resolv.conf"])
        XCTAssertTrue(resolv.stdout.contains("9.9.9.9"), resolv.stdout)
        XCTAssertTrue(resolv.stdout.contains("deck.test"), resolv.stdout)
        let volumes = try await client.listVolumes()
        let volume = try XCTUnwrap(volumes.first { $0.name == anon }, "\(volumes.map(\.name))")
        XCTAssertEqual(volume.labels[ComposeLabel.project], "deck-compose-live")

        // Second Up without `extra`: the orphan goes, the anonymous volume stays.
        let second = try ComposeParser.parse("""
        name: deck-compose-live
        services:
          app:
            image: alpine:3.22
            command: ["sleep", "300"]
            dns: [9.9.9.9]
            dns_search: deck.test
            init: true
            stop_signal: SIGTERM
            stop_grace_period: 2s
            volumes:
              - /data
            post_start:
              - command: ["sh", "-c", "echo $$GREETING > /data/hook.txt"]
                environment:
                  GREETING: hello-hook
            pre_stop:
              - command: ["sh", "-c", "echo bye > /data/bye.txt"]
        """, file: file)
        let plan2 = try ComposePlanner.plan(second)
        let log2 = GapsEventLog()
        try await runner.up(plan2, events: { log2.add($0) })
        XCTAssertTrue(log2.text.contains("Removing orphan deck-compose-live-extra"), log2.text)
        XCTAssertTrue(log2.text.contains("Up to date"), log2.text)
        let names = try await runner.ps(project: "deck-compose-live").map(\.service)
        XCTAssertEqual(names, ["app"])

        // Recreate keeps the data in the anonymous volume and runs pre_stop first.
        try await runner.up(plan2, options: .init(forceRecreate: true), events: { _ in })
        let bye = try await client.exec("deck-compose-live-app", ["cat", "/data/bye.txt"])
        XCTAssertEqual(bye.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "bye")

        // Down -v removes the anonymous volume.
        try await runner.down(project: "deck-compose-live", removeVolumes: true, plan: plan2, events: { _ in })
        let after = try await client.listVolumes().map(\.name)
        XCTAssertFalse(after.contains(anon), "\(after)")
        let left = try await runner.ps(project: "deck-compose-live")
        XCTAssertTrue(left.isEmpty)
    }
}
