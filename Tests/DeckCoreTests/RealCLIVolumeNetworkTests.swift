import XCTest
@testable import DeckCore

/// Output recorded from Apple's `container` CLI 1.6.1 (macOS 27.2, Apple silicon).
enum RealCLIVolumeNetworkFixtures {
    /// `container volume list --format json`: sized, default (512 GB sparse) and `--opt size=1G`.
    static let volumeList = #"""
    [{"configuration":{"creationDate":"2026-11-05T12:24:45Z","driver":"local","format":"ext4","labels":{"a":"b","deck.test":"1"},"name":"deck-test-vol1","options":{"size":"512M"},"sizeInBytes":536870912,"source":"/Users/suresh/Library/Application Support/com.apple.container/volumes/deck-test-vol1/volume.img"},"id":"deck-test-vol1"},{"configuration":{"creationDate":"2026-11-05T12:24:45Z","driver":"local","format":"ext4","labels":{},"name":"deck-test-vol2","options":{},"sizeInBytes":549755813888,"source":"/Users/suresh/Library/Application Support/com.apple.container/volumes/deck-test-vol2/volume.img"},"id":"deck-test-vol2"},{"configuration":{"creationDate":"2026-11-05T12:24:45Z","driver":"local","format":"ext4","labels":{},"name":"deck-test-vol3","options":{"size":"1G"},"sizeInBytes":1073741824,"source":"/Users/suresh/Library/Application Support/com.apple.container/volumes/deck-test-vol3/volume.img"},"id":"deck-test-vol3"}]
    """#

    /// `container network list --format json`: `--subnet --label`, `--internal`,
    /// `--subnet-v6`, and the builtin default network.
    static let networkList = #"""
    [{"configuration":{"creationDate":"2026-11-05T12:25:16Z","ipv4Subnet":"192.168.200.0/24","labels":{"deck.test":"1"},"mode":"nat","name":"deck-test-net1","options":{},"plugin":"container-network-vmnet"},"id":"deck-test-net1","status":{"ipv4Gateway":"192.168.200.1","ipv4Subnet":"192.168.200.0/24","ipv6Subnet":"fdd1:7725:8159:12bf::/64"}},{"configuration":{"creationDate":"2026-11-05T12:25:16Z","labels":{},"mode":"hostOnly","name":"deck-test-net2","options":{},"plugin":"container-network-vmnet"},"id":"deck-test-net2","status":{"ipv4Gateway":"192.168.128.1","ipv4Subnet":"192.168.128.0/24","ipv6Subnet":"fdc5:d08f:33b5:2e9d::/64"}},{"configuration":{"creationDate":"2026-11-05T12:32:51Z","ipv4Subnet":"192.168.201.0/24","ipv6Subnet":"fd00:dec0::/64","labels":{"deck.test":"1"},"mode":"nat","name":"deck-test-net3","options":{},"plugin":"container-network-vmnet"},"id":"deck-test-net3","status":{"ipv4Gateway":"192.168.201.1","ipv4Subnet":"192.168.201.0/24","ipv6Subnet":"fd00:dec0::1/64"}},{"configuration":{"creationDate":"2026-11-05T10:42:13Z","labels":{"com.apple.container.resource.role":"builtin"},"mode":"nat","name":"default","options":{},"plugin":"container-network-vmnet"},"id":"default","status":{"ipv4Gateway":"192.168.64.1","ipv4Subnet":"192.168.64.0/24","ipv6Subnet":"fd3a:ea47:104a:c220::/64"}}]
    """#

    /// `container list --all --format json` and `container inspect` of a STOPPED container
    /// on network deck-test-net1 with volume deck-test-vol2. `status.networks` is empty,
    /// yet `network delete` and `volume delete` both refuse while it exists.
    static let stoppedContainer = #"""
    [{"configuration": {"capAdd": [], "capDrop": [], "creationDate": "2026-11-05T12:25:25Z", "dns": {"nameservers": [], "options": [], "searchDomains": []}, "id": "deck-test-netc", "image": {"descriptor": {"digest": "sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 9218}, "reference": "docker.io/library/alpine:latest"}, "initProcess": {"arguments": ["3600"], "environment": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"], "executable": "sleep", "rlimits": [], "supplementalGroups": [], "terminal": false, "user": {"id": {"gid": 0, "uid": 0}}, "workingDirectory": "/"}, "labels": {}, "mounts": [{"destination": "/v", "options": [], "source": "/Users/suresh/Library/Application Support/com.apple.container/volumes/deck-test-vol2/volume.img", "type": {"volume": {"cache": {"on": {}}, "format": "ext4", "name": "deck-test-vol2", "sync": {"fsync": {}}}}}], "networks": [{"network": "deck-test-net1", "options": {"hostname": "deck-test-netc", "mtu": 1280}}], "platform": {"architecture": "arm64", "os": "linux", "variant": "v8"}, "publishedPorts": [], "publishedSockets": [], "readOnly": false, "resources": {"cpuOverhead": 1, "cpus": 4, "memoryInBytes": 1073741824}, "rosetta": false, "runtimeHandler": "container-runtime-linux", "ssh": false, "sysctls": {}, "useInit": false, "virtualization": false}, "id": "deck-test-netc", "status": {"networks": [], "startedDate": "2026-11-05T12:25:26Z", "state": "stopped"}}]
    """#

    /// `container system property list --format json` (no config.toml).
    static let propertyList = #"""
    {"build":{"cpus":2,"image":"ghcr.io/apple/container-builder-shim/builder:0.13.2","memory":"2048mb","rosetta":true},"container":{"cpus":4,"memory":"1gb"},"dns":{},"kernel":{"binaryPath":"opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug","digest":"sha256:8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5","url":"https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst"},"machine":{"cpus":5,"homeMount":"rw","memory":"16gb","virtualization":false},"network":{},"registry":{"domain":"docker.io"},"vminit":{"image":"ghcr.io/apple/containerization/vminit:0.53.0"}}
    """#

    /// `container system dns list` and `--format json` with no domains.
    static let dnsTableEmpty = "DOMAIN\n"
    static let dnsJSONEmpty = "[]\n"
    /// `--format json` renders `domains.map { $0.pqdn }` (DNSList.swift).
    static let dnsJSON = #"["test","dev.local"]"#

    /// `container registry list` with no logins, table and JSON.
    static let registryTableEmpty = "HOSTNAME  USERNAME  MODIFIED  CREATED\n"
    static let registryJSONEmpty = "[]\n"
    /// Shape of RegistryResource (id, name, username, creationDate, modificationDate, labels).
    /// A login to docker.io is stored as registry-1.docker.io (Reference.resolveDomain).
    static let registryJSON = #"""
    [{"creationDate":"2026-11-05T12:00:00Z","id":"registry-1.docker.io","labels":{},"modificationDate":"2026-11-05T12:30:00Z","name":"registry-1.docker.io","username":"deckuser"},{"creationDate":"2026-11-05T12:00:00Z","id":"localhost:5000","labels":{},"modificationDate":"2026-11-05T12:00:00Z","name":"localhost:5000","username":"me"}]
    """#
}

private let cliPath = "/usr/local/bin/container"
private typealias Fx = RealCLIVolumeNetworkFixtures

private func ok(_ stdout: String) -> CommandResult {
    CommandResult(exitCode: 0, stdout: stdout)
}

final class RealCLIVolumeNetworkTests: XCTestCase {

    // MARK: Volumes

    func testVolumeListParsesRealOutput() throws {
        let volumes = try ContainerOutputParser.volumes(Fx.volumeList)
        XCTAssertEqual(volumes.map(\.name), ["deck-test-vol1", "deck-test-vol2", "deck-test-vol3"])
        XCTAssertEqual(volumes[0].sizeBytes, 536_870_912)
        XCTAssertEqual(volumes[0].labels, ["a": "b", "deck.test": "1"])
        XCTAssertEqual(volumes[1].sizeBytes, 549_755_813_888)
        XCTAssertEqual(volumes[2].sizeBytes, 1_073_741_824)
        XCTAssertEqual(volumes[0].backingPath, "/Users/suresh/Library/Application Support/com.apple.container/volumes/deck-test-vol1/volume.img")
        XCTAssertEqual(volumes[0].createdAt, DeckDate.parse("2026-11-05T12:24:45Z"))
        XCTAssertFalse(volumes[0].isAnonymous)
    }

    func testVolumeCreateArgumentsMatchCLI() {
        let client = ContainerClient(cliPath: cliPath, runner: MockRunner())
        XCTAssertEqual(
            client.volumeCreateArguments(name: "deck-test-vol1", size: "512M", labels: ["deck.test": "1", "a": "b"]),
            ["volume", "create", "-s", "512M", "--label", "a=b", "--label", "deck.test=1", "deck-test-vol1"]
        )
        XCTAssertEqual(client.volumeCreateArguments(name: "v"), ["volume", "create", "v"])
    }

    func testStoppedContainerCountsAsVolumeUser() async throws {
        let runner = MockRunner()
        runner.responses["volume list --format json"] = ok(Fx.volumeList)
        runner.responses["list --all --format json"] = ok(Fx.stoppedContainer)
        runner.responses["inspect deck-test-netc"] = ok(Fx.stoppedContainer)
        let volumes = try await ContainerClient(cliPath: cliPath, runner: runner).listVolumes()
        XCTAssertEqual(volumes.first { $0.name == "deck-test-vol2" }?.usedBy, ["deck-test-netc"])
        XCTAssertEqual(volumes.first { $0.name == "deck-test-vol1" }?.usedBy, [])
    }

    func testAllocatedBytesReadsSparseFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deck-test-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 1, count: 8192).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        let bytes = try XCTUnwrap(ContainerClient.allocatedBytes(atPath: url.path))
        XCTAssertGreaterThanOrEqual(bytes, 8192)
        XCTAssertLessThan(bytes, 1 << 30)
        XCTAssertNil(ContainerClient.allocatedBytes(atPath: nil))
        XCTAssertNil(ContainerClient.allocatedBytes(atPath: "/nonexistent/deck-test"))
    }

    // MARK: Networks

    func testNetworkListParsesRealOutput() throws {
        let networks = try ContainerOutputParser.networks(Fx.networkList)
        XCTAssertEqual(networks.map(\.name), ["deck-test-net1", "deck-test-net2", "deck-test-net3", "default"])

        let net1 = networks[0]
        XCTAssertEqual(net1.subnet, "192.168.200.0/24")
        XCTAssertEqual(net1.gateway, "192.168.200.1")
        XCTAssertFalse(net1.isInternal)
        XCTAssertEqual(net1.labels, ["deck.test": "1"])
        XCTAssertEqual(net1.ipv6Subnet, "fdd1:7725:8159:12bf::/64")
        XCTAssertEqual(net1.state, "running")
        XCTAssertFalse(net1.isBuiltin)

        XCTAssertTrue(networks[1].isInternal, "mode hostOnly is --internal")
        XCTAssertEqual(networks[1].subnet, "192.168.128.0/24")

        // The status IPv6 value carries the gateway address. The configured prefix wins.
        XCTAssertEqual(networks[2].ipv6Subnet, "fd00:dec0::/64")

        XCTAssertTrue(networks[3].isBuiltin)
        XCTAssertTrue(networks[3].isDefault)
    }

    func testNetworkCreateArgumentsMatchCLI() {
        let client = ContainerClient(cliPath: cliPath, runner: MockRunner())
        XCTAssertEqual(
            client.networkCreateArguments(name: "deck-test-net3", subnet: "192.168.201.0/24", subnetV6: "fd00:dec0::/64", internal: true, labels: ["deck.test": "1"]),
            ["network", "create", "--subnet", "192.168.201.0/24", "--subnet-v6", "fd00:dec0::/64", "--internal", "--label", "deck.test=1", "deck-test-net3"]
        )
        XCTAssertEqual(client.networkCreateArguments(name: "n", subnet: "", subnetV6: nil), ["network", "create", "n"])
    }

    func testStoppedContainerCountsAsAttachedToNetwork() async throws {
        let runner = MockRunner()
        runner.responses["network list --format json"] = ok(Fx.networkList)
        runner.responses["list --all --format json"] = ok(Fx.stoppedContainer)
        runner.responses["inspect deck-test-netc"] = ok(Fx.stoppedContainer)
        let networks = try await ContainerClient(cliPath: cliPath, runner: runner).listNetworks()
        XCTAssertEqual(networks.first { $0.name == "deck-test-net1" }?.attachedContainers, ["deck-test-netc"])
        XCTAssertEqual(networks.first { $0.name == "default" }?.attachedContainers, [])
    }

    // MARK: DNS

    func testDNSDomainsPreferJSON() async throws {
        let runner = MockRunner()
        runner.responses["system dns list --format json"] = ok(Fx.dnsJSON)
        let domains = try await ContainerClient(cliPath: cliPath, runner: runner).dnsDomains()
        XCTAssertEqual(domains, ["test", "dev.local"])
    }

    func testDNSDomainsFallBackToTable() async throws {
        let runner = MockRunner()
        runner.responses["system dns list"] = ok(Fx.dnsTableEmpty)
        let domains = try await ContainerClient(cliPath: cliPath, runner: runner).dnsDomains()
        XCTAssertEqual(domains, [])
    }

    func testDNSParserShapes() {
        XCTAssertEqual(ContainerOutputParser.dnsDomains(Fx.dnsJSONEmpty), [])
        XCTAssertEqual(ContainerOutputParser.dnsDomains(#"["test."]"#), ["test"])
        XCTAssertNil(ContainerOutputParser.dnsDomains(Fx.dnsTableEmpty))
    }

    func testDNSCreateArguments() {
        let client = ContainerClient(cliPath: cliPath, runner: MockRunner())
        XCTAssertEqual(client.dnsCreateArguments("test"), ["system", "dns", "create", "test"])
        XCTAssertEqual(client.dnsCreateArguments("test", localhost: "203.0.113.5"), ["system", "dns", "create", "--localhost", "203.0.113.5", "test"])
    }

    // MARK: Registries

    func testRegistryLoginsParseRealShape() {
        let logins = RegistryLogin.parseList(Fx.registryJSON) ?? []
        XCTAssertEqual(logins.map(\.server), ["registry-1.docker.io", "localhost:5000"])
        XCTAssertEqual(logins[0].displayHost, "docker.io")
        XCTAssertEqual(logins[0].username, "deckuser")
        XCTAssertTrue(logins[0].matches("docker.io"))
        XCTAssertTrue(logins[0].matches("https://index.docker.io/v1/"))
        XCTAssertFalse(logins[1].matches("docker.io"))
        XCTAssertEqual(logins[0].modifiedAt, DeckDate.parse("2026-11-05T12:30:00Z"))
        XCTAssertEqual(RegistryLogin.parseList(Fx.registryJSONEmpty), [])
        XCTAssertNil(RegistryLogin.parseList(Fx.registryTableEmpty))
    }

    func testRegistryListEmptyTableAndJSON() {
        XCTAssertEqual(ContainerOutputParser.registries(Fx.registryJSONEmpty), [])
        XCTAssertEqual(ContainerOutputParser.registries(Fx.registryTableEmpty), [])
        XCTAssertEqual(ContainerOutputParser.registries(Fx.registryJSON), ["registry-1.docker.io", "localhost:5000"])
    }

    func testRegistryLoginArguments() async throws {
        let runner = MockRunner()
        let client = ContainerClient(cliPath: cliPath, runner: runner)
        XCTAssertEqual(
            client.registryLoginArguments(server: "localhost:5000", username: "me", scheme: "http"),
            ["registry", "login", "--scheme", "http", "--username", "me", "--password-stdin", "localhost:5000"]
        )
        runner.responses["registry list --format json"] = ok(Fx.registryJSON)
        let logins = try await client.registryLogins()
        XCTAssertEqual(logins.count, 2)
    }

    // MARK: System properties and config.toml

    func testPropertyListFlattensRealOutput() throws {
        let properties = try ContainerOutputParser.systemProperties(Fx.propertyList)
        let map = Dictionary(uniqueKeysWithValues: properties.map { ($0.key, $0.value) })
        XCTAssertEqual(map["build.cpus"], "2")
        XCTAssertEqual(map["build.memory"], "2048mb")
        XCTAssertEqual(map["build.rosetta"], "true")
        XCTAssertEqual(map["container.memory"], "1gb")
        XCTAssertEqual(map["machine.homeMount"], "rw")
        XCTAssertEqual(map["machine.virtualization"], "false")
        XCTAssertEqual(map["registry.domain"], "docker.io")
        // Empty tables ([dns], [network]) have no keys until set.
        XCTAssertNil(map["dns.domain"])
        XCTAssertNotNil(properties.first { $0.key == "machine.cpus" }?.description)
    }

    func testConfigFileValueRoundTrip() {
        var text = ""
        text = SystemConfigFile.updating(text, key: "dns.domain", value: "test")
        text = SystemConfigFile.updating(text, key: "container.memory", value: "2g")
        text = SystemConfigFile.updating(text, key: "container.cpus", value: "6")
        XCTAssertEqual(SystemConfigFile.value(in: text, key: "dns.domain"), "test")
        XCTAssertEqual(SystemConfigFile.value(in: text, key: "container.memory"), "2g")
        XCTAssertEqual(SystemConfigFile.value(in: text, key: "container.cpus"), "6")
        XCTAssertNil(SystemConfigFile.value(in: text, key: "build.cpus"))
        XCTAssertEqual(SystemConfigFile.value(in: "[dns]\ndomain = \"a.b\" # note\n", key: "dns.domain"), "a.b")
        XCTAssertEqual(SystemConfigFile.value(in: "[build]\ncpus = 3 # note\n", key: "build.cpus"), "3")
    }

    func testConfigFileDefaultPathMatchesApple() {
        // PathUtils.BaseConfigPath.home: $XDG_CONFIG_HOME/container, else ~/.config/container.
        XCTAssertEqual(SystemConfigFile.defaultURL(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"]).path, "/tmp/xdg/container/config.toml")
        XCTAssertTrue(SystemConfigFile.defaultURL(environment: [:]).path.hasSuffix("/.config/container/config.toml"))
    }
}

/// Runs against the real CLI only when DECK_REAL_CLI=1. Creates and removes
/// deck-test-* resources. Never touches the default network.
final class RealCLILiveVolumeNetworkTests: XCTestCase {
    private var client: ContainerClient!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_REAL_CLI"] == "1", "Set DECK_REAL_CLI=1 to run against the real CLI")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cliPath), "container CLI not installed")
        client = ContainerClient(cliPath: cliPath)
    }

    func testVolumeLifecycle() async throws {
        let name = "deck-test-live-vol"
        try? await client.deleteVolume(name)
        try await client.createVolume(name: name, size: "64M", labels: ["deck.test": "1"])
        let listed = try await client.listVolumes()
        let volume = try XCTUnwrap(listed.first { $0.name == name })
        XCTAssertEqual(volume.sizeBytes, 64 * 1_048_576)
        XCTAssertEqual(volume.labels["deck.test"], "1")
        XCTAssertNotNil(ContainerClient.allocatedBytes(atPath: volume.backingPath))
        try await client.deleteVolume(name)
        let after = try await client.listVolumes()
        XCTAssertFalse(after.contains { $0.name == name })
    }

    func testNetworkLifecycle() async throws {
        let name = "deck-test-live-net"
        try? await client.deleteNetwork(name)
        try await client.createNetwork(name: name, subnet: "192.168.211.0/24", subnetV6: nil, internal: true, labels: ["deck.test": "1"])
        let listed = try await client.listNetworks()
        let network = try XCTUnwrap(listed.first { $0.name == name })
        XCTAssertEqual(network.subnet, "192.168.211.0/24")
        XCTAssertEqual(network.gateway, "192.168.211.1")
        XCTAssertTrue(network.isInternal)
        try await client.deleteNetwork(name)
        let after = try await client.listNetworks()
        XCTAssertFalse(after.contains { $0.name == name })
        XCTAssertTrue(after.contains { $0.name == "default" })
    }

    func testReadOnlyQueries() async throws {
        _ = try await client.dnsDomains()
        _ = try await client.registryLogins()
        let properties = try await client.systemProperties()
        XCTAssertTrue(properties.contains { $0.key == "registry.domain" })
    }
}
