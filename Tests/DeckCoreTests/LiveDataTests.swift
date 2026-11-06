import XCTest
@testable import DeckCore

final class LiveDataTests: XCTestCase {

    private func container(_ id: String, _ state: ContainerRunState = .running, labels: [String: String] = [:], ip: String? = nil) -> ContainerSummary {
        ContainerSummary(id: id, name: id, image: "alpine", state: state, ipAddress: ip, labels: labels)
    }

    // MARK: Sequencing

    func testSequencerDropsOlderResults() {
        var sequencer = PollSequencer()
        let slowManual = sequencer.begin()
        let poll = sequencer.begin()
        XCTAssertTrue(sequencer.hasPending)
        // The newer poll lands first.
        XCTAssertTrue(sequencer.accept(poll))
        // The older manual refresh lands later and must be dropped.
        XCTAssertFalse(sequencer.accept(slowManual))
        XCTAssertFalse(sequencer.hasPending)
    }

    func testSequencerAcceptsInOrderAndNeverTwice() {
        var sequencer = PollSequencer()
        let first = sequencer.begin()
        XCTAssertTrue(sequencer.accept(first))
        XCTAssertFalse(sequencer.accept(first))
        let second = sequencer.begin()
        XCTAssertTrue(sequencer.accept(second))
        XCTAssertEqual(sequencer.applied, 2)
    }

    // MARK: Diff

    func testDiffFindsInsertRemoveUpdate() {
        let old = [container("a"), container("b"), container("c", .stopped)]
        let new = [container("a"), container("c", .running), container("d")]
        let change = ListDiff.diff(old: old, new: new)
        XCTAssertEqual(change.inserted, ["d"])
        XCTAssertEqual(change.removed, ["b"])
        XCTAssertEqual(change.updated, ["c"])
        XCTAssertFalse(change.reordered)
        XCTAssertTrue(change.changesMembership)
        XCTAssertFalse(change.isEmpty)
    }

    func testDiffSameListIsEmpty() {
        let list = [container("a"), container("b", .stopped)]
        let change = ListDiff.diff(old: list, new: list)
        XCTAssertTrue(change.isEmpty)
    }

    func testDiffSeesReorderAndFieldChanges() {
        let reordered = ListDiff.diff(old: [container("a"), container("b")], new: [container("b"), container("a")])
        XCTAssertTrue(reordered.reordered)
        XCTAssertTrue(reordered.updated.isEmpty)
        XCTAssertFalse(reordered.isEmpty)

        let ipChanged = ListDiff.diff(old: [container("a", ip: "1.1.1.1")], new: [container("a", ip: "1.1.1.2")])
        XCTAssertEqual(ipChanged.updated, ["a"])
        XCTAssertFalse(ipChanged.changesMembership)
    }

    func testRunningIDs() {
        let list = [container("a"), container("b", .stopped), container("c")]
        XCTAssertEqual(list.runningIDs, ["a", "c"])
    }

    // MARK: Subscriptions

