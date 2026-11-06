import XCTest
import CryptoKit
@testable import DeckCore

/// Release and update signing without Apple's Developer Program:
/// Ed25519 signatures on the disk image, the self signed certificate check, the install
/// script and the release scripts.
final class UpdateSigningTests: XCTestCase {

    // A fixed test key. Never used for real releases.
    private let testKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
    private var testPublicKey: String { testKey.publicKey.rawRepresentation.base64EncodedString() }

    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deck-sign-\(UUID().uuidString).dmg")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sign(_ file: URL, with key: Curve25519.Signing.PrivateKey) throws -> String {
        try UpdateSignature.sign(digest: UpdateChecksum.sha256Digest(of: file), with: key)
    }

    private func release(_ names: [String]) -> AppRelease {
        let dir = URL(fileURLWithPath: "/nonexistent/deck-release")
        return AppRelease(version: ReleaseVersion(99, 0, 0), tagName: "v99.0.0", title: "", notes: "",
                          pageURL: URL(string: "https://github.com/\(AppConfig.repository)/releases")!,
                          publishedAt: nil, isPrerelease: false,
                          assets: names.map { ReleaseAsset(name: $0, url: dir.appendingPathComponent($0)) })
    }

    // MARK: Ed25519

    func testSignVerifyRoundTrip() throws {
        let dmg = try tempFile("a disk image")
        let signature = try sign(dmg, with: testKey)
        XCTAssertEqual(Data(base64Encoded: signature)?.count, 64)
        XCTAssertNoThrow(try UpdateSignature.verify(file: dmg, signatureText: signature, publicKey: testPublicKey))
        // Trailing newline and comments in the .sig file are fine.
        XCTAssertNoThrow(try UpdateSignature.verify(file: dmg, signatureText: "# sig\n\(signature)\n", publicKey: testPublicKey + "\n"))
        // The message is the raw SHA-256 digest of the file.
        let digest = try UpdateChecksum.sha256Digest(of: dmg)
        XCTAssertEqual(digest.count, 32)
        XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(), try UpdateChecksum.sha256(of: dmg))
        XCTAssertTrue(testKey.publicKey.isValidSignature(Data(base64Encoded: signature)!, for: digest))
    }

    func testTamperedDiskImageRejected() throws {
        let dmg = try tempFile("a disk image")
        let signature = try sign(dmg, with: testKey)
        try Data("a disk imagE".utf8).write(to: dmg)
        XCTAssertThrowsError(try UpdateSignature.verify(file: dmg, signatureText: signature, publicKey: testPublicKey)) { error in
            guard case .updateSignatureInvalid? = error as? UpdateInstallError else { return XCTFail("wrong error \(error)") }
        }
    }

    func testWrongKeyRejected() throws {
        let dmg = try tempFile("a disk image")
        let other = Curve25519.Signing.PrivateKey()
        let signature = try sign(dmg, with: other)
        XCTAssertThrowsError(try UpdateSignature.verify(file: dmg, signatureText: signature, publicKey: testPublicKey)) { error in
            guard case .updateSignatureInvalid? = error as? UpdateInstallError else { return XCTFail("wrong error \(error)") }
        }
        // A key that is not 32 bytes is refused.
        XCTAssertThrowsError(try UpdateSignature.verify(file: dmg, signatureText: signature, publicKey: "AAAA"))
    }

    func testMissingOrGarbageSignatureRejected() async throws {
        let dmg = try tempFile("a disk image")
        XCTAssertThrowsError(try UpdateSignature.verify(file: dmg, signatureText: nil, publicKey: testPublicKey)) { error in
            XCTAssertEqual(error as? UpdateInstallError, .updateSignatureMissing)
        }
        for garbage in ["", "not base64!", Data(repeating: 1, count: 63).base64EncodedString()] {
            XCTAssertThrowsError(try UpdateSignature.verify(file: dmg, signatureText: garbage, publicKey: testPublicKey))
        }
        XCTAssertNil(UpdateSignature.parseSignature("abc"))

        // A release without "<dmg>.sig" is refused before anything is downloaded.
        let installer = UpdateInstaller(runner: MockRunner(), publicKey: testPublicKey)
        let dmgName = "ContainerDeck-99.0.0\(AppConfig.updateAssetSuffix)"
        let unsigned = release([dmgName, dmgName + ".sha256"])
        XCTAssertNil(UpdateAssets.signatureAsset(for: unsigned.assets[0], in: unsigned.assets))
        do {
            _ = try await installer.prepare(release: unsigned, expectedBundleID: AppConfig.bundleID,
                                            currentVersion: "1.0.0", runningApp: nil) { _ in }
            XCTFail("an unsigned release must fail")
        } catch {
            XCTAssertEqual(error as? UpdateInstallError, .updateSignatureMissing)
        }
        do {
            _ = try await installer.downloadVerified(asset: unsigned.assets[0], release: unsigned,
                                                     into: FileManager.default.temporaryDirectory) { _ in }
            XCTFail("an unsigned download must fail")
        } catch {
            XCTAssertEqual(error as? UpdateInstallError, .updateSignatureMissing)
        }
        // And one without a checksum file.
        do {
            _ = try await installer.prepare(release: release([dmgName, dmgName + ".sig"]), expectedBundleID: AppConfig.bundleID,
                                            currentVersion: "1.0.0", runningApp: nil) { _ in }
            XCTFail("a release without checksum must fail")
        } catch {
            XCTAssertEqual(error as? UpdateInstallError, .checksumMissing)
        }
    }

    func testSignatureAssetLookup() {
        let rel = release(["ContainerDeck-1.2.0.dmg", "ContainerDeck-1.2.0.dmg.sha256", "ContainerDeck-1.2.0.DMG.SIG", "other.sig"])
        XCTAssertEqual(UpdateAssets.signatureAsset(for: rel.assets[0], in: rel.assets)?.name, "ContainerDeck-1.2.0.DMG.SIG")
    }

    // MARK: No update key

    func testEmptyPublicKeyMeansNoAutomaticInstall() async throws {
        XCTAssertFalse(UpdateSignature.isConfigured(publicKey: ""))
        XCTAssertFalse(UpdateSignature.isConfigured(publicKey: "  \n"))
        XCTAssertTrue(UpdateSignature.isConfigured(publicKey: testPublicKey))
        let installer = UpdateInstaller(runner: MockRunner(), publicKey: "")
        XCTAssertFalse(installer.canInstallAutomatically)
        let dmgName = "ContainerDeck-99.0.0\(AppConfig.updateAssetSuffix)"
        do {
            _ = try await installer.prepare(release: release([dmgName, dmgName + ".sha256", dmgName + ".sig"]),
                                            expectedBundleID: AppConfig.bundleID, currentVersion: "1.0.0", runningApp: nil) { _ in }
            XCTFail("no key must refuse to install")
        } catch {
            XCTAssertEqual(error as? UpdateInstallError, .updatesNotSigned)
        }
        XCTAssertTrue(UpdateInstallError.updatesNotSigned.suggestsManualInstall)
        XCTAssertThrowsError(try UpdateSignature.verify(digest: Data(count: 32), signatureText: "x", publicKey: "")) { error in
            XCTAssertEqual(error as? UpdateInstallError, .updatesNotSigned)
        }
    }

    func testConfiguredPublicKeyIsEmptyOrValid() {
        if UpdateSignature.isConfigured() {
            XCTAssertNoThrow(try UpdateSignature.publicKey(base64: AppConfig.updatePublicKey),
                             "AppConfig.updatePublicKey must be base64 of 32 bytes (scripts/make_update_keys.sh)")
        }
        XCTAssertEqual(UpdateInstaller().canInstallAutomatically, UpdateSignature.isConfigured())
        XCTAssertEqual(AppConfig.codeSigningIdentity, "\(AppConfig.appName) Code Signing")
    }

    // MARK: Certificate decisions

    private let bundleID = AppConfig.bundleID

    private func info(_ hash: String?, adHoc: Bool = false) -> CodeSignInfo {
        CodeSignInfo(isSigned: true, isAdHoc: adHoc, identifier: AppConfig.bundleID,
                     authorities: adHoc ? [] : [AppConfig.codeSigningIdentity], hardenedRuntime: !adHoc,
                     leafCertificateHash: hash)
    }

    func testCertificateHashDecisions() {
        let same = String(repeating: "c", count: 64)
        let other = String(repeating: "d", count: 64)
        // Same certificate: trusted.
        XCTAssertEqual(UpdateTrust.evaluate(running: info(same), candidate: info(same), candidateBundleID: bundleID, expectedBundleID: bundleID), .trusted)
        // Different certificate: rejected.
        XCTAssertFalse(UpdateTrust.evaluate(running: info(same), candidate: info(other), candidateBundleID: bundleID, expectedBundleID: bundleID).isTrusted)
        // Ad hoc new version on a signed copy: rejected.
        XCTAssertFalse(UpdateTrust.evaluate(running: info(same), candidate: info(nil, adHoc: true), candidateBundleID: bundleID, expectedBundleID: bundleID).isTrusted)
        // Ad hoc running copy (dev build): check skipped.
        XCTAssertEqual(UpdateTrust.evaluate(running: info(nil, adHoc: true), candidate: info(other), candidateBundleID: bundleID, expectedBundleID: bundleID), .trustedDevelopmentBuild)
        XCTAssertEqual(UpdateTrust.evaluate(running: nil, candidate: info(other), candidateBundleID: bundleID, expectedBundleID: bundleID), .trustedDevelopmentBuild)
        // Signed copy whose certificate can not be read: fail closed.
        XCTAssertFalse(UpdateTrust.evaluate(running: info(nil), candidate: info(same), candidateBundleID: bundleID, expectedBundleID: bundleID).isTrusted)
    }

    /// The real Security framework lookup: Apple signed code has a leaf, ad hoc code has none.
    func testLeafHashFromRealSignatures() async throws {
        let apple = SigningCertificate.leafHash(of: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertEqual(apple?.count, 64)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("deck-adhoc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: copy.path)
        let result = try await ProcessRunner().run("/usr/bin/codesign", ["--force", "--sign", "-", copy.path])
        XCTAssertTrue(result.succeeded, result.failureMessage)
        XCTAssertNil(SigningCertificate.leafHash(of: copy))
        XCTAssertNil(SigningCertificate.leafHash(of: URL(fileURLWithPath: "/nonexistent/app")))
    }

    // MARK: Install script

    func testInstallScriptRemovesQuarantine() {
        let text = UpdateInstallScript(pid: 1, newApp: "/tmp/u/new/\(AppConfig.appName).app",
                                       target: "/Applications/\(AppConfig.appName).app", workDir: "/tmp/u", logFile: "/tmp/u/log").contents
        XCTAssertTrue(text.contains("/usr/bin/xattr -dr com.apple.quarantine \"$STAGE\""))
        XCTAssertTrue(text.contains("/usr/bin/xattr -dr com.apple.quarantine \"$TARGET\""))
        // Cleared before the relaunch.
        let clear = text.range(of: "com.apple.quarantine \"$TARGET\"")!
        let open = text.range(of: "if ! /usr/bin/open \"$TARGET\"")!
        XCTAssertLessThan(clear.lowerBound, open.lowerBound)
    }

    // MARK: Scripts

    /// `bash -n` on every release script, so a typo never reaches the Release workflow.
    func testScriptsAreValidBash() throws {
        let scripts = try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("scripts").path)
            .filter { $0.hasSuffix(".sh") }
        XCTAssertTrue(scripts.contains("make_signing_cert.sh"))
        XCTAssertTrue(scripts.contains("make_update_keys.sh"))
        XCTAssertTrue(scripts.contains("sign_update.sh"))
        for name in scripts {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-n", repo.appendingPathComponent("scripts/\(name)").path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(name) has a syntax error")
        }
    }

    // MARK: Real release dry run (DECK_RELEASE_DRYRUN=1)

    /// Runs the updater's download, checksum, Ed25519, mount, extract and certificate steps
    /// against a real disk image made by scripts/bundle.sh, make_dmg.sh and sign_update.sh
    /// with a throw away certificate and key. Never replaces anything.
    ///   DECK_DRYRUN_DMG          the .dmg (with .sha256 and .sig next to it)
    ///   DECK_DRYRUN_PUBLIC_KEY   the throw away Ed25519 public key
    ///   DECK_DRYRUN_RUNNING_APP  an app signed with the same certificate (stands in for the running copy)
    ///   DECK_DRYRUN_OTHER_APP    optional, an app signed with another certificate
    func testRealReleaseDryRun() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DECK_RELEASE_DRYRUN"] == "1", "Set DECK_RELEASE_DRYRUN=1 to run")
        let dmg = URL(fileURLWithPath: try XCTUnwrap(env["DECK_DRYRUN_DMG"]))
        let publicKey = try XCTUnwrap(env["DECK_DRYRUN_PUBLIC_KEY"])
        let running = URL(fileURLWithPath: try XCTUnwrap(env["DECK_DRYRUN_RUNNING_APP"]))
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("deck-dryrun-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        func releaseFor(_ image: URL) -> AppRelease {
            let names = [image.lastPathComponent, image.lastPathComponent + ".sha256", image.lastPathComponent + ".sig"]
            return AppRelease(version: ReleaseVersion(99, 0, 0), tagName: "v99.0.0", title: "", notes: "",
                              pageURL: URL(string: "https://github.com/\(AppConfig.repository)/releases")!,
                              publishedAt: nil, isPrerelease: false,
                              assets: names.map { ReleaseAsset(name: $0, url: image.deletingLastPathComponent().appendingPathComponent($0)) })
        }
        let installer = UpdateInstaller(workRoot: work, publicKey: publicKey)

        // 1. The real release installs over a copy signed with the same certificate.
        let runningHash = try XCTUnwrap(SigningCertificate.leafHash(of: running), "the running app has no certificate")
        let prepared = try await installer.prepare(release: releaseFor(dmg), expectedBundleID: AppConfig.bundleID,
                                                   currentVersion: "0.0.1", runningApp: running) { _ in }
        XCTAssertEqual(prepared.trust, .trusted)
        XCTAssertTrue(prepared.checksumVerified)
        XCTAssertTrue(prepared.signatureVerified)
        XCTAssertEqual(SigningCertificate.leafHash(of: prepared.app), runningHash)
        let info = await installer.codeSignInfo(of: prepared.app)
        XCTAssertTrue(info.hardenedRuntime)
        XCTAssertEqual(info.authorities.first, AppConfig.codeSigningIdentity)
        print("dry run: installed copy would be \(prepared.app.path), certificate \(runningHash)")

        // 2. A copy signed with another certificate refuses it.
        if let other = env["DECK_DRYRUN_OTHER_APP"], !other.isEmpty {
            do {
                _ = try await installer.prepare(release: releaseFor(dmg), expectedBundleID: AppConfig.bundleID,
                                                currentVersion: "0.0.1", runningApp: URL(fileURLWithPath: other)) { _ in }
                XCTFail("another certificate must be refused")
            } catch let error as UpdateInstallError {
                guard case .rejected = error else { return XCTFail("wrong error \(error)") }
            }
        }

        // 3. A changed image with a matching checksum but the old signature is refused.
        let tamperedDir = work.appendingPathComponent("tampered")
        try fm.createDirectory(at: tamperedDir, withIntermediateDirectories: true)
        let tampered = tamperedDir.appendingPathComponent(dmg.lastPathComponent)
        var bytes = try Data(contentsOf: dmg)
        bytes.append(0)
        try bytes.write(to: tampered)
        try "\(try UpdateChecksum.sha256(of: tampered))  \(tampered.lastPathComponent)\n"
            .write(to: URL(fileURLWithPath: tampered.path + ".sha256"), atomically: true, encoding: .utf8)
        try fm.copyItem(atPath: dmg.path + ".sig", toPath: tampered.path + ".sig")
        do {
            _ = try await installer.prepare(release: releaseFor(tampered), expectedBundleID: AppConfig.bundleID,
                                            currentVersion: "0.0.1", runningApp: running) { _ in }
            XCTFail("a changed image must be refused")
        } catch let error as UpdateInstallError {
            guard case .updateSignatureInvalid = error else { return XCTFail("wrong error \(error)") }
        }
    }

    /// scripts/update_signer.swift (used by the Release workflow) and the app agree on the format.
    /// Runs the Swift interpreter, so it is gated: DECK_SIGNER_SCRIPT=1.
    func testSignerScriptMatchesApp() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_SIGNER_SCRIPT"] == "1", "Set DECK_SIGNER_SCRIPT=1 to run")
        let dmg = try tempFile("release bytes")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", repo.appendingPathComponent("scripts/update_signer.swift").path, "sign", dmg.path]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["UPDATE_SIGNING_KEY": testKey.rawRepresentation.base64EncodedString()]) { $1 }
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNoThrow(try UpdateSignature.verify(file: dmg, signatureText: String(decoding: data, as: UTF8.self), publicKey: testPublicKey))
    }
}
