import XCTest
@testable import DeckCore

/// Records calls and stdin, and returns one canned result.
private final class HelperRecordingRunner: CommandRunning, @unchecked Sendable {
    var result: CommandResult
    private(set) var executable: String?
    private(set) var arguments: [String] = []
    private(set) var stdinText: String?

    init(result: CommandResult) {
        self.result = result
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        self.executable = executable
        self.arguments = arguments
        self.stdinText = stdin.map { String(decoding: $0, as: UTF8.self) }
        return result
    }
}

private func helperFiles(executables: Set<String>) -> FileSystem {
    FileSystem(
        fileExists: { executables.contains($0) },
        isExecutable: { executables.contains($0) },
        contentsOfDirectory: { _ in [] }
    )
}

final class CredentialHelperTests: XCTestCase {

    func testParsesConfigFile() throws {
        let json = """
        {
          "auths": { "https://index.docker.io/v1/": {}, "quay.io": {} },
          "credsStore": "osxkeychain",
          "credHelpers": { "us-docker.pkg.dev": "gcloud", "ghcr.io": "" }
        }
        """
        let config = try DockerConfigFile(data: Data(json.utf8))
        XCTAssertEqual(config.credsStore, "osxkeychain")
        XCTAssertEqual(config.credHelpers, ["us-docker.pkg.dev": "gcloud"])
        XCTAssertEqual(config.authServers, ["https://index.docker.io/v1/", "quay.io"])
    }

    func testBadConfigThrows() {
        XCTAssertThrowsError(try DockerConfigFile(data: Data("not json".utf8)))
        XCTAssertThrowsError(try DockerConfigFile(data: Data("[1, 2]".utf8)))
    }

    func testEmptyConfigHasNoSources() throws {
        let config = try DockerConfigFile(data: Data("{}".utf8))
        XCTAssertNil(config.credsStore)
        XCTAssertTrue(config.sources.isEmpty)
    }

    func testSourcesPreferCredHelpers() {
        let config = DockerConfigFile(
            credsStore: "desktop",
            credHelpers: ["https://index.docker.io/v1/": "osxkeychain", "us-docker.pkg.dev": "gcloud"],
            authServers: ["https://index.docker.io/v1/", "quay.io"]
        )
        let sources = config.sources
        XCTAssertEqual(sources.map(\.server), ["docker.io", "us-docker.pkg.dev", "quay.io"])
        XCTAssertEqual(sources.first { $0.server == "docker.io" }?.helper, "osxkeychain")
        XCTAssertEqual(sources.first { $0.server == "docker.io" }?.configKey, "https://index.docker.io/v1/")
        XCTAssertEqual(sources.first { $0.server == "quay.io" }?.helper, "desktop")
    }

    func testAuthsWithoutStoreGiveNoSources() {
        let config = DockerConfigFile(credsStore: nil, credHelpers: [:], authServers: ["quay.io"])
        XCTAssertTrue(config.sources.isEmpty)
    }

    func testRegistryHostNormalizing() {
        XCTAssertEqual(DockerConfigFile.registryHost(from: "https://index.docker.io/v1/"), "docker.io")
        XCTAssertEqual(DockerConfigFile.registryHost(from: "registry-1.docker.io"), "docker.io")
        XCTAssertEqual(DockerConfigFile.registryHost(from: "https://ghcr.io"), "ghcr.io")
        XCTAssertEqual(DockerConfigFile.registryHost(from: "http://localhost:5000/v2/"), "localhost:5000")
        XCTAssertEqual(DockerConfigFile.registryHost(from: "Quay.io"), "quay.io")
    }

    func testDefaultPathUsesDockerConfigEnv() {
        XCTAssertEqual(
            DockerConfigFile.defaultPath(environment: ["DOCKER_CONFIG": "/custom/dir"], home: "/Users/test"),
            "/custom/dir/config.json"
        )
        XCTAssertEqual(
            DockerConfigFile.defaultPath(environment: [:], home: "/Users/test"),
            "/Users/test/.docker/config.json"
        )
    }

