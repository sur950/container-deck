import XCTest
@testable import DeckCore

/// Compose v2: stacks found by other tools' labels, hash based re-up preview,
/// YAML syntax errors with line numbers and source excerpts.
final class PolishComposeTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/work/shop/compose.yaml")

    private let yaml = """
    name: shop
    services:
      web:
        image: nginx
        ports: ["8080:80"]
      db:
        image: postgres
      cache:
        image: redis
    """

    private func plan() throws -> ComposePlan {
        let project = try ComposeParser.parse(yaml, file: file, environment: [:], readFile: { _ in nil })
        return try ComposePlanner.plan(project, settings: ComposePlanSettings())
    }

    private func container(_ name: String, labels: [String: String], running: Bool = true) -> ContainerSummary {
        ContainerSummary(id: name, name: name, image: "x", state: running ? .running : .stopped, labels: labels)
    }

    func testDockerComposeLabelsMakeAStack() {
        let docker = [
            ComposeLabel.dockerProject: "blog",
            ComposeLabel.dockerService: "api",
            ComposeLabel.dockerWorkingDir: "/Users/me/blog",
            ComposeLabel.dockerConfigFiles: "compose.yaml,compose.override.yaml"
        ]
        let stacks = ComposeStack.group([
            container("blog-api-1", labels: docker),
            container("solo", labels: [:]),
            container("shop-web", labels: [ComposeLabel.project: "shop", ComposeLabel.service: "web", ComposeLabel.file: "/work/shop/compose.yaml"])
        ])
        XCTAssertEqual(stacks.map(\.name), ["blog", "shop"])
        XCTAssertEqual(stacks[0].origin, .docker)
        XCTAssertEqual(stacks[0].services.map(\.service), ["api"])
        XCTAssertEqual(stacks[0].file?.path, "/Users/me/blog/compose.yaml")
        XCTAssertEqual(stacks[1].origin, .deck)
        XCTAssertEqual(stacks[1].file?.path, "/work/shop/compose.yaml")
    }

    func testOwnLabelWinsOverDocker() {
        let labels = [ComposeLabel.project: "a", ComposeLabel.dockerProject: "b", ComposeLabel.service: "s", ComposeLabel.dockerService: "t"]
        XCTAssertEqual(ComposeLabel.projectName(labels), "a")
        XCTAssertEqual(ComposeLabel.serviceName(labels), "s")
        XCTAssertEqual(ComposeLabel.origin(labels), .deck)
        XCTAssertNil(ComposeLabel.projectName([ComposeLabel.dockerProject: "  "]))
        XCTAssertEqual(ComposeLabel.filePath([ComposeLabel.dockerConfigFiles: "/abs/compose.yml"]), "/abs/compose.yml")
    }

    func testReupChangesByConfigHash() throws {
        let plan = try plan()
        let web = try XCTUnwrap(plan.service("web"))
        let db = try XCTUnwrap(plan.service("db"))
        let containers = [
            container("shop-web", labels: [ComposeLabel.project: "shop", ComposeLabel.service: "web", ComposeLabel.configHash: web.configHash]),
            container("shop-db", labels: [ComposeLabel.project: "shop", ComposeLabel.service: "db", ComposeLabel.configHash: "old"]),
            container("other-web", labels: [ComposeLabel.project: "other", ComposeLabel.service: "cache", ComposeLabel.configHash: "x"])
        ]
        let changes = ComposeReup.changes(plan, containers: containers)
        XCTAssertEqual(changes["web"], .upToDate)
        XCTAssertEqual(changes["db"], .changed)
        XCTAssertEqual(changes["cache"], .new)
        XCTAssertEqual(ComposeReup.summary(changes), "1 changed, 1 new, 1 up to date")
        XCTAssertNotEqual(db.configHash, "old")

        let stopped = [container("shop-web", labels: [ComposeLabel.project: "shop", ComposeLabel.service: "web", ComposeLabel.configHash: web.configHash], running: false)]
        XCTAssertEqual(ComposeReup.changes(plan, containers: stopped)["web"], .willStart)
        XCTAssertEqual(ComposeReup.changes(plan, containers: stopped, forceRecreate: true)["web"], .changed)
    }

    func testDockerStartedServiceCountsAsChanged() throws {
        // A stack started by another tool has no config hash, so Up recreates it with ours.
        let plan = try plan()
        let containers = [container("shop-web-1", labels: [ComposeLabel.dockerProject: "shop", ComposeLabel.dockerService: "web"])]
        XCTAssertEqual(ComposeReup.changes(plan, containers: containers)["web"], .changed)
    }

    func testYAMLSyntaxErrorHasLine() {
        let broken = "services:\n  web:\n    image: nginx\n   ports: [80]\n"
        XCTAssertThrowsError(try ComposeParser.parse(broken, file: file)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Line 4, column"), message)
            XCTAssertEqual(ComposeYAMLIssue.line(in: message), 4)
        }
    }

    func testYAMLIssueMessage() {
        let issue = ComposeYAMLIssue(line: 3, column: 7, problem: "did not find expected key")
        XCTAssertEqual(issue.message, "Line 3, column 7: Did not find expected key.")
        XCTAssertNil(ComposeYAMLIssue.line(in: "no line here"))
    }

    func testParsedProblemsKeepLines() throws {
        let text = "services:\n  web:\n    image: nginx\n    privileged: true\n"
        let project = try ComposeParser.parse(text, file: file)
        let problem = try XCTUnwrap(project.problems.first { $0.key.contains("privileged") })
        XCTAssertEqual(problem.line, 4)
        let excerpt = ComposeSourceExcerpt.make(text, line: problem.line)
        XCTAssertEqual(excerpt.lines.map(\.number), [3, 4, 5])
        XCTAssertEqual(excerpt.lines.first { $0.isTarget }?.text, "    privileged: true")
        XCTAssertTrue(ComposeSourceExcerpt.make(text, line: 99).lines.isEmpty)
    }
}
