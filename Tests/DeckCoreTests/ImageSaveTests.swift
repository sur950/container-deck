import XCTest
@testable import DeckCore

/// `container image save` fails with "content with digest …" for images pulled for one
/// platform only (the app's default). The client then saves this Mac's platform.
final class ImageSaveTests: XCTestCase {
    private let cli = "/usr/local/bin/container"
    private let file = URL(fileURLWithPath: "/tmp/deck-save-test.tar")
    private let ref = "docker.io/library/busybox:latest"

    func testPlainSaveWhenAllContentIsThere() async throws {
        let runner = MockRunner()
        runner.responses["image save --output \(file.path) \(ref)"] = CommandResult(exitCode: 0, stdout: "", stderr: "")
        try await ContainerClient(cliPath: cli, runner: runner).saveImage(ref, to: file)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertFalse(runner.calls[0].contains("--platform"))
    }

    func testRetriesWithHostPlatformWhenOtherPlatformsWereNotPulled() async throws {
        let runner = MockRunner()
        runner.responses["image save --output \(file.path) \(ref)"] = CommandResult(
            exitCode: 1, stdout: "",
            stderr: "Error: content with digest sha256:f97baa533a26513c453a362be331a43eb60214302f449c16571b23cea141dce4")
        runner.responses["image save --output \(file.path) --platform \(ImagePlatform.host) \(ref)"] = CommandResult(exitCode: 0, stdout: "", stderr: "")
        try await ContainerClient(cliPath: cli, runner: runner).saveImage(ref, to: file)
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(Array(runner.calls[1].suffix(3)), ["--platform", ImagePlatform.host, ref])
        XCTAssertTrue(runner.calls[1].contains("--platform"))
        XCTAssertTrue(runner.calls[1].contains(ImagePlatform.host))
    }

    func testOtherErrorsAreNotRetried() async {
        let runner = MockRunner()
        runner.responses["image save --output \(file.path) \(ref)"] = CommandResult(exitCode: 1, stdout: "", stderr: "Error: image not found")
        do {
            try await ContainerClient(cliPath: cli, runner: runner).saveImage(ref, to: file)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(runner.calls.count, 1)
        }
    }

    func testExplicitPlatformArguments() {
        let client = ContainerClient(cliPath: cli)
        XCTAssertEqual(client.saveImageArguments(ref, to: file, platform: "linux/amd64"),
                       ["image", "save", "--output", file.path, "--platform", "linux/amd64", ref])
        XCTAssertEqual(client.saveImageArguments(ref, to: file, platform: nil),
                       ["image", "save", "--output", file.path, ref])
    }
}
