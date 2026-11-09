import Foundation

/// The kernel archive to download and the kernel file inside it.
public struct KernelSource: Sendable, Equatable {
    public enum Origin: String, Sendable, Equatable {
        /// Read from the installed `container` (`system property list`).
        case installedTool
        /// The tested values in `AppConfig.kernelDefaults`.
        case builtIn
    }

    public var url: URL
    /// `sha256:<hex>` of the archive.
    public var digest: String
    /// Archive member, as Apple's config stores it (no leading "./").
    public var binaryPath: String
    /// Archive size in bytes when known ahead of the download.
    public var expectedSize: Int64?
    public var origin: Origin

    public init(url: URL, digest: String, binaryPath: String, expectedSize: Int64?, origin: Origin) {
        self.url = url
        self.digest = digest
        self.binaryPath = binaryPath
        self.expectedSize = expectedSize
        self.origin = origin
    }

    /// Lowercase hex of the SHA-256 digest. nil when the digest is not `sha256:` and 64 hex digits.
    public var sha256Hex: String? {
        let lower = digest.trimmingCharacters(in: .whitespaces).lowercased()
        guard lower.hasPrefix("sha256:") else { return nil }
        let hex = String(lower.dropFirst(7))
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// File name for the download, like kata-static-4.3.1-arm64.tar.zst.
    public var fileName: String {
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? "kernel.tar" : name
    }

    /// Reads `kernel.url`, `kernel.digest` and `kernel.binaryPath` from `system property list`.
    /// nil when one is missing or not usable (releases before 1.3 had no digest).
    public static func from(properties: [SystemProperty]) -> KernelSource? {
        func value(_ key: String) -> String? {
            guard let text = properties.first(where: { $0.key == key })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }
        guard let urlText = value("kernel.url"), let url = URL(string: urlText),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let digest = value("kernel.digest"), let binary = value("kernel.binaryPath") else { return nil }
        let known = AppConfig.kernelDefaults.first { $0.url == urlText && $0.digest.lowercased() == digest.lowercased() }
        let source = KernelSource(url: url, digest: digest, binaryPath: binary, expectedSize: known?.size, origin: .installedTool)
        return source.sha256Hex == nil ? nil : source
    }

    /// The tested values for this `container` version. Unknown versions get the newest entry.
    public static func builtIn(for version: SemanticVersion?) -> KernelSource {
        let list = AppConfig.kernelDefaults
        let pick = version.flatMap { v in list.first { $0.from <= v } } ?? list[0]
        return KernelSource(
            url: URL(string: pick.url)!,
            digest: pick.digest,
            binaryPath: pick.binaryPath,
            expectedSize: pick.size,
            origin: .builtIn
        )
    }
}

/// Download progress for the kernel archive.
public struct KernelDownloadProgress: Sendable, Equatable {
    public var receivedBytes: Int64
    /// 0 when the size is not known yet.
    public var totalBytes: Int64
    public var bytesPerSecond: Double
    /// 1 for the first try. Higher after a dropped connection.
    public var attempt: Int
    /// True on the fresh download after a damaged one.
    public var isFreshRetry: Bool

    public init(receivedBytes: Int64, totalBytes: Int64, bytesPerSecond: Double, attempt: Int = 1, isFreshRetry: Bool = false) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.attempt = attempt
        self.isFreshRetry = isFreshRetry
    }

    public var fraction: Double? {
        totalBytes > 0 ? min(1, max(0, Double(receivedBytes) / Double(totalBytes))) : nil
    }

    /// "312 MB of 676 MB", or "312 MB" while the size is unknown. Decimal megabytes, like Finder.
    public var sizeText: String {
        let done = Self.megabytes(receivedBytes)
        return totalBytes > 0 ? "\(done) of \(Self.megabytes(totalBytes))" : done
    }

    /// "8.4 MB/s", "640 KB/s", or nil before the first sample.
    public var speedText: String? {
        guard bytesPerSecond >= 1 else { return nil }
        if bytesPerSecond >= 10_000_000 { return "\(Int(bytesPerSecond / 1_000_000)) MB/s" }
        if bytesPerSecond >= 1_000_000 { return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000) }
        return "\(max(1, Int(bytesPerSecond / 1_000))) KB/s"
    }

    static func megabytes(_ bytes: Int64) -> String {
        "\(max(0, bytes) / 1_000_000) MB"
    }
}

