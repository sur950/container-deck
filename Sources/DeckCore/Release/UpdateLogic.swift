import Foundation
import CryptoKit

// Pure decisions for in app updates. No AppKit, no network. Unit tested in UpdaterTests.

// MARK: - Errors

public enum UpdateInstallError: LocalizedError, Equatable {
    case noDiskImage
    case notWritable(String)
    case translocated
    case runningFromDiskImage
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case checksumUnreadable
    case mountFailed(String)
    case appNotFound
    case signatureInvalid(String)
    /// The build has no update public key (AppConfig.updatePublicKey), so it never installs by itself.
    case updatesNotSigned
    /// The release has no "<dmg>.sig".
    case updateSignatureMissing
    /// The Ed25519 signature of the disk image is wrong.
    case updateSignatureInvalid(String)
    case checksumMissing
    case rejected(String)
    case versionNotNewer(String)
    case handOffFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noDiskImage:
            return "This release has no disk image to install."
        case .notWritable(let folder):
            return "\(AppConfig.appName) cannot replace itself in \(folder). Open the disk image and drag the app to Applications instead."
        case .translocated:
            return "macOS is running \(AppConfig.appName) from a temporary place. Move it to Applications, open it again, then update."
        case .runningFromDiskImage:
            return "\(AppConfig.appName) is running from the disk image. Drag it to Applications first."
        case .downloadFailed(let message):
            return "The download failed. \(message)"
        case .checksumMismatch:
            return "The download is damaged. Its checksum does not match the release."
        case .checksumUnreadable:
            return "The release checksum file could not be read."
        case .mountFailed(let message):
            return "The disk image could not be opened. \(message)"
        case .appNotFound:
            return "The disk image has no \(AppConfig.appName) app inside."
        case .signatureInvalid(let message):
            return "The new version failed the signature check. \(message)"
        case .updatesNotSigned:
            return "This build cannot install updates by itself. Download the new version from the release page."
        case .updateSignatureMissing:
            return "This release is not signed, so it was not installed. Download it from the release page instead."
        case .updateSignatureInvalid(let message):
            return "The download failed the update signature check. \(message)"
        case .checksumMissing:
            return "This release has no checksum file, so it was not installed."
        case .rejected(let reason):
            return reason
        case .versionNotNewer(let version):
            return "The downloaded app is version \(version), which is not newer than this one."
        case .handOffFailed(let message):
            return "Could not start the installer. \(message)"
        }
    }

    /// True when opening the disk image by hand is a sensible next step.
    public var suggestsManualInstall: Bool {
        switch self {
        case .notWritable, .translocated, .runningFromDiskImage, .handOffFailed, .updatesNotSigned: return true
        default: return false
        }
    }
}

// MARK: - Assets

public enum UpdateAssets {
    /// The installable asset: name ends with `suffix`, Apple silicon or universal builds first.
    public static func pickInstallAsset(_ assets: [ReleaseAsset], suffix: String = AppConfig.updateAssetSuffix) -> ReleaseAsset? {
        let wanted = suffix.lowercased()
        let images = assets.filter { $0.name.lowercased().hasSuffix(wanted) }
        for word in ["arm64", "aarch64", "apple-silicon", "universal"] {
            if let match = images.first(where: { $0.name.lowercased().contains(word) }) {
                return match
            }
        }
        // Skip builds that are clearly for Intel only.
        return images.first(where: { !$0.name.lowercased().contains("x86_64") && !$0.name.lowercased().contains("intel") })
            ?? images.first
    }

    /// The checksum file for `asset`: "<asset>.sha256" first, then a SHA256SUMS style list.
    public static func checksumAsset(for asset: ReleaseAsset, in assets: [ReleaseAsset]) -> ReleaseAsset? {
        let exact = (asset.name + ".sha256").lowercased()
        if let match = assets.first(where: { $0.name.lowercased() == exact }) { return match }
        return assets.first { ["sha256sums", "sha256sums.txt", "checksums.txt"].contains($0.name.lowercased()) }
    }

    /// The Ed25519 signature file for `asset`: "<asset>.sig".
    public static func signatureAsset(for asset: ReleaseAsset, in assets: [ReleaseAsset]) -> ReleaseAsset? {
        let exact = (asset.name + ".sig").lowercased()
        return assets.first { $0.name.lowercased() == exact }
    }
}

// MARK: - Checksums