    func testSubscriptionCounting() {
        var subs = SubscriptionSet()
        XCTAssertFalse(subs.isActive)
        let list = subs.acquire("list")
        let dashboard = subs.acquire("dashboard")
        XCTAssertEqual(subs.count, 2)
        XCTAssertNotEqual(list, dashboard)
        XCTAssertTrue(subs.release(list))
        XCTAssertTrue(subs.isActive)
        // Releasing twice does nothing.
        XCTAssertFalse(subs.release(list))
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.owners, ["dashboard"])
        XCTAssertTrue(subs.release(dashboard))
        XCTAssertFalse(subs.isActive)
        // Tokens are never reused.
        XCTAssertGreaterThan(subs.acquire("again"), dashboard)
    }

    func testSubscriptionUnknownTokenIgnored() {
        var subs = SubscriptionSet()
        _ = subs.acquire("menu")
        XCTAssertFalse(subs.release(999))
        XCTAssertEqual(subs.count, 1)
    }

    // MARK: Steady order

    func testStableOrderKeepsRowsForSmallChanges() {
        let band = StableOrder.band(absolute: 1, relative: 0.15)
        let first = StableOrder.order(previous: [], items: [("a", 5.0), ("b", 5.4), ("c", 1)], descending: true, threshold: band)
        XCTAssertEqual(first, ["b", "a", "c"])
        // a moves just above b: inside the band, no jump.
        let second = StableOrder.order(previous: first, items: [("a", 5.6), ("b", 5.2), ("c", 1)], descending: true, threshold: band)
        XCTAssertEqual(second, ["b", "a", "c"])
        // c shoots up: it moves to the top.
        let third = StableOrder.order(previous: second, items: [("a", 5.6), ("b", 5.2), ("c", 40)], descending: true, threshold: band)
        XCTAssertEqual(third, ["c", "b", "a"])
    }

    func testStableOrderAscendingAndMembershipChange() {
        let band = StableOrder.band(absolute: 0, relative: 0)
        let up = StableOrder.order(previous: ["a", "b"], items: [("a", 3), ("b", 1)], descending: false, threshold: band)
        XCTAssertEqual(up, ["b", "a"])
        // A new row: full sort.
        let added = StableOrder.order(previous: up, items: [("a", 3), ("b", 1), ("c", 2)], descending: false, threshold: band)
        XCTAssertEqual(added, ["b", "c", "a"])
        // Ties keep the given order on a full sort.
        let ties = StableOrder.order(previous: [], items: [("x", 1), ("y", 1), ("z", 1)], descending: true, threshold: band)
        XCTAssertEqual(ties, ["x", "y", "z"])
    }

    // MARK: Grouping

    func testGroupByComposeProject() {
        let list = [
            container("web", labels: [ComposeLabel.project: "shop"]),
            container("solo"),
            container("db", labels: [ComposeLabel.project: "shop"]),
            container("api", .stopped, labels: [ComposeLabel.project: "billing"])
        ]
        let groups = ContainerGroups.group(list, by: .composeProject)
        XCTAssertEqual(groups.map(\.title), ["billing", "shop", "Not in a project"])
        XCTAssertEqual(groups[1].containers.map(\.id), ["web", "db"])
        XCTAssertEqual(groups[1].runningCount, 2)
        XCTAssertEqual(groups[0].runningCount, 0)
        XCTAssertEqual(groups[2].containers.map(\.id), ["solo"])
    }

    func testGroupByLabelAndKeys() {
        let list = [
            container("a", labels: ["team": "red", "com.apple.container.plugin": "x"]),
            container("b", labels: ["team": "blue", "deck.helper": "1"]),
            container("c")
        ]
        XCTAssertEqual(ContainerGroups.labelKeys(list), ["team"])
        let groups = ContainerGroups.group(list, by: .label("team"))
        XCTAssertEqual(groups.map(\.title), ["blue", "red", "No team label"])
        XCTAssertEqual(ContainerGroups.group(list, by: .none).first?.containers.count, 3)
    }

    func testGroupingStorageRoundTrip() {
        for value in [ContainerGrouping.none, .composeProject, .label("team")] {
            XCTAssertEqual(ContainerGrouping(storageValue: value.storageValue), value)
        }
        XCTAssertEqual(ContainerGrouping(storageValue: "label:"), ContainerGrouping.none)
        XCTAssertEqual(ContainerGrouping(storageValue: "garbage"), ContainerGrouping.none)
    }

    // MARK: Commit and cheap lists

    func testCommitArguments() async throws {
        let runner = MockRunner()
        runner.responses["commit web my-app:v1"] = CommandResult(exitCode: 0, stdout: "", stderr: "")
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: runner)
        XCTAssertEqual(client.commitArguments("web", reference: " my-app:v1 "), ["commit", "web", "my-app:v1"])
        XCTAssertEqual(client.commandLine(client.commitArguments("web", reference: "my-app:v1")), "container commit web my-app:v1")
        try await client.commitContainer("web", reference: "my-app:v1")
        XCTAssertEqual(runner.calls.last, ["/usr/local/bin/container", "commit", "web", "my-app:v1"])
    }

    func testCommitRejectsBadNameWithoutRunning() async {
        let runner = MockRunner()
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: runner)
        do {
            try await client.commitContainer("web", reference: "My App")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(runner.calls.isEmpty)
        }
    }

    func testImageReferenceCheck() {
        XCTAssertNil(ImageReferenceCheck.problem("my-app"))
        XCTAssertNil(ImageReferenceCheck.problem("my-app:v1.2"))
        XCTAssertNil(ImageReferenceCheck.problem("ghcr.io/owner/app:latest"))
        XCTAssertNotNil(ImageReferenceCheck.problem("ghcr.io/Owner/app:latest"))
        XCTAssertNil(ImageReferenceCheck.problem("localhost:5000/team/app:dev"))
        XCTAssertNil(ImageReferenceCheck.problem("registry.example.com/app"))
        XCTAssertNotNil(ImageReferenceCheck.problem(""))
        XCTAssertNotNil(ImageReferenceCheck.problem("my app"))
        XCTAssertNotNil(ImageReferenceCheck.problem("MyApp:v1"))
        XCTAssertNotNil(ImageReferenceCheck.problem("app:"))
        XCTAssertNotNil(ImageReferenceCheck.problem("app:v1 beta"))
        XCTAssertNotNil(ImageReferenceCheck.problem("a//b"))
        XCTAssertNotNil(ImageReferenceCheck.problem(":v1"))
        XCTAssertEqual(ImageReferenceCheck.withDefaultTag("app"), "app:latest")
        XCTAssertEqual(ImageReferenceCheck.withDefaultTag("localhost:5000/app"), "localhost:5000/app:latest")
        XCTAssertEqual(ImageReferenceCheck.withDefaultTag("app:v1"), "app:v1")
    }

    func testCountsUseOnlyListCalls() async throws {
        let runner = MockRunner()
        runner.responses["volume list --format json"] = CommandResult(exitCode: 0, stdout: "[]", stderr: "")
        runner.responses["network list --format json"] = CommandResult(exitCode: 0, stdout: "[]", stderr: "")
        let client = ContainerClient(cliPath: "/c", runner: runner)
        let volumes = try await client.countVolumes()
        let networks = try await client.countNetworks()
        XCTAssertEqual(volumes, 0)
        XCTAssertEqual(networks, 0)
        // No `list` of containers and no `inspect`.
        XCTAssertEqual(runner.calls.map { $0.dropFirst().joined(separator: " ") }, ["volume list --format json", "network list --format json"])
    }
}
