import XCTest
@testable import DeckCore

/// The setup guide opens by itself once on the very first launch, and later only when
/// something compulsory is broken. A stopped service or an optional check never opens it.
final class SetupGuidePolicyTests: XCTestCase {
    private func report(_ overrides: [CheckID: CheckState] = [:]) -> SetupReport {
        let checks = CheckID.allCases.map { id in SetupCheck(id: id, state: overrides[id] ?? .ok("Fine")) }
        return SetupReport(checks: checks, cliPath: "/usr/local/bin/container", cliVersion: nil, serviceRunning: overrides[.service] == nil)
    }

    func testOpensOnceOnFirstLaunchEvenWhenEverythingIsFine() {
        XCTAssertTrue(SetupReport.shouldAutoOpenGuide(firstLaunch: true, report: report()))
    }

    func testStaysClosedOnLaterLaunchesWhenEverythingIsFine() {
        XCTAssertFalse(SetupReport.shouldAutoOpenGuide(firstLaunch: false, report: report()))
    }

    func testStoppedServiceDoesNotOpenIt() {
        let r = report([.service: .failed("The container service is stopped.")])
        XCTAssertFalse(SetupReport.shouldAutoOpenGuide(firstLaunch: false, report: r))
        XCTAssertTrue(r.blockingIssues.isEmpty)
    }

    func testMissingToolOpensIt() {
        let r = report([.cliInstalled: .missing("Not installed.")])
        XCTAssertTrue(SetupReport.shouldAutoOpenGuide(firstLaunch: false, report: r))
        XCTAssertEqual(r.blockingIssues.map(\.id), [.cliInstalled])
    }

    func testOldVersionAndMissingKernelOpenIt() {
        XCTAssertTrue(SetupReport.shouldAutoOpenGuide(firstLaunch: false, report: report([.cliVersion: .failed("Too old.")])))
        XCTAssertTrue(SetupReport.shouldAutoOpenGuide(firstLaunch: false, report: report([.kernel: .missing("No kernel.")])))
    }

    func testOptionalChecksNeverOpenIt() {
        let r = report([.dns: .missing("No domain."), .rosetta: .missing("Not installed."), .terminalCommand: .missing("Not linked.")])
        XCTAssertFalse(SetupReport.shouldAutoOpenGuide(firstLaunch: false, report: r))
    }

    func testChecksStillRunningDoNotOpenIt() {
        XCTAssertFalse(SetupReport.shouldAutoOpenGuide(firstLaunch: false, report: report([.kernel: .waiting("Checking")])))
        XCTAssertFalse(SetupReport.shouldAutoOpenGuide(firstLaunch: true, report: .empty), "nothing checked yet")
    }
}