public enum UpdateChecksum {
    /// Reads a SHA-256 from `shasum -a 256` output ("hash  name" or "hash *name"),
    /// BSD style ("SHA256 (name) = hash") or a bare hash. With several lines, the line
    /// for `fileName` wins. A single entry is accepted whatever its name.
    public static func parse(_ text: String, fileName: String? = nil) -> String? {
        var entries: [(hash: String, name: String?)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("SHA256 ("), let close = line.range(of: ") = ") {
                let name = String(line[line.index(line.startIndex, offsetBy: 8)..<close.lowerBound])
                let hash = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                if isHash(hash) { entries.append((hash.lowercased(), name)) }
                continue
            }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first, isHash(String(first)) else { continue }
            var name: String?
            if parts.count > 1 {
                var rest = parts[1].trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("*") { rest.removeFirst() }
                name = rest.isEmpty ? nil : rest
            }
            entries.append((String(first).lowercased(), name))
        }
        if let fileName {
            if let match = entries.first(where: { entry in
                guard let name = entry.name else { return false }
                return name == fileName || (name as NSString).lastPathComponent == fileName
            }) {
                return match.hash
            }
            return entries.count == 1 ? entries[0].hash : nil
        }
        return entries.first?.hash
    }

    static func isHash(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit }
    }

    /// SHA-256 of a file as lowercase hex. Reads in chunks, so big disk images are fine.
    public static func sha256(of url: URL) throws -> String {
        try sha256Digest(of: url).map { String(format: "%02x", $0) }.joined()
    }

    /// The raw 32 byte SHA-256 digest of a file (what the update signature covers).
    public static func sha256Digest(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    /// Throws `checksumMismatch` when the file does not match `expected`.
    public static func verify(file: URL, expected: String) throws {
        let actual = try sha256(of: file)
        let wanted = expected.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard actual == wanted else {
            throw UpdateInstallError.checksumMismatch(expected: wanted, actual: actual)
        }
    }
}

// MARK: - Code signatures

/// What `codesign -dv --verbose=2 <path>` says about a bundle (it prints to stderr).
public struct CodeSignInfo: Sendable, Equatable {
    public var isSigned: Bool
    public var isAdHoc: Bool
    public var identifier: String?
    /// nil when not set (ad hoc and unsigned code, and Apple's own apps).
    public var teamIdentifier: String?
    public var authorities: [String]
    public var hardenedRuntime: Bool
    public var notarizationStapled: Bool
    /// SHA-256 of the leaf signing certificate (from `SigningCertificate.leafHash`). Not in codesign -dv output.
    public var leafCertificateHash: String?

    public init(isSigned: Bool, isAdHoc: Bool = false, identifier: String? = nil, teamIdentifier: String? = nil,
                authorities: [String] = [], hardenedRuntime: Bool = false, notarizationStapled: Bool = false,
                leafCertificateHash: String? = nil) {
        self.isSigned = isSigned
        self.isAdHoc = isAdHoc
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.authorities = authorities
        self.hardenedRuntime = hardenedRuntime
        self.notarizationStapled = notarizationStapled
        self.leafCertificateHash = leafCertificateHash
    }

    public static let unsigned = CodeSignInfo(isSigned: false)

    /// Signed with an Apple Developer ID certificate.
    public var isDeveloperID: Bool {
        authorities.first?.hasPrefix("Developer ID Application:") == true
    }

    /// Signed with a real certificate (our self signed one or any other), not ad hoc.
    public var hasCertificate: Bool { isSigned && !isAdHoc && !authorities.isEmpty }

    public static func parse(_ output: String) -> CodeSignInfo {
        if output.contains("not signed at all") { return .unsigned }
        var info = CodeSignInfo(isSigned: false)
        var sawCodeDirectory = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "Identifier":
                info.identifier = value.isEmpty ? nil : value
            case "TeamIdentifier":
                info.teamIdentifier = (value.isEmpty || value == "not set") ? nil : value
            case "Authority":
                info.authorities.append(value)
            case "Signature":
                if value == "adhoc" { info.isAdHoc = true }
            case "Notarization Ticket":
                info.notarizationStapled = value == "stapled"
            case "CodeDirectory v":
                sawCodeDirectory = true
                if value.contains("(adhoc") || value.contains(",adhoc") { info.isAdHoc = true }
                if value.contains("runtime") { info.hardenedRuntime = true }
            default:
                break
            }
        }
        info.isSigned = sawCodeDirectory || info.identifier != nil
        return info
    }
}

public enum UpdateTrustDecision: Sendable, Equatable {
    case trusted
    /// Trusted, but the running app is a development build, so the team check was skipped.
    case trustedDevelopmentBuild
    case rejected(String)

    public var isTrusted: Bool {
        if case .rejected = self { return false }
        return true
    }
}

