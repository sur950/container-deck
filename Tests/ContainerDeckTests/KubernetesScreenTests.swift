import XCTest
@testable import ContainerDeck
import DeckCore

final class KubernetesScreenTests: XCTestCase {

    func testCreateJobStepAndProgress() {
        var job = KubeCreateJob(options: KubeClusterOptions(name: "dev"))
        XCTAssertEqual(job.step, "Starting")
        XCTAssertNil(job.progress)
        job.lines = ["[1/4] Starting cluster [3s]"]
        XCTAssertEqual(job.step, "Starting cluster")
        XCTAssertEqual(job.progress ?? -1, 0.125, accuracy: 0.001)
        job.lines.append("[2/4] Running kubeadm init [24s]")
        XCTAssertEqual(job.step, "Running kubeadm init")
        XCTAssertEqual(job.progress ?? -1, 0.375, accuracy: 0.001)
        job.lines.append("dev")
        XCTAssertEqual(job.step, "Running kubeadm init")
    }

    @MainActor
    func testProgressLinesCollapse() {
        XCTAssertTrue(KubernetesStore.sameStep("[1/4] Starting cluster [3s]", "[1/4] Starting cluster [4s]"))
        XCTAssertFalse(KubernetesStore.sameStep("[1/4] Starting cluster [3s]", "[2/4] Running kubeadm init [5s]"))
        XCTAssertFalse(KubernetesStore.sameStep("plain", "plain"))
    }

    func testAges() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(KubeAge.text(nil, now: now), "-")
        XCTAssertEqual(KubeAge.text(now.addingTimeInterval(-45), now: now), "45s")
        XCTAssertEqual(KubeAge.text(now.addingTimeInterval(-600), now: now), "10m")
        XCTAssertEqual(KubeAge.text(now.addingTimeInterval(-3 * 3600), now: now), "3h")
        XCTAssertEqual(KubeAge.text(now.addingTimeInterval(-5 * 86400), now: now), "5d")
        XCTAssertEqual(KubeAge.text(now.addingTimeInterval(60), now: now), "0s")
    }

    func testHealthColorsAndTilde() {
        XCTAssertEqual(KubeHealthDot.color(.good), DS.running)
        XCTAssertEqual(KubeHealthDot.color(.bad), DS.danger)
        XCTAssertEqual(KubeconfigPopover.tilde(NSHomeDirectory() + "/.kube/config"), "~/.kube/config")
        XCTAssertEqual(KubeconfigPopover.tilde("/etc/x"), "/etc/x")
    }

    func testCommandHintsUseTheRealArguments() {
        let args = KubeCommands.createArguments(KubeClusterOptions(name: "dev", workers: 1, cni: .none))
        XCTAssertEqual(args, ["cluster", "create", "--name", "dev", "--cni", "NONE", "--workers", "1"])
    }
}
