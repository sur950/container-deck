import XCTest
@testable import ContainerDeck
import DeckCore

final class ComponentsSettingsTests: XCTestCase {
    func testSettingsDeepLink() {
        XCTAssertEqual(DeepLink(url: URL(string: "containerdeck://settings/components")!), .settings("components"))
        XCTAssertEqual(DeepLink(url: URL(string: "containerdeck://settings")!), .settings("general"))
        XCTAssertEqual(DeepLink.settings("components").url?.absoluteString, "containerdeck://settings/components")
    }

    private func row(_ id: String, _ name: String, target: String?) -> ComponentInfo {
        ComponentInfo(id: id, kind: .ollama, name: name, target: target, status: .updateAvailable)
    }

    func testNoticeSignatureChangesWithTheSetOfUpdates() {
        let a = [row("ollama", "Ollama", target: "0.40.15"), row("mlx", "MLX", target: "0.32.2")]
        let sameOtherOrder = [a[1], a[0]]
        XCTAssertEqual(ComponentsNotice.signature(a), ComponentsNotice.signature(sameOtherOrder))
        let newer = [row("ollama", "Ollama", target: "0.41.0"), a[1]]
        XCTAssertNotEqual(ComponentsNotice.signature(a), ComponentsNotice.signature(newer))
    }

    func testNoticeNames() {
        let rows = ["Ollama", "MLX", "Codex CLI", "Helm"].enumerated().map { row("\($0.offset)", $0.element, target: "1") }
        XCTAssertEqual(ComponentsNotice.names(Array(rows.prefix(1))), "Ollama")
        XCTAssertEqual(ComponentsNotice.names(Array(rows.prefix(2))), "Ollama and MLX")
        XCTAssertEqual(ComponentsNotice.names(Array(rows.prefix(3))), "Ollama, MLX and Codex CLI")
        XCTAssertEqual(ComponentsNotice.names(rows), "Ollama, MLX and 2 more")
    }

    // MARK: Not working

    private func broken(_ kind: ComponentKind, _ name: String, installed: String, failed: [String], target: String? = "1.7.1") -> ComponentInfo {
        var info = ComponentInfo(id: kind.rawValue, kind: kind, name: name, installed: installed, status: failed.isEmpty ? .upToDate : .notWorking)
        info.health = ComponentHealthReport(componentID: info.id, version: installed, checks: failed.enumerated().map {
            HealthCheck(id: "c\($0.offset)", title: $0.element, feature: $0.element, failure: "\($0.element) didn't work", outcome: .failed)
        })
        info.testedText = "1.7.x"
        info.matchesTested = false
        info.switchTarget = failed.isEmpty ? nil : target
        return info
    }

    func testContainerPromptOncePerVersionAndDontAskAgain() {
        var rules = HealthPromptRules()
        let row = broken(.container, "Apple container", installed: "1.8.0", failed: ["The Kubernetes cluster list"])
        XCTAssertTrue(rules.shouldShow(row))
        rules.noteShown(row)
        XCTAssertFalse(rules.shouldShow(row), "Once per version per launch")
        var newer = row
        newer.installed = "1.8.1"
        XCTAssertTrue(rules.shouldShow(newer), "A new version asks again")
        rules.skip(newer)
        XCTAssertFalse(HealthPromptRules(skippedVersion: rules.skippedVersion).shouldShow(newer), "Don't Ask Again holds for that version")
        XCTAssertTrue(HealthPromptRules(skippedVersion: "1.8.1").shouldShow(row), "...only for that version")
        // Only Apple container, only when something failed, only with a tested version to switch to.
        XCTAssertFalse(HealthPromptRules().shouldShow(broken(.ollama, "Ollama", installed: "1.0.0", failed: ["x"])))
        XCTAssertFalse(HealthPromptRules().shouldShow(broken(.container, "Apple container", installed: "1.8.0", failed: [])),
                       "No popup just because a version is untested")
        XCTAssertFalse(HealthPromptRules().shouldShow(broken(.container, "Apple container", installed: "1.7.1", failed: ["x"], target: nil)),
                       "No popup on the tested version")
        XCTAssertFalse(HealthPromptRules().shouldShow(nil))
    }

    func testDashboardHealthNotice() {
        let ollama = broken(.ollama, "Ollama", installed: "1.0.0", failed: ["The Ollama model list", "The list of loaded Ollama models"], target: "0.16.2")
        XCTAssertEqual(ComponentsNotice.healthTitle([ollama]), "The Ollama model list (and 1 more) didn't work with Ollama 1.0.0.")
        XCTAssertEqual(ComponentsNotice.healthDetail([ollama]), "It works with 0.16.2. Switch from Settings, Components.")
        let kubectl = broken(.kubectl, "kubectl", installed: "2.0.0", failed: ["Kubernetes port forwards"], target: "1.35.0")
        XCTAssertEqual(ComponentsNotice.healthTitle([ollama, kubectl]), "2 tools have features that didn't work")
        XCTAssertEqual(ComponentsNotice.healthDetail([ollama, kubectl]), "Ollama and kubectl. Each works with its tested version.")
        // Close hides it until another tool, version or failure shows up.
        var fixed = ollama
        fixed.health?.checks.removeLast()
        XCTAssertNotEqual(ComponentsNotice.healthSignature([ollama]), ComponentsNotice.healthSignature([fixed]))
        XCTAssertEqual(ComponentsNotice.healthSignature([ollama, kubectl]), ComponentsNotice.healthSignature([kubectl, ollama]))
    }

    func testInlineOfferText() {
        XCTAssertEqual(ComponentHealthNote.text(broken(.container, "Apple container", installed: "1.8.0", failed: ["The Kubernetes cluster list"])),
                       "The Kubernetes cluster list didn't work with Apple container 1.8.0. It works with 1.7.1.")
    }

    func testUpdatePromptSaysWhetherTheUpdateIsTested() {
        var row = ComponentInfo(id: "container", kind: .container, name: "Apple container", installed: "1.6.1", target: "99.0.0", status: .updateAvailable)
        XCTAssertTrue(PlatformUpdatePromptView.testedLine(row).contains("offers to switch back"))
        row.target = ComponentGate.tested(for: "container").map { $0.line.map(String.init).joined(separator: ".") + ".1" }
        XCTAssertTrue(PlatformUpdatePromptView.testedLine(row).hasPrefix("This version is tested"))
    }
}
