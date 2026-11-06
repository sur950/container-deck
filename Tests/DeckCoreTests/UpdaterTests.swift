import XCTest
import CryptoKit
@testable import DeckCore

/// In app updater: pure logic, plus an end to end run gated by DECK_UPDATER_E2E=1.
final class UpdaterTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/x")

    private func v(_ text: String) -> ReleaseVersion {
        guard let version = ReleaseVersion(text) else {
            XCTFail("Could not parse \(text)")
            return ReleaseVersion(0)
        }
        return version
    }

    private func release(_ version: String, assets: [ReleaseAsset] = []) -> AppRelease {
        AppRelease(version: v(version), tagName: "v\(version)", title: "", notes: "",
                   pageURL: URL(string: "https://github.com/\(AppConfig.repository)/releases/tag/v\(version)")!,
                   publishedAt: nil, isPrerelease: v(version).isPrerelease, assets: assets)
    }

    // MARK: Versions

    func testVersionCompareWithPrereleases() {
        XCTAssertLessThan(v("1.2.0"), v("1.2.1"))
        XCTAssertLessThan(v("1.2.9"), v("1.10.0"))
        XCTAssertLessThan(v("1.3.0-beta.1"), v("1.3.0"))
        XCTAssertLessThan(v("1.3.0-alpha"), v("1.3.0-beta"))
        XCTAssertLessThan(v("1.3.0-beta.2"), v("1.3.0-beta.10"))
        XCTAssertLessThan(v("1.3.0-rc.1"), v("1.3.0-rc.1.1"))
        XCTAssertLessThan(v("1.2.0"), v("1.3.0-beta.1"))
        XCTAssertEqual(v("v1.3.0+build.7"), v("1.3.0"))
        XCTAssertTrue(v("2.0.0-rc.1").isPrerelease)
    }

    func testUpdateAvailableFromPrereleaseToRelease() {
        XCTAssertTrue(UpdateChecker.evaluate(latest: release("1.3.0"), currentVersion: "1.3.0-beta.2").isUpdateAvailable)
        XCTAssertFalse(UpdateChecker.evaluate(latest: release("1.3.0-beta.2"), currentVersion: "1.3.0").isUpdateAvailable)
    }

    func testAcceptableVersionRejectsDowngrade() {
        XCTAssertTrue(UpdateTrust.isAcceptableVersion(candidate: "1.3.0", current: "1.2.0"))
        XCTAssertFalse(UpdateTrust.isAcceptableVersion(candidate: "1.2.0", current: "1.2.0"))
        XCTAssertFalse(UpdateTrust.isAcceptableVersion(candidate: "1.1.0", current: "1.2.0"))
        XCTAssertFalse(UpdateTrust.isAcceptableVersion(candidate: nil, current: "1.2.0"))
        XCTAssertFalse(UpdateTrust.isAcceptableVersion(candidate: "nightly", current: "1.2.0"))
        // Dev builds have no version: anything readable is fine.
        XCTAssertTrue(UpdateTrust.isAcceptableVersion(candidate: "1.0.0", current: nil))
    }

    // MARK: Assets

    func testAssetPickPrefersAppleSiliconThenUniversal() {
        let assets = [
            ReleaseAsset(name: "ContainerDeck-1.0.0-x86_64.dmg", url: url),
            ReleaseAsset(name: "ContainerDeck-1.0.0-universal.dmg", url: url),
            ReleaseAsset(name: "ContainerDeck-1.0.0-arm64.dmg", url: url),
            ReleaseAsset(name: "ContainerDeck-1.0.0-arm64.dmg.sha256", url: url)
        ]
        XCTAssertEqual(UpdateAssets.pickInstallAsset(assets)?.name, "ContainerDeck-1.0.0-arm64.dmg")
        XCTAssertEqual(UpdateAssets.pickInstallAsset(Array(assets.prefix(2)))?.name, "ContainerDeck-1.0.0-universal.dmg")
    }

    func testAssetPickUsesConfiguredSuffixAndAvoidsIntel() {
        let assets = [
            ReleaseAsset(name: "ContainerDeck-1.0.0-intel.dmg", url: url),
            ReleaseAsset(name: "ContainerDeck-1.0.0.DMG", url: url),
            ReleaseAsset(name: "ContainerDeck-1.0.0.zip", url: url)
        ]
        XCTAssertEqual(UpdateAssets.pickInstallAsset(assets)?.name, "ContainerDeck-1.0.0.DMG")
        XCTAssertEqual(UpdateAssets.pickInstallAsset(assets, suffix: ".zip")?.name, "ContainerDeck-1.0.0.zip")
        XCTAssertNil(UpdateAssets.pickInstallAsset([ReleaseAsset(name: "notes.txt", url: url)]))
        XCTAssertEqual(UpdateChecker.pickDiskImage(assets)?.name, "ContainerDeck-1.0.0.DMG")
    }

    func testChecksumAssetLookup() {
        let dmg = ReleaseAsset(name: "ContainerDeck-1.2.0.dmg", url: url)
        let sha = ReleaseAsset(name: "ContainerDeck-1.2.0.dmg.sha256", url: url)
        let sums = ReleaseAsset(name: "SHA256SUMS.txt", url: url)
        XCTAssertEqual(UpdateAssets.checksumAsset(for: dmg, in: [sums, dmg, sha]), sha)
        XCTAssertEqual(UpdateAssets.checksumAsset(for: dmg, in: [dmg, sums]), sums)
        XCTAssertNil(UpdateAssets.checksumAsset(for: dmg, in: [dmg]))
        XCTAssertEqual(release("1.2.0", assets: [dmg, sha]).checksumAsset, sha)
    }

    // MARK: Checksums

    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "B", count: 64)

    func testChecksumParseFormats() {
        XCTAssertEqual(UpdateChecksum.parse("\(hashA)  ContainerDeck-1.2.0.dmg\n"), hashA)
        XCTAssertEqual(UpdateChecksum.parse("\(hashA) *ContainerDeck-1.2.0.dmg", fileName: "ContainerDeck-1.2.0.dmg"), hashA)
        XCTAssertEqual(UpdateChecksum.parse("  \(hashB)\n"), hashB.lowercased())
        XCTAssertEqual(UpdateChecksum.parse("SHA256 (ContainerDeck-1.2.0.dmg) = \(hashA)", fileName: "ContainerDeck-1.2.0.dmg"), hashA)
        XCTAssertNil(UpdateChecksum.parse("not a hash  file.dmg"))
        XCTAssertNil(UpdateChecksum.parse(""))
        XCTAssertNil(UpdateChecksum.parse(String(repeating: "g", count: 64)))
    }

    func testChecksumParsePicksNamedLine() {
        let sums = """
        # checksums
        \(hashA)  ContainerDeck-1.2.0.dmg
        \(hashB)  container-deck.rb
        """
        XCTAssertEqual(UpdateChecksum.parse(sums, fileName: "ContainerDeck-1.2.0.dmg"), hashA)
        XCTAssertEqual(UpdateChecksum.parse(sums, fileName: "container-deck.rb"), hashB.lowercased())
        XCTAssertNil(UpdateChecksum.parse(sums, fileName: "other.dmg"))
        // One entry is accepted whatever its name (a renamed asset still has its own .sha256).
        XCTAssertEqual(UpdateChecksum.parse("\(hashA)  old-name.dmg", fileName: "new-name.dmg"), hashA)
        XCTAssertEqual(UpdateChecksum.parse("\(hashA)  build/ContainerDeck-1.2.0.dmg", fileName: "ContainerDeck-1.2.0.dmg"), hashA)
    }

    func testChecksumVerifyTempFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("deck-sha-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("hello\n".utf8).write(to: file)
        // shasum -a 256 of "hello\n"
        let expected = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
        XCTAssertEqual(try UpdateChecksum.sha256(of: file), expected)
        XCTAssertNoThrow(try UpdateChecksum.verify(file: file, expected: expected.uppercased() + "\n"))
        XCTAssertThrowsError(try UpdateChecksum.verify(file: file, expected: hashA)) { error in
            guard case .checksumMismatch(let wanted, let actual)? = error as? UpdateInstallError else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertEqual(wanted, hashA)
            XCTAssertEqual(actual, expected)
        }
    }

    // MARK: codesign -dv

    static let developerIDOutput = """
    Executable=/Applications/Container Deck.app/Contents/MacOS/ContainerDeck
    Identifier=\(AppConfig.bundleID)
    Format=app bundle with Mach-O thin (arm64)
    CodeDirectory v=20500 size=31252 flags=0x10000(runtime) hashes=970+7 location=embedded
    Signature size=9045
    Authority=Developer ID Application: Example Developer (ABCDE12345)
    Authority=Developer ID Certification Authority
    Authority=Apple Root CA
    Timestamp=1 Nov 2026 at 10:00:00 AM
    Notarization Ticket=stapled
    Info.plist entries=16
    TeamIdentifier=ABCDE12345
    Runtime Version=26.0.0
    Sealed Resources version=2 rules=13 files=2
    Internal requirements count=1 size=200
    """

    static let adHocOutput = """
    Executable=/Users/me/build/Container Deck.app/Contents/MacOS/ContainerDeck
    Identifier=\(AppConfig.bundleID)
    Format=app bundle with Mach-O thin (arm64)
    CodeDirectory v=20400 size=31252 flags=0x2(adhoc) hashes=970+3 location=embedded
    Signature=adhoc
    Info.plist entries=16
    TeamIdentifier=not set
    Sealed Resources version=2 rules=13 files=2
    Internal requirements count=0 size=12
    """

    static let unsignedOutput = "/tmp/Container Deck.app: code object is not signed at all\n"

    func testCodesignParseDeveloperID() {
        let info = CodeSignInfo.parse(Self.developerIDOutput)
        XCTAssertTrue(info.isSigned)
        XCTAssertFalse(info.isAdHoc)
        XCTAssertTrue(info.isDeveloperID)
        XCTAssertEqual(info.identifier, AppConfig.bundleID)
        XCTAssertEqual(info.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(info.authorities.count, 3)
        XCTAssertTrue(info.hardenedRuntime)
        XCTAssertTrue(info.notarizationStapled)
    }

    func testCodesignParseAdHoc() {
        let info = CodeSignInfo.parse(Self.adHocOutput)
        XCTAssertTrue(info.isSigned)
        XCTAssertTrue(info.isAdHoc)
        XCTAssertFalse(info.isDeveloperID)
        XCTAssertNil(info.teamIdentifier)
        XCTAssertEqual(info.identifier, AppConfig.bundleID)
        XCTAssertFalse(info.hardenedRuntime)
    }

    func testCodesignParseUnsigned() {
        let info = CodeSignInfo.parse(Self.unsignedOutput)
        XCTAssertEqual(info, .unsigned)
        XCTAssertFalse(info.isSigned)
        XCTAssertFalse(CodeSignInfo.parse("").isSigned)
    }

    // MARK: Trust decision

    private let bundleID = AppConfig.bundleID

    private let certA = String(repeating: "a1", count: 32)
    private let certB = String(repeating: "b2", count: 32)

    private func signed(_ hash: String?) -> CodeSignInfo {
        var info = CodeSignInfo.parse(Self.selfSignedOutput)
        info.leafCertificateHash = hash
        return info
    }

    static let selfSignedOutput = """
    Executable=/Applications/Container Deck.app/Contents/MacOS/ContainerDeck
    Identifier=\(AppConfig.bundleID)
    Format=app bundle with Mach-O thin (arm64)
    CodeDirectory v=20500 size=31252 flags=0x10000(runtime) hashes=970+7 location=embedded
    Signature size=1700
    Authority=\(AppConfig.codeSigningIdentity)
    Signed Time=1 Nov 2026 at 10:00:00 AM
    Info.plist entries=16
    TeamIdentifier=not set
    Runtime Version=26.0.0
    Sealed Resources version=2 rules=13 files=2
    Internal requirements count=1 size=200
    """

    func testSelfSignedParse() {
        let info = CodeSignInfo.parse(Self.selfSignedOutput)
        XCTAssertTrue(info.isSigned)
        XCTAssertFalse(info.isAdHoc)
        XCTAssertTrue(info.hasCertificate)
        XCTAssertFalse(info.isDeveloperID)
        XCTAssertNil(info.teamIdentifier)
        XCTAssertEqual(info.authorities, [AppConfig.codeSigningIdentity])
        XCTAssertTrue(info.hardenedRuntime)
    }

    func testSameCertificateIsTrusted() {
        XCTAssertEqual(UpdateTrust.evaluate(running: signed(certA), candidate: signed(certA),
                                            candidateBundleID: bundleID, expectedBundleID: bundleID), .trusted)
        // Hex case does not matter.
        XCTAssertEqual(UpdateTrust.evaluate(running: signed(certA), candidate: signed(certA.uppercased()),
                                            candidateBundleID: bundleID, expectedBundleID: bundleID), .trusted)
    }

    func testOtherCertificateIsRejected() {
        let decision = UpdateTrust.evaluate(running: signed(certA), candidate: signed(certB), candidateBundleID: bundleID, expectedBundleID: bundleID)
        XCTAssertFalse(decision.isTrusted)
        // The same name on another certificate is still another certificate.
        XCTAssertEqual(signed(certA).authorities, signed(certB).authorities)
        // A Developer ID team match no longer counts. Only the certificate does.
        var devID = CodeSignInfo.parse(Self.developerIDOutput)
        devID.leafCertificateHash = certB
        var devIDRunning = devID
        devIDRunning.leafCertificateHash = certA
        XCTAssertFalse(UpdateTrust.evaluate(running: devIDRunning, candidate: devID, candidateBundleID: bundleID, expectedBundleID: bundleID).isTrusted)
    }

    func testUnknownCertificateFailsClosed() {
        XCTAssertFalse(UpdateTrust.evaluate(running: signed(certA), candidate: signed(nil), candidateBundleID: bundleID, expectedBundleID: bundleID).isTrusted)
        XCTAssertFalse(UpdateTrust.evaluate(running: signed(nil), candidate: signed(certA), candidateBundleID: bundleID, expectedBundleID: bundleID).isTrusted)
        XCTAssertFalse(UpdateTrust.evaluate(running: signed(""), candidate: signed(""), candidateBundleID: bundleID, expectedBundleID: bundleID).isTrusted)
    }

    func testAdHocCandidateRejectedWhenRunningIsSigned() {
        var adHoc = CodeSignInfo.parse(Self.adHocOutput)
        adHoc.leafCertificateHash = certA   // can not happen, and must not help
        XCTAssertFalse(UpdateTrust.evaluate(running: signed(certA), candidate: adHoc, candidateBundleID: bundleID, expectedBundleID: bundleID).isTrusted)
    }

    func testDevBuildSkipsCertificateCheck() {
        let adHoc = CodeSignInfo.parse(Self.adHocOutput)
        let signed = self.signed(certA)
        XCTAssertEqual(UpdateTrust.evaluate(running: adHoc, candidate: signed, candidateBundleID: bundleID, expectedBundleID: bundleID), .trustedDevelopmentBuild)
        XCTAssertEqual(UpdateTrust.evaluate(running: adHoc, candidate: adHoc, candidateBundleID: bundleID, expectedBundleID: bundleID), .trustedDevelopmentBuild)
        XCTAssertEqual(UpdateTrust.evaluate(running: nil, candidate: adHoc, candidateBundleID: bundleID, expectedBundleID: bundleID), .trustedDevelopmentBuild)
        XCTAssertEqual(UpdateTrust.evaluate(running: .unsigned, candidate: signed, candidateBundleID: bundleID, expectedBundleID: bundleID), .trustedDevelopmentBuild)
    }

    func testUnsignedOrWrongBundleAlwaysRejected() {
        let adHoc = CodeSignInfo.parse(Self.adHocOutput)
        let signed = self.signed(certA)
        XCTAssertFalse(UpdateTrust.evaluate(running: adHoc, candidate: .unsigned, candidateBundleID: bundleID, expectedBundleID: bundleID).isTrusted)
        XCTAssertFalse(UpdateTrust.evaluate(running: adHoc, candidate: signed, candidateBundleID: "com.evil.app", expectedBundleID: bundleID).isTrusted)
        XCTAssertFalse(UpdateTrust.evaluate(running: adHoc, candidate: signed, candidateBundleID: nil, expectedBundleID: bundleID).isTrusted)
        var mislabeled = signed
        mislabeled.identifier = "com.evil.app"
        XCTAssertFalse(UpdateTrust.evaluate(running: signed, candidate: mislabeled, candidateBundleID: bundleID, expectedBundleID: bundleID).isTrusted)
    }

    // MARK: Skip, due and notify

    func testSkipVersion() {
        let result = UpdateChecker.evaluate(latest: release("1.3.0"), currentVersion: "1.2.0")
        XCTAssertTrue(UpdatePolicy.shouldOffer(result, skippedVersion: nil))
        XCTAssertFalse(UpdatePolicy.shouldOffer(result, skippedVersion: "1.3.0"))
        XCTAssertFalse(UpdatePolicy.shouldOffer(result, skippedVersion: "v1.3"))
        // Checking by hand still shows it.
        XCTAssertTrue(UpdatePolicy.shouldOffer(result, skippedVersion: "1.3.0", userInitiated: true))
        // A newer release than the skipped one is offered again.
        let newer = UpdateChecker.evaluate(latest: release("1.3.1"), currentVersion: "1.2.0")
        XCTAssertTrue(UpdatePolicy.shouldOffer(newer, skippedVersion: "1.3.0"))
        XCTAssertTrue(UpdatePolicy.shouldOffer(result, skippedVersion: "garbage"))
        // Nothing to offer when up to date.
        let current = UpdateChecker.evaluate(latest: release("1.2.0"), currentVersion: "1.2.0")
        XCTAssertFalse(UpdatePolicy.shouldOffer(current, skippedVersion: nil, userInitiated: true))
        XCTAssertFalse(UpdatePolicy.shouldOffer(nil, skippedVersion: nil))
    }

    func testNotifyOncePerVersion() {
        let result = UpdateChecker.evaluate(latest: release("1.3.0"), currentVersion: "1.2.0")
        XCTAssertTrue(UpdatePolicy.shouldNotify(result, skippedVersion: nil, alreadyNotified: nil))
        XCTAssertFalse(UpdatePolicy.shouldNotify(result, skippedVersion: nil, alreadyNotified: "1.3.0"))
        XCTAssertTrue(UpdatePolicy.shouldNotify(result, skippedVersion: nil, alreadyNotified: "1.2.5"))
        XCTAssertFalse(UpdatePolicy.shouldNotify(result, skippedVersion: "1.3.0", alreadyNotified: nil))
    }

    func testIsDue() {
        let now = Date()
        XCTAssertTrue(UpdatePolicy.isDue(lastChecked: nil, now: now))
        XCTAssertFalse(UpdatePolicy.isDue(lastChecked: now.addingTimeInterval(-60), now: now, interval: 3600))
        XCTAssertTrue(UpdatePolicy.isDue(lastChecked: now.addingTimeInterval(-3600), now: now, interval: 3600))
        // Clock moved back: check again.
        XCTAssertTrue(UpdatePolicy.isDue(lastChecked: now.addingTimeInterval(600), now: now, interval: 3600))
        XCTAssertFalse(UpdatePolicy.isDue(lastChecked: now.addingTimeInterval(-60), now: now))
    }

    // MARK: Location

    func testLocationProblems() {
        let all: (String) -> Bool = { _ in true }
        let none: (String) -> Bool = { _ in false }
        XCTAssertNil(UpdateLocation.problem(bundlePath: "/Applications/Container Deck.app", isWritable: all))
        XCTAssertEqual(UpdateLocation.problem(bundlePath: "/Applications/Container Deck.app", isWritable: none), .notWritable("/Applications"))
        XCTAssertEqual(UpdateLocation.problem(bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/Container Deck.app", isWritable: all), .translocated)
        XCTAssertEqual(UpdateLocation.problem(bundlePath: "/Volumes/Container Deck/Container Deck.app", isWritable: none), .runningFromDiskImage)
        XCTAssertEqual(UpdateLocation.problem(bundlePath: "/usr/local/bin", isWritable: all), .notWritable("/usr/local/bin"))
        // Parent writable but the bundle itself is not (owned by root).
        let parentOnly: (String) -> Bool = { $0 == "/Applications" }
        XCTAssertEqual(UpdateLocation.problem(bundlePath: "/Applications/Container Deck.app", isWritable: parentOnly), .notWritable("/Applications"))
        XCTAssertTrue(UpdateInstallError.notWritable("/Applications").suggestsManualInstall)
        XCTAssertFalse(UpdateInstallError.checksumMismatch(expected: "", actual: "").suggestsManualInstall)
    }

    func testPickAppBundleInDiskImage() {
        let name = AppConfig.appName + ".app"
        XCTAssertEqual(UpdateLocation.pickAppBundle(["Applications", ".VolumeIcon.icns", name]), name)
        XCTAssertEqual(UpdateLocation.pickAppBundle(["Other.app", name]), name)
        XCTAssertEqual(UpdateLocation.pickAppBundle(["B.app", "A.app"], preferredName: "Container Deck.app"), "A.app")
        XCTAssertEqual(UpdateLocation.pickAppBundle(["Renamed.app", "Applications"]), "Renamed.app")
        XCTAssertNil(UpdateLocation.pickAppBundle(["Applications", ".hidden.app"]))
    }

    // MARK: Install script

    func testShellQuote() {
        XCTAssertEqual(UpdateInstallScript.shellQuote("/Applications/Container Deck.app"), "'/Applications/Container Deck.app'")
        XCTAssertEqual(UpdateInstallScript.shellQuote("it's $HOME `x`"), "'it'\\''s $HOME `x`'")
    }

    func testInstallScriptContents() throws {
        let script = UpdateInstallScript(
            pid: 4242,
            newApp: "/private/var/folders/T/upd/new/Container Deck.app",
            target: "/Applications/Container Deck.app",
            workDir: "/private/var/folders/T/upd",
            logFile: "/Users/me/Library/Logs/Container Deck/update.log",
            quitTimeout: 60, launchTimeout: 20
        )
        XCTAssertEqual(script.stagePath, "/Applications/.Container Deck.app.update-new")
        XCTAssertEqual(script.backupPath, "/Applications/.Container Deck.app.update-old")

        let text = script.contents
        XCTAssertTrue(text.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(text.contains("PID=4242\n"))
        XCTAssertTrue(text.contains("TARGET='/Applications/Container Deck.app'\n"))
        XCTAssertTrue(text.contains("NEW_APP='/private/var/folders/T/upd/new/Container Deck.app'\n"))
        XCTAssertTrue(text.contains("STAGE='/Applications/.Container Deck.app.update-new'\n"))
        XCTAssertTrue(text.contains("BACKUP='/Applications/.Container Deck.app.update-old'\n"))
        XCTAssertTrue(text.contains("LOG='/Users/me/Library/Logs/Container Deck/update.log'\n"))
        XCTAssertTrue(text.contains("WORK='/private/var/folders/T/upd'\n"))
        // Waits for our process, swaps with ditto then mv, clears quarantine, relaunches.
        XCTAssertTrue(text.contains("/bin/kill -0 \"$PID\""))
        XCTAssertTrue(text.contains("-ge 120 ]"))
        XCTAssertTrue(text.contains("-lt 40 ]"))
        XCTAssertTrue(text.contains("/usr/bin/ditto \"$NEW_APP\" \"$STAGE\""))
        XCTAssertTrue(text.contains("/bin/mv \"$TARGET\" \"$BACKUP\""))
        XCTAssertTrue(text.contains("/bin/mv \"$STAGE\" \"$TARGET\""))
        XCTAssertTrue(text.contains("/usr/bin/xattr -dr com.apple.quarantine \"$STAGE\""))
        XCTAssertTrue(text.contains("/usr/bin/xattr -dr com.apple.quarantine \"$TARGET\""))
        XCTAssertTrue(text.contains("/usr/bin/open \"$TARGET\""))
        XCTAssertTrue(text.contains("rollback()"))
        // No path is ever used unquoted.
        XCTAssertFalse(text.contains("$TARGET "), "unquoted $TARGET")
        XCTAssertFalse(text.contains(" /Applications/Container Deck.app"))
        // The order matters: backup before swap, delete backup only after the launch check.
        let backup = try XCTUnwrap(text.range(of: "/bin/mv \"$TARGET\" \"$BACKUP\""))
        let swap = try XCTUnwrap(text.range(of: "/bin/mv \"$STAGE\" \"$TARGET\""))
        let cleanup = try XCTUnwrap(text.range(of: "log \"new version is running\""))
        XCTAssertLessThan(backup.lowerBound, swap.lowerBound)
        XCTAssertLessThan(swap.lowerBound, cleanup.lowerBound)
    }

    func testInstallScriptQuotesAwkwardPaths() {
        let script = UpdateInstallScript(pid: 1, newApp: "/tmp/a'b/Container Deck.app", target: "/Users/me/My Apps/Container Deck.app",
                                         workDir: "/tmp/a'b", logFile: "/tmp/log $x.txt")
        let text = script.contents
        XCTAssertTrue(text.contains("NEW_APP='/tmp/a'\\''b/Container Deck.app'"))
        XCTAssertTrue(text.contains("LOG='/tmp/log $x.txt'"))
        XCTAssertTrue(text.contains("STAGE='/Users/me/My Apps/.Container Deck.app.update-new'"))
    }

    /// Runs the real script against throw away bundles: swap, launch check and rollback.
    /// `open` is not used here; the script is checked with `sh -n` only.
    func testInstallScriptIsValidShell() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = UpdateInstallScript(pid: 1, newApp: "/tmp/x y/Container Deck.app", target: "/Applications/Container Deck.app",
                                         workDir: "/tmp/x y", logFile: "/tmp/x y/log")
        let file = dir.appendingPathComponent("install.sh")
        try script.contents.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: End to end (DECK_UPDATER_E2E=1)

    /// Builds a fake "new" app, packs it into a DMG with a .sha256, serves both from file URLs,
    /// then runs download, checksum, mount, extract and signature checks. Never replaces anything.
    func testEndToEndDownloadVerifyExtract() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DECK_UPDATER_E2E"] == "1", "Set DECK_UPDATER_E2E=1 to run")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("deck-e2e-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        let served = root.appendingPathComponent("served")
        let work = root.appendingPathComponent("work")
        for dir in [source, served, work] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }

        // 1. Fake app bundle named like the real one, ad hoc signed.
        let app = source.appendingPathComponent("\(AppConfig.appName).app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/ContainerDeck").path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": AppConfig.bundleID,
            "CFBundleExecutable": "ContainerDeck",
            "CFBundleName": AppConfig.appName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "99.0.0",
            "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        let runner = ProcessRunner()
        let sign = try await runner.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        XCTAssertTrue(sign.succeeded, sign.failureMessage)

        // 2. DMG and checksum file, like the Release workflow makes them.
        let dmgName = "ContainerDeck-99.0.0\(AppConfig.updateAssetSuffix)"
        let dmg = served.appendingPathComponent(dmgName)
        var create = try await runner.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", AppConfig.appName, "-srcfolder", source.path,
                                                               "-fs", "HFS+", "-format", "UDZO", "-ov", dmg.path])
        if !create.succeeded {
            // macOS 27 and later: hdiutil create from a folder is gone, diskutil image replaces it.
            create = try await runner.run("/usr/sbin/diskutil", ["image", "create", "from", "--format", "UDZO",
                                                                 "--volumeName", AppConfig.appName, source.path, dmg.path])
        }
        XCTAssertTrue(create.succeeded, create.failureMessage)
        let hash = try UpdateChecksum.sha256(of: dmg)
        try "\(hash)  \(dmgName)\n".write(to: served.appendingPathComponent(dmgName + ".sha256"), atomically: true, encoding: .utf8)
        let key = Curve25519.Signing.PrivateKey()
        let signature = try UpdateSignature.sign(digest: UpdateChecksum.sha256Digest(of: dmg), with: key)
        try signature.write(to: served.appendingPathComponent(dmgName + ".sig"), atomically: true, encoding: .utf8)

        let release = AppRelease(
            version: v("99.0.0"), tagName: "v99.0.0", title: "", notes: "",
            pageURL: URL(string: "https://github.com/\(AppConfig.repository)/releases/tag/v99.0.0")!,
            publishedAt: nil, isPrerelease: false,
            assets: [
                ReleaseAsset(name: dmgName + ".sha256", url: served.appendingPathComponent(dmgName + ".sha256")),
                ReleaseAsset(name: dmgName + ".sig", url: served.appendingPathComponent(dmgName + ".sig")),
                ReleaseAsset(name: dmgName, url: dmg)
            ]
        )
        XCTAssertEqual(release.diskImage?.name, dmgName)

        // 3. Download, checksum, mount, extract, verify.
        let installer = UpdateInstaller(runner: runner, workRoot: work,
                                        publicKey: key.publicKey.rawRepresentation.base64EncodedString())
        let steps = StepLog()
        let prepared = try await installer.prepare(release: release, expectedBundleID: AppConfig.bundleID,
                                                   currentVersion: "1.0.0", runningApp: nil) { steps.add($0) }
        XCTAssertTrue(prepared.checksumVerified)
        XCTAssertTrue(prepared.signatureVerified)
        XCTAssertEqual(prepared.version, "99.0.0")
        XCTAssertEqual(prepared.trust, .trustedDevelopmentBuild)
        XCTAssertEqual(prepared.app.lastPathComponent, "\(AppConfig.appName).app")
        XCTAssertTrue(fm.fileExists(atPath: prepared.app.appendingPathComponent("Contents/MacOS/ContainerDeck").path))
        XCTAssertTrue(prepared.app.path.hasPrefix(prepared.workDir.path))
        XCTAssertFalse(fm.fileExists(atPath: prepared.workDir.appendingPathComponent("mount").path), "image still mounted")
        let seen = steps.all
        XCTAssertTrue(seen.contains(.verifyingChecksum))
        XCTAssertTrue(seen.contains(.verifyingUpdateSignature))
        XCTAssertTrue(seen.contains(.mounting))
        XCTAssertEqual(seen.last, .ready)

        // 4. The handed off script would be written for this app (not run).
        let script = UpdateInstallScript(pid: 1, newApp: prepared.app.path, target: "/Applications/\(AppConfig.appName).app",
                                         workDir: prepared.workDir.path, logFile: work.appendingPathComponent("u.log").path)
        XCTAssertTrue(script.contents.contains(UpdateInstallScript.shellQuote(prepared.app.path)))

        // 5. A damaged download is refused.
        try "\(String(repeating: "0", count: 64))  \(dmgName)\n".write(to: served.appendingPathComponent(dmgName + ".sha256"),
                                                                       atomically: true, encoding: .utf8)
        do {
            _ = try await installer.prepare(release: release, expectedBundleID: AppConfig.bundleID,
                                            currentVersion: "1.0.0", runningApp: nil) { _ in }
            XCTFail("a wrong checksum must fail")
        } catch let error as UpdateInstallError {
            guard case .checksumMismatch = error else { return XCTFail("wrong error \(error)") }
        }

        // 5b. Another update key is refused, and so is a build without one.
        try "\(hash)  \(dmgName)\n".write(to: served.appendingPathComponent(dmgName + ".sha256"), atomically: true, encoding: .utf8)
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        do {
            _ = try await UpdateInstaller(runner: runner, workRoot: work, publicKey: otherKey)
                .prepare(release: release, expectedBundleID: AppConfig.bundleID, currentVersion: "1.0.0", runningApp: nil) { _ in }
            XCTFail("another key must fail")
        } catch let error as UpdateInstallError {
            guard case .updateSignatureInvalid = error else { return XCTFail("wrong error \(error)") }
        }
        do {
            _ = try await UpdateInstaller(runner: runner, workRoot: work, publicKey: "")
                .prepare(release: release, expectedBundleID: AppConfig.bundleID, currentVersion: "1.0.0", runningApp: nil) { _ in }
            XCTFail("no key must fail")
        } catch let error as UpdateInstallError {
            XCTAssertEqual(error, .updatesNotSigned)
        }

        // 6. A wrong bundle id or an older version is refused.
        try "\(hash)  \(dmgName)\n".write(to: served.appendingPathComponent(dmgName + ".sha256"), atomically: true, encoding: .utf8)
        do {
            _ = try await installer.prepare(release: release, expectedBundleID: "com.example.other",
                                            currentVersion: "1.0.0", runningApp: nil) { _ in }
            XCTFail("a different bundle id must fail")
        } catch let error as UpdateInstallError {
            guard case .rejected = error else { return XCTFail("wrong error \(error)") }
        }
        do {
            _ = try await installer.prepare(release: release, expectedBundleID: AppConfig.bundleID,
                                            currentVersion: "100.0.0", runningApp: nil) { _ in }
            XCTFail("an older app must fail")
        } catch let error as UpdateInstallError {
            XCTAssertEqual(error, .versionNotNewer("99.0.0"))
        }
    }
}

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [UpdateInstaller.Step] = []
    func add(_ step: UpdateInstaller.Step) { lock.lock(); steps.append(step); lock.unlock() }
    var all: [UpdateInstaller.Step] { lock.lock(); defer { lock.unlock() }; return steps }
}
