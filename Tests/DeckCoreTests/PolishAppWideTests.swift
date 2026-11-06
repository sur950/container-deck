import XCTest
@testable import DeckCore

/// Pull from any registry, version mismatch rules, diagnostics text and redaction.
final class PolishAppWideTests: XCTestCase {

    // MARK: Pull references

    func testParseReferences() throws {
        let gh = try XCTUnwrap(PullReference.parse("ghcr.io/owner/app:1.2"))
        XCTAssertEqual(gh.registry, "ghcr.io")
        XCTAssertEqual(gh.repository, "owner/app")
        XCTAssertEqual(gh.tag, "1.2")
        XCTAssertEqual(gh.registryDisplayName, "GitHub")
        XCTAssertEqual(gh.canonical, "ghcr.io/owner/app:1.2")

        let hub = try XCTUnwrap(PullReference.parse("nginx"))
        XCTAssertNil(hub.registry)
        XCTAssertTrue(hub.isDockerHub)
        XCTAssertEqual(hub.canonical, "docker.io/library/nginx:latest")

        let local = try XCTUnwrap(PullReference.parse("localhost:5000/team/tool"))
        XCTAssertEqual(local.registry, "localhost:5000")
        XCTAssertNil(local.tag)

        let digest = try XCTUnwrap(PullReference.parse("quay.io/org/tool@sha256:" + String(repeating: "a", count: 64)))
        XCTAssertEqual(digest.registry, "quay.io")
        XCTAssertNotNil(digest.digest)
        XCTAssertTrue(digest.canonical.hasSuffix("@sha256:" + String(repeating: "a", count: 64)))
    }

    func testParseCleansPastedCommands() {
        XCTAssertEqual(PullReference.parse("docker pull ghcr.io/a/b:1")?.canonical, "ghcr.io/a/b:1")
        XCTAssertEqual(PullReference.parse("https://quay.io/a/b")?.registry, "quay.io")
    }

    func testRejectsBadReferences() {
        XCTAssertNil(PullReference.parse(""))
        XCTAssertNil(PullReference.parse("Upper/Case"))
        XCTAssertNil(PullReference.parse("two words"))
        XCTAssertNil(PullReference.parse("a//b"))
        XCTAssertNil(PullReference.parse("app@sha256:short"))
    }

    func testDirectPullDetection() {
        XCTAssertTrue(PullReference.looksLikeDirectPull("ghcr.io/a/b"))
        XCTAssertTrue(PullReference.looksLikeDirectPull("public.ecr.aws/x/y:1"))
        XCTAssertFalse(PullReference.looksLikeDirectPull("nginx"))
        XCTAssertFalse(PullReference.looksLikeDirectPull("docker.io/library/nginx"))
        XCTAssertFalse(PullReference.looksLikeDirectPull("search words"))
    }

    // MARK: Versions

    private let range = SemanticVersion(1, 4, 0)..<SemanticVersion(1, 7, 0)

    func testVersionVerdicts() {
        func verdict(_ cli: SemanticVersion?, _ daemon: SemanticVersion? = nil) -> VersionCompatibility.Verdict {
            VersionCompatibility(cliVersion: cli, daemonVersion: daemon ?? cli, minimum: SemanticVersion(0, 5, 0), supported: range).verdict
        }
        XCTAssertEqual(verdict(SemanticVersion(1, 6, 1)), .supported)
        XCTAssertEqual(verdict(SemanticVersion(1, 4, 0)), .supported)
        XCTAssertEqual(verdict(SemanticVersion(0, 4, 9)), .tooOld)
        XCTAssertEqual(verdict(SemanticVersion(1, 2, 0)), .olderThanTested)
        XCTAssertEqual(verdict(SemanticVersion(1, 7, 0)), .newerThanTested)
        XCTAssertEqual(verdict(SemanticVersion(1, 6, 1), SemanticVersion(1, 5, 0)), .serviceMismatch)
        XCTAssertEqual(verdict(nil), .unknown)
    }

    func testVersionScreenAndSteps() {
        let old = VersionCompatibility(cliVersion: SemanticVersion(0, 4, 0), daemonVersion: nil, minimum: SemanticVersion(0, 5, 0), supported: range)
        XCTAssertTrue(old.needsScreen)
        XCTAssertTrue(old.steps.contains { $0.link == VersionCompatibility.releasesURL })
        XCTAssertTrue(old.steps.contains { $0.command == "container system stop" })
        let newer = VersionCompatibility(cliVersion: SemanticVersion(1, 8, 0), daemonVersion: SemanticVersion(1, 8, 0), minimum: SemanticVersion(0, 5, 0), supported: range)
        XCTAssertFalse(newer.needsScreen)
        XCTAssertTrue(newer.hasIssue)
        XCTAssertEqual(newer.testedRangeText, "1.4.0 to 1.6.x")
        XCTAssertTrue(newer.message.contains("1.8.0"))
        let fine = VersionCompatibility(cliVersion: SemanticVersion(1, 6, 1), daemonVersion: SemanticVersion(1, 6, 1), minimum: SemanticVersion(0, 5, 0), supported: range)
        XCTAssertTrue(fine.steps.isEmpty)
        XCTAssertFalse(fine.hasIssue)
    }

