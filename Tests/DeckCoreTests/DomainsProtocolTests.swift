import XCTest
@testable import DeckCore

final class DomainsProtocolTests: XCTestCase {

    private func data(hex: String) -> Data {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    // MARK: SNI

    func testRealClientHelloGivesServerName() {
        let hello = data(hex: DomainsFixtures.curlClientHelloHex)
        XCTAssertEqual(TLSClientHello.parse(hello), .serverName("web.localhost"))
    }

    func testPartialClientHelloWaits() {
        let hello = data(hex: DomainsFixtures.curlClientHelloHex)
        XCTAssertEqual(TLSClientHello.parse(hello.prefix(3)), .needMoreData)
        XCTAssertEqual(TLSClientHello.parse(hello.prefix(100)), .needMoreData)
        XCTAssertEqual(TLSClientHello.parse(Data()), .needMoreData)
    }

    func testPlainHTTPIsNotTLS() {
        XCTAssertEqual(TLSClientHello.parse(Data("GET / HTTP/1.1\r\n".utf8)), .notTLS)
    }

    func testGarbageNeverCrashes() {
        for length in 0..<64 {
            var bytes = [UInt8](repeating: 0xFF, count: length)
            if length > 0 { bytes[0] = 0x16 }
            if length > 1 { bytes[1] = 0x03 }
            if length > 4 { bytes[3] = 0; bytes[4] = UInt8(max(0, length - 5)) }
            _ = TLSClientHello.parse(Data(bytes))
        }
        var random = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var bytes = (0..<Int.random(in: 5...300, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }
            bytes[0] = 0x16; bytes[1] = 0x03
            bytes[3] = UInt8((bytes.count - 5) >> 8); bytes[4] = UInt8((bytes.count - 5) & 0xFF)
            _ = TLSClientHello.parse(Data(bytes))
        }
    }

    func testClientHelloWithoutServerName() {
        // Minimal ClientHello: no session, one suite, null compression, no extensions.
        var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 1, count: 32) + [0x00, 0x00, 0x02, 0x13, 0x01, 0x01, 0x00]
        body += [0x00, 0x00]
        let handshake: [UInt8] = [0x01, 0x00, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
        let record: [UInt8] = [0x16, 0x03, 0x01, UInt8(handshake.count >> 8), UInt8(handshake.count & 0xFF)] + handshake
        XCTAssertEqual(TLSClientHello.parse(Data(record)), .noServerName)
    }

    // MARK: DNS

    private func query(_ name: String, type: UInt16) -> Data {
        var bytes: [UInt8] = [0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes += Array(label.utf8)
        }
        bytes += [0, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        return Data(bytes)
    }

    func testDNSAnswerForKnownName() throws {
        let question = try XCTUnwrap(AliasDNSMessage.parseQuery(query("A.Gateway.test", type: 1)))
        XCTAssertEqual(question.name, "a.gateway.test")
        XCTAssertEqual(question.id, 0xABCD)
        let reply = [UInt8](AliasDNSMessage.answer(question, known: true))
        XCTAssertEqual(Array(reply[0..<2]), [0xAB, 0xCD])
        XCTAssertEqual(reply[2] & 0x80, 0x80)       // response
        XCTAssertEqual(reply[3] & 0x0F, 0)          // no error
        XCTAssertEqual(reply[7], 1)                 // one answer
        XCTAssertEqual(Array(reply.suffix(4)), [127, 0, 0, 1])
    }

    func testDNSAnswerForUnknownAndIPv6() throws {
        let unknown = try XCTUnwrap(AliasDNSMessage.parseQuery(query("other.test", type: 1)))
        let reply = [UInt8](AliasDNSMessage.answer(unknown, known: false))
        XCTAssertEqual(reply[3] & 0x0F, 3)          // no such name
        XCTAssertEqual(reply[7], 0)

        let six = try XCTUnwrap(AliasDNSMessage.parseQuery(query("api.test", type: 28)))
        let sixReply = [UInt8](AliasDNSMessage.answer(six, known: true))
        XCTAssertEqual(sixReply[3] & 0x0F, 0)
        XCTAssertEqual(sixReply[7], 0)
    }

    func testDNSRejectsBadQueries() {
        XCTAssertNil(AliasDNSMessage.parseQuery(Data([1, 2, 3])))
        var response = [UInt8](query("api.test", type: 1)); response[2] |= 0x80
        XCTAssertNil(AliasDNSMessage.parseQuery(Data(response)))
        XCTAssertNil(AliasDNSMessage.parseQuery(query("api.test", type: 1).prefix(16)))
    }

    // MARK: Resolver files and pf

    func testResolverFileCommands() {
        XCTAssertEqual(AliasResolverFiles.path(for: "*.gateway.test"), "/etc/resolver/gateway.test")
        let install = AliasResolverFiles.installCommands(for: "*.gateway.test")
        XCTAssertEqual(install.count, 1)
        XCTAssertEqual(install[0][0], "/bin/sh")
        XCTAssertFalse(install[0][2].contains("\n"), "scripts pass through AppleScript on one line")
        XCTAssertEqual(Array(install[0][4...]), ["/etc/resolver/gateway.test", DomainsConfig.resolverMarker, "15353"])
        XCTAssertTrue(install[0][2].contains("belongs to another app"))
        let remove = AliasResolverFiles.removeCommands(for: "api.test")
        XCTAssertTrue(remove[0][2].contains("grep -qF"))
        XCTAssertEqual(remove[0][4], "/etc/resolver/api.test")
        XCTAssertTrue(AliasResolverFiles.isInstalled("api.test") { _ in AliasResolverFiles.contents() })
        XCTAssertFalse(AliasResolverFiles.isInstalled("api.test") { _ in "nameserver 1.1.1.1" })
    }

    func testResolverScriptRunsInShell() throws {
        // Runs the real script against a temporary folder instead of /etc/resolver.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-v2-net-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var command = AliasResolverFiles.installCommands(for: "api.test")[0]
        command[2] = command[2].replacingOccurrences(of: "mkdir -p /etc/resolver", with: "true")
            .replacingOccurrences(of: "killall -HUP mDNSResponder", with: "true")
        command[4] = dir.appendingPathComponent("api.test").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let text = try String(contentsOf: dir.appendingPathComponent("api.test"), encoding: .utf8)
        XCTAssertEqual(text, AliasResolverFiles.contents())

        // A file someone else wrote is left alone.
        let foreign = dir.appendingPathComponent("other.test")
        try "nameserver 10.0.0.1\n".write(to: foreign, atomically: true, encoding: .utf8)
        command[4] = foreign.path
        let second = Process()
        second.executableURL = URL(fileURLWithPath: command[0])
        second.arguments = Array(command.dropFirst())
        second.standardError = FileHandle.nullDevice
        try second.run()
        second.waitUntilExit()
        XCTAssertEqual(second.terminationStatus, 3)
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "nameserver 10.0.0.1\n")
    }

    func testPortRedirectRule() {
        XCTAssertEqual(PortRedirect.rule(), "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port 8443")
        let install = PortRedirect.installCommands(to: 9443)
        XCTAssertTrue(install[0][4].hasSuffix("port 9443"))
        XCTAssertEqual(install[0][5], "com.apple/250.ContainerDeck")
        XCTAssertEqual(PortRedirect.removeCommands(), [["/sbin/pfctl", "-a", "com.apple/250.ContainerDeck", "-F", "all"]])
        let boot = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(PortRedirect.isLikelyActive(installedAt: Date(timeIntervalSince1970: 2_000), bootTime: boot))
        XCTAssertFalse(PortRedirect.isLikelyActive(installedAt: Date(timeIntervalSince1970: 500), bootTime: boot))
        XCTAssertFalse(PortRedirect.isLikelyActive(installedAt: nil, bootTime: boot))
        XCTAssertLessThan(PortRedirect.bootTime(), Date())
    }

    // MARK: Domains

    func testHostAliasResolverParsing() {
        XCTAssertEqual(LocalDomain.localhostAddress(inResolver: DomainsFixtures.hostAliasResolver), "203.0.113.113")
        XCTAssertNil(LocalDomain.localhostAddress(inResolver: DomainsFixtures.plainResolver))
        XCTAssertNil(LocalDomain.localhostAddress(inResolver: "options localhost:999.1.1.1"))
        XCTAssertTrue(LocalDomain.isValidName("dev.local"))
        XCTAssertTrue(LocalDomain.isValidName("test"))
        XCTAssertFalse(LocalDomain.isValidName("bad_name"))
        XCTAssertTrue(LocalDomain.isIPv4("203.0.113.113"))
        XCTAssertFalse(LocalDomain.isIPv4("203.0.113"))
    }

    func testLocalDomainsReadHostAliases() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-v2-net-etc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try DomainsFixtures.hostAliasResolver.write(to: dir.appendingPathComponent("containerization.host.container.internal"), atomically: true, encoding: .utf8)
        try DomainsFixtures.plainResolver.write(to: dir.appendingPathComponent("containerization.test"), atomically: true, encoding: .utf8)
        let runner = MockRunner()
        runner.responses["system dns list --format json"] = CommandResult(exitCode: 0, stdout: #"["test","host.container.internal"]"#)
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: runner)
        let domains = try await client.localDomains(resolverDirectory: dir.path)
        XCTAssertEqual(domains, [
            LocalDomain(name: "host.container.internal", localhostAddress: "203.0.113.113"),
            LocalDomain(name: "test"),
        ])
    }

    func testHostAliasUsesPrivilegedLocalhostFlag() async throws {
        let runner = MockRunner()
        runner.responses.removeAll()
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: runner)
        _ = try? await client.createHostAlias("host.container.internal")
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call[0], "/usr/bin/osascript")
        XCTAssertTrue(call[2].contains("'system' 'dns' 'create' '--localhost' '203.0.113.113' 'host.container.internal'"))
        XCTAssertTrue(call[2].hasSuffix("with administrator privileges"))
        do {
            try await client.createHostAlias("x.test", address: "nope")
            XCTFail("bad address must throw")
        } catch {}
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testCleanDomainValue() {
        XCTAssertEqual(ContainerClient.cleanDomainValue("\"test\""), "test")
        XCTAssertNil(ContainerClient.cleanDomainValue("nil"))
        XCTAssertNil(ContainerClient.cleanDomainValue(" "))
        XCTAssertNil(ContainerClient.cleanDomainValue(nil))
    }
}