public enum UpdateTrust {
    /// Decides if `candidate` may replace the running app.
    /// - The new app must be signed and carry our bundle id (Info.plist and signature).
    /// - When the running app is signed with a certificate (releases use the self signed
    ///   AppConfig.codeSigningIdentity), the new app must be signed with the very same leaf
    ///   certificate (SHA-256 of the certificate). Unknown hashes fail closed.
    /// - Ad hoc or unsigned running apps are development builds, so the certificate check is skipped.
    public static func evaluate(running: CodeSignInfo?, candidate: CodeSignInfo,
                                candidateBundleID: String?, expectedBundleID: String) -> UpdateTrustDecision {
        guard candidate.isSigned else {
            return .rejected("The new version is not signed.")
        }
        guard candidateBundleID == expectedBundleID else {
            return .rejected("The downloaded app is not \(AppConfig.appName) (bundle id \(candidateBundleID ?? "missing")).")
        }
        if let identifier = candidate.identifier, identifier != expectedBundleID {
            return .rejected("The new version is signed as \(identifier), not \(expectedBundleID).")
        }
        guard let running, running.isSigned, !running.isAdHoc else {
            return .trustedDevelopmentBuild
        }
        guard let runningHash = running.leafCertificateHash, !runningHash.isEmpty else {
            return .rejected("The certificate of this copy could not be read.")
        }
        if candidate.isAdHoc {
            return .rejected("The new version is not signed with a certificate. This copy is.")
        }
        guard let candidateHash = candidate.leafCertificateHash, !candidateHash.isEmpty else {
            return .rejected("The certificate of the new version could not be read.")
        }
        guard candidateHash.lowercased() == runningHash.lowercased() else {
            let name = candidate.authorities.first ?? "another certificate"
            return .rejected("The new version is signed by \(name), not by the certificate this copy uses.")
        }
        return .trusted
    }

    /// The downloaded app must be newer than the running one. Unknown current version (dev build) passes.
    public static func isAcceptableVersion(candidate: String?, current: String?) -> Bool {
        guard let candidateText = candidate, let newVersion = ReleaseVersion(candidateText) else { return false }
        guard let currentText = current, let currentVersion = ReleaseVersion(currentText) else { return true }
        return currentVersion < newVersion
    }
}

// MARK: - When to check, offer and notify

public enum UpdatePolicy {
    /// True when no check ran yet or the last one is older than `interval`.
    public static func isDue(lastChecked: Date?, now: Date = Date(), interval: TimeInterval = AppConfig.updateCheckInterval) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval || now < lastChecked
    }

    /// True when the person pressed Later on exactly this version.
    public static func isSkipped(_ version: ReleaseVersion, skippedVersion: String?) -> Bool {
        guard let skippedVersion, let skipped = ReleaseVersion(skippedVersion) else { return false }
        return skipped == version
    }

    /// Show the update in the menu bar and alerts. A checked by hand update always shows.
    /// A skipped version stays quiet until an even newer one comes out.
    public static func shouldOffer(_ result: UpdateCheckResult?, skippedVersion: String?, userInitiated: Bool = false) -> Bool {
        guard let result, result.isUpdateAvailable else { return false }
        if userInitiated { return true }
        return !isSkipped(result.latest.version, skippedVersion: skippedVersion)
    }

    /// Post a notification only once per version, and never for a skipped one.
    public static func shouldNotify(_ result: UpdateCheckResult?, skippedVersion: String?, alreadyNotified: String?) -> Bool {
        guard shouldOffer(result, skippedVersion: skippedVersion), let result else { return false }
        if let alreadyNotified, ReleaseVersion(alreadyNotified) == result.latest.version { return false }
        return true
    }
}

// MARK: - Install location

public enum UpdateLocation {
    /// Why the app at `bundlePath` cannot replace itself, or nil when it can.
    /// `isWritable` is asked for the bundle and its parent folder.
    public static func problem(bundlePath: String, isWritable: (String) -> Bool) -> UpdateInstallError? {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        guard bundlePath.hasSuffix(".app") else { return .notWritable(bundlePath) }
        let parent = (bundlePath as NSString).deletingLastPathComponent
        if parent.hasPrefix("/Volumes/") && !isWritable(parent) { return .runningFromDiskImage }
        guard isWritable(parent), isWritable(bundlePath) else { return .notWritable(parent) }
        return nil
    }

    /// Picks the app from the names at the top of a mounted disk image.
    public static func pickAppBundle(_ names: [String], preferredName: String = AppConfig.appName + ".app") -> String? {
        let apps = names.filter { $0.hasSuffix(".app") && !$0.hasPrefix(".") }
        if apps.contains(preferredName) { return preferredName }
        return apps.sorted().first
    }
}