    func testCopyHasNoLongDashesOrSemicolons() {
        let verdicts: [(SemanticVersion?, SemanticVersion?)] = [
            (SemanticVersion(0, 1, 0), nil), (SemanticVersion(1, 0, 0), nil), (SemanticVersion(2, 0, 0), nil),
            (SemanticVersion(1, 6, 1), SemanticVersion(1, 5, 0)), (nil, nil), (SemanticVersion(1, 6, 1), SemanticVersion(1, 6, 1))
        ]
        for (cli, daemon) in verdicts {
            let item = VersionCompatibility(cliVersion: cli, daemonVersion: daemon ?? cli, minimum: SemanticVersion(0, 5, 0), supported: range)
            let copy = ([item.title, item.message] + item.steps.map(\.text)).joined(separator: " ")
            XCTAssertFalse(copy.contains("\u{2014}") || copy.contains(";"), copy)
        }
    }

    // MARK: Diagnostics

    // Recorded: `container system status --format json` on 1.6.1.
    static let statusFixture = #"{"client":{"appName":"container","build":"release","commit":"aa8d76b44a834eee3ebf6a0bc577e376f65f6361","version":"1.6.1"},"host":{"architecture":"arm64","cpus":10,"operatingSystem":"Version 27.2 (Build 26B123)"},"paths":{"appRoot":"/Users/suresh/Library/Application Support/com.apple.container/","installRoot":"/usr/local/"},"resources":{"containersRunning":4,"containersTotal":5,"images":8},"server":{"appName":"container-apiserver","build":"release","commit":"aa8d76b44a834eee3ebf6a0bc577e376f65f6361","version":"1.6.1"},"status":"running"}"#

    func testParseSystemStatus() throws {
        let info = try XCTUnwrap(SystemStatusInfo.parse(Self.statusFixture))
        XCTAssertEqual(info.status, "running")
        XCTAssertEqual(info.clientVersion, "1.6.1")
        XCTAssertEqual(info.serverVersion, "1.6.1")
        XCTAssertEqual(info.containersRunning, 4)
        XCTAssertEqual(info.images, 8)
        XCTAssertEqual(info.installRoot, "/usr/local/")
        XCTAssertNil(SystemStatusInfo.parse("Error: not running"))
    }

    func testRedaction() {
        let text = """
        path /Users/alice/Library/x
        GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz123456
        Authorization: Bearer abcdef1234567890
        password: hunter2
        https://bob:secret@registry.example.com/v2
        key sk-abcdefghijklmnopqrstuvwx
        """
        let redacted = DiagnosticsRedactor.redact(text, home: "/Users/alice")
        XCTAssertTrue(redacted.contains("path ~/Library/x"))
        XCTAssertFalse(redacted.contains("ghp_"))
        XCTAssertFalse(redacted.contains("abcdef1234567890"))
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertFalse(redacted.contains("bob:secret"))
        XCTAssertFalse(redacted.contains("sk-abc"))
        XCTAssertTrue(redacted.contains("registry.example.com"))
    }

    func testReportText() {
        let compat = VersionCompatibility(cliVersion: SemanticVersion(1, 6, 1), daemonVersion: SemanticVersion(1, 6, 1))
        let report = DiagnosticsReport(
            date: Date(timeIntervalSince1970: 0),
            sections: [.init("App", [.init("App", "Deck 2.0"), .init("Data folder", "/Users/alice/Library/Application Support/com.apple.container/")])],
            errors: [DiagnosticsLog.Entry(date: Date(timeIntervalSince1970: 60), message: "pull failed token=abc123", source: "Images")],
            compatibility: compat
        )
        let text = report.text(home: "/Users/alice")
        XCTAssertTrue(text.contains("## App"))
        XCTAssertTrue(text.contains("Data folder: ~/Library/Application Support"))
        XCTAssertTrue(text.contains("[Images] pull failed token=<hidden>"))
        XCTAssertFalse(text.contains("abc123"))
        XCTAssertEqual(report.value("App"), "Deck 2.0")
    }

    func testErrorLogCapsAndMergesRepeats() {
        let log = DiagnosticsLog()
        let start = Date()
        log.record("same", date: start)
        log.record("same", date: start.addingTimeInterval(5))
        XCTAssertEqual(log.entries.count, 1)
        for index in 0..<(DiagnosticsLog.capacity + 10) {
            log.record("error \(index)")
        }
        XCTAssertEqual(log.entries.count, DiagnosticsLog.capacity)
        XCTAssertEqual(log.entries.last?.message, "error \(DiagnosticsLog.capacity + 9)")
        log.record(CancellationError())
        XCTAssertEqual(log.entries.last?.message, "error \(DiagnosticsLog.capacity + 9)")
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testCollectorWithMockRunner() async {
        let runner = MockRunner()
        runner.responses["--version"] = CommandResult(exitCode: 0, stdout: "container CLI version 1.6.1 (build: release, commit: aa8d76b)\n")
        runner.responses["system status --format json"] = CommandResult(exitCode: 0, stdout: Self.statusFixture)
        runner.responses["machine list --quiet"] = CommandResult(exitCode: 0, stdout: "dev\nbox\n")
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: runner)
        let context = DiagnosticsContext(appVersion: "2.0", appBuild: "7", cliPath: "/usr/local/bin/container", backend: nil)
        let report = await DiagnosticsCollector.collect(client: client, context: context)
        XCTAssertEqual(report.compatibility.verdict, .supported)
        XCTAssertEqual(report.value("Service"), "Running")
        XCTAssertEqual(report.value("Service version"), "1.6.1")
        XCTAssertEqual(report.value("Machines"), "2")
        XCTAssertTrue(report.value("Container command")?.hasPrefix("1.6.1") ?? false)
    }
}