/// What the kernel installer is doing.
public enum KernelInstallStage: Sendable, Equatable {
    /// Reading the recommended kernel from `container`.
    case preparing
    case downloading(KernelDownloadProgress)
    /// Checking the SHA-256 of the archive.
    case verifying
    case startingService
    /// `container system kernel set` is running. Cannot be cancelled.
    case installing

    public var title: String {
        switch self {
        case .preparing: return "Getting ready"
        case .downloading(let p): return p.isFreshRetry ? "Downloading the kernel again" : "Downloading the Linux kernel"
        case .verifying: return "Checking the download"
        case .startingService: return "Starting the container service"
        case .installing: return "Installing the kernel"
        }
    }

    public var canCancel: Bool {
        switch self {
        case .installing, .startingService: return false
        default: return true
        }
    }
}

/// Why the kernel install stopped, in plain words, with the raw text for a Details view.
public enum KernelInstallError: LocalizedError, Equatable, Sendable {
    /// The archive did not match its digest, also after one fresh download.
    case damaged(details: String)
    case offline(details: String)
    case timedOut(details: String)
    /// GitHub answered with an HTTP error.
    case server(status: Int, details: String)
    case diskFull(neededBytes: Int64)
    /// `container system kernel set` failed.
    case installFailed(details: String)
    case other(message: String, details: String)

    public static let damagedMessage = "The kernel download was damaged on the way, often by a VPN or proxy. Try again, or use another network."

    public var message: String {
        switch self {
        case .damaged:
            return Self.damagedMessage
        case .offline:
            return "Could not reach GitHub to download the kernel. Check your internet connection and try again."
        case .timedOut:
            return "The kernel download stopped responding. Check your connection and try again."
        case .server(let status, _):
            return "GitHub did not send the kernel (error \(status)). Try again in a few minutes."
        case .diskFull(let needed):
            return "Not enough free disk space. The kernel needs about \(KernelDownloadProgress.megabytes(needed)) free."
        case .installFailed:
            return "The kernel downloaded fine, but Apple's container tool could not install it. Try again, or open Details."
        case .other(let message, _):
            return message
        }
    }

    public var details: String {
        switch self {
        case .damaged(let d), .offline(let d), .timedOut(let d), .server(_, let d), .installFailed(let d), .other(_, let d):
            return d
        case .diskFull(let needed):
            return "Needed: \(needed) bytes."
        }
    }

    public var errorDescription: String? { message }

    // MARK: - Reading the CLI's error text

    /// Maps the output of a failed `container system kernel set` to a plain error.
    /// `command` goes first in the details so people can run it again in Terminal.
    public static func fromCLI(_ result: CommandResult, command: String) -> KernelInstallError {
        let raw = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let details = "$ \(command)\n" + (raw.isEmpty ? "Exit code \(result.exitCode)" : raw)
        if KernelDigestMismatch.parse(raw) != nil { return .damaged(details: details) }
        let lower = raw.lowercased()
        if timeoutMarkers.contains(where: lower.contains) { return .timedOut(details: details) }
        if offlineMarkers.contains(where: lower.contains) { return .offline(details: details) }
        return .installFailed(details: details)
    }

    static let timeoutMarkers = ["timed out", "error -1001", "code=-1001"]
    static let offlineMarkers = [
        "appears to be offline", "not connected to the internet", "could not connect to the server",
        "network connection was lost", "hostname could not be found", "dns lookup",
        "error -1009", "code=-1009", "error -1004", "code=-1004", "error -1005", "code=-1005", "error -1003", "code=-1003"
    ]
}

/// "kernel archive digest mismatch: expected sha256:<hex>, got sha256:<hex>" from Apple's KernelService.
public struct KernelDigestMismatch: Sendable, Equatable {
    public var expected: String
    public var actual: String

    public static func parse(_ text: String) -> KernelDigestMismatch? {
        let pattern = #"digest mismatch: expected (sha256:[0-9a-fA-F]{64}), got (sha256:[0-9a-fA-F]{64})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return KernelDigestMismatch(
            expected: ns.substring(with: match.range(at: 1)).lowercased(),
            actual: ns.substring(with: match.range(at: 2)).lowercased()
        )
    }
}
