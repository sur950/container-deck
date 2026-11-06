import XCTest
@testable import DeckCore

final class DomainsCertificateTests: XCTestCase {

    func testCAArguments() {
        let args = LocalCertificateAuthority.caArguments(key: "/k", certificate: "/c")
        XCTAssertEqual(Array(args.prefix(3)), ["req", "-x509", "-newkey"])
        XCTAssertTrue(args.contains("basicConstraints=critical,CA:TRUE,pathlen:0"))
        XCTAssertTrue(args.contains("/CN=\(DomainsConfig.caCommonName)/O=\(AppConfig.appName)"))
    }

    func testLeafExtensions() {
        let text = LocalCertificateAuthority.leafExtensions(name: "web.localhost")
        XCTAssertTrue(text.contains("subjectAltName=DNS:web.localhost"))
        XCTAssertTrue(text.contains("extendedKeyUsage=serverAuth"))
        XCTAssertLessThanOrEqual(DomainsConfig.leafValidityDays, 825)
    }

    func testSerialIsPositiveHex() {
        for _ in 0..<50 {
            let serial = LocalCertificateAuthority.randomSerial()
            XCTAssertTrue(serial.hasPrefix("0x"))
            XCTAssertEqual(serial.count, 34)
            let first = UInt8(serial.dropFirst(2).prefix(2), radix: 16)!
            XCTAssertLessThan(first, 0x80)
        }
    }

    func testTrustArgumentsTargetTheGivenKeychain() {
        let ca = LocalCertificateAuthority(directory: URL(fileURLWithPath: "/tmp/deck-v2-net-none"), runner: MockRunner())
        XCTAssertEqual(ca.trustArguments(keychain: "/tmp/k.keychain-db"),
                       ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", "/tmp/k.keychain-db", "/tmp/deck-v2-net-none/ca.pem"])
        // No CA file: only the trust setting is removed, nothing to delete by hash.
        XCTAssertEqual(ca.untrustArguments(keychain: "/tmp/k"), [["remove-trusted-cert", "/tmp/deck-v2-net-none/ca.pem"]])
        XCTAssertFalse(ca.exists)
        XCTAssertFalse(ca.isTrusted())
    }

    func testIdentityNeedsCA() async {
        let ca = LocalCertificateAuthority(directory: URL(fileURLWithPath: "/tmp/deck-v2-net-none"), runner: MockRunner())
        do {
            _ = try await ca.identity(for: "web.localhost")
            XCTFail("needs a CA first")
        } catch {}
        do {
            _ = try await ca.identity(for: "bad name")
            XCTFail("bad names are refused")
        } catch {}
    }

    /// Real openssl, real files in a temporary folder. Nothing touches a keychain.
    func testRealCertificateChain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-v2-net-ca-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ca = LocalCertificateAuthority(directory: dir)
        let made = try await ca.createIfNeeded()
        XCTAssertTrue(made)
        XCTAssertTrue(ca.exists)
        let again = try await ca.createIfNeeded()
        XCTAssertFalse(again)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("ca.key").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertFalse(ca.isTrusted(), "a new CA is never trusted by itself")
        XCTAssertEqual(ca.caFingerprint()?.count, 40)

        _ = try await ca.identity(for: "web.localhost")
        let leaf = ca.leafCertificateURL(for: "web.localhost")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leaf.path))
        // macOS checks the chain against our CA only (the -r anchor), with the SSL policy and name.
        let verify = try await ProcessRunner().run("/usr/bin/security", ["verify-cert", "-c", leaf.path, "-r", ca.caCertificateURL.path, "-p", "ssl", "-s", "web.localhost"])
        XCTAssertTrue(verify.succeeded, verify.stdout + verify.stderr)
        let wrongName = try await ProcessRunner().run("/usr/bin/security", ["verify-cert", "-c", leaf.path, "-r", ca.caCertificateURL.path, "-p", "ssl", "-s", "other.localhost"])
        XCTAssertFalse(wrongName.succeeded)

        try await ca.reset()
        XCTAssertFalse(ca.exists)
    }
}