    func testLocateSearchesPathThenExtras() {
        let inPath = DockerCredentialHelper(
            name: "osxkeychain",
            runner: HelperRecordingRunner(result: CommandResult(exitCode: 0, stdout: "")),
            files: helperFiles(executables: ["/my/bin/docker-credential-osxkeychain", "/opt/homebrew/bin/docker-credential-osxkeychain"]),
            pathEnv: "/usr/bin:/my/bin"
        )
        XCTAssertEqual(inPath.locate(), "/my/bin/docker-credential-osxkeychain")

        let inHomebrew = DockerCredentialHelper(
            name: "gcloud",
            runner: HelperRecordingRunner(result: CommandResult(exitCode: 0, stdout: "")),
            files: helperFiles(executables: ["/opt/homebrew/bin/docker-credential-gcloud"]),
            pathEnv: "/usr/bin:/bin"
        )
        XCTAssertEqual(inHomebrew.locate(), "/opt/homebrew/bin/docker-credential-gcloud")

        let missing = DockerCredentialHelper(
            name: "ecr-login",
            runner: HelperRecordingRunner(result: CommandResult(exitCode: 0, stdout: "")),
            files: helperFiles(executables: []),
            pathEnv: "/usr/bin"
        )
        XCTAssertNil(missing.locate())
    }

    func testLocateRejectsNamesWithSlash() {
        let helper = DockerCredentialHelper(
            name: "../evil",
            runner: HelperRecordingRunner(result: CommandResult(exitCode: 0, stdout: "")),
            files: helperFiles(executables: ["/usr/local/bin/docker-credential-../evil"]),
            pathEnv: ""
        )
        XCTAssertNil(helper.locate())
    }

    func testGetSendsServerOnStdin() async throws {
        let runner = HelperRecordingRunner(result: CommandResult(
            exitCode: 0,
            stdout: #"{"ServerURL":"https://index.docker.io/v1/","Username":"sam","Secret":"dckr_pat_123"}"#
        ))
        let helper = DockerCredentialHelper(
            name: "osxkeychain",
            runner: runner,
            files: helperFiles(executables: ["/usr/local/bin/docker-credential-osxkeychain"]),
            pathEnv: "/usr/bin"
        )
        let credential = try await helper.get(server: "https://index.docker.io/v1/")
        XCTAssertEqual(credential, DockerCredential(serverURL: "https://index.docker.io/v1/", username: "sam", secret: "dckr_pat_123"))
        XCTAssertEqual(runner.executable, "/usr/bin/env")
        XCTAssertEqual(runner.arguments.count, 3)
        XCTAssertEqual(runner.arguments.first, "PATH=/usr/bin:/usr/local/bin:/opt/homebrew/bin")
        XCTAssertEqual(Array(runner.arguments.dropFirst()), ["/usr/local/bin/docker-credential-osxkeychain", "get"])
        XCTAssertEqual(runner.stdinText, "https://index.docker.io/v1/\n")
    }

    func testGetFailsWhenHelperMissing() async {
        let helper = DockerCredentialHelper(
            name: "desktop",
            runner: HelperRecordingRunner(result: CommandResult(exitCode: 0, stdout: "")),
            files: helperFiles(executables: []),
            pathEnv: "/usr/bin"
        )
        do {
            _ = try await helper.get(server: "quay.io")
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("docker-credential-desktop"))
        }
    }

    func testGetFailsOnNonZeroExit() async {
        let helper = DockerCredentialHelper(
            name: "osxkeychain",
            runner: HelperRecordingRunner(result: CommandResult(exitCode: 1, stdout: "credentials not found in native keychain")),
            files: helperFiles(executables: ["/usr/local/bin/docker-credential-osxkeychain"]),
            pathEnv: ""
        )
        do {
            _ = try await helper.get(server: "quay.io")
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("credentials not found"))
        }
    }

    func testParseRejectsIdentityTokens() {
        XCTAssertThrowsError(try DockerCredentialHelper.parse(#"{"Username":"<token>","Secret":"abc"}"#, server: "docker.io"))
    }

    func testParseRejectsEmptySecretAndBadJSON() {
        XCTAssertThrowsError(try DockerCredentialHelper.parse(#"{"Username":"sam","Secret":""}"#, server: "docker.io"))
        XCTAssertThrowsError(try DockerCredentialHelper.parse("nope", server: "docker.io"))
    }

    func testParseFallsBackToServer() throws {
        let credential = try DockerCredentialHelper.parse(#"{"Username":"sam","Secret":"s3cret"}"#, server: "ghcr.io")
        XCTAssertEqual(credential.serverURL, "ghcr.io")
        XCTAssertEqual(credential.username, "sam")
    }
}
