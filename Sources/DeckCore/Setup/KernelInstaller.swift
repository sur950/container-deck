import Foundation

/// Installs Apple's recommended Linux kernel in a way that survives flaky networks.
///
/// `container system kernel set --recommended` downloads the 676 MB archive in one go,
/// with no resume and no retry, and a single dropped or altered byte ends in
/// "kernel archive digest mismatch". So the app downloads the archive itself
/// (`KernelDownloader`: resume, retries, SHA-256 check), then hands the checked local
/// file to Apple's tool, which unpacks and installs it exactly like `--recommended` does:
///
///     container system kernel set --tar <archive> --binary <member> --force
///
/// `--binary` takes the member as Apple's config stores it ("opt/kata/..."). Apple's
/// ArchiveReader trims "./" from both sides before comparing, so "./opt/..." works too,
/// and `--recommended` passes the same value.
public struct KernelInstaller: Sendable {
    public let cli: ContainerCLI
    public let downloader: KernelDownloader

    public init(cli: ContainerCLI, directory: URL = KernelInstaller.defaultDirectory(),
                configuration: URLSessionConfiguration = .default, policy: KernelDownloadPolicy = .standard) {
        self.cli = cli
        self.downloader = KernelDownloader(directory: directory, configuration: configuration, policy: policy)
    }

    /// Application Support/<bundle id>/Kernel.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let id = Bundle.main.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? AppConfig.bundleID
        return base.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(AppConfig.kernelDownloadFolder, isDirectory: true)
    }

    /// Deletes a partial or finished download left from an earlier try. The app calls it
    /// once the kernel check passes.
    public static func removeLeftoverDownloads(directory: URL = defaultDirectory()) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Arguments for installing from the local archive.
    public static func setArguments(archive: URL, binaryPath: String) -> [String] {
        ["system", "kernel", "set", "--tar", archive.path, "--binary", binaryPath, "--force"]
    }

    /// The kernel the installed `container` recommends (its merged config, so a custom
    /// `kernel.url` in config.toml is honoured). Falls back to the tested values in
    /// `AppConfig.kernelDefaults` when the tool cannot answer, for example while the
    /// service is stopped.
    public func recommendedSource() async -> KernelSource {
        if let result = try? await cli.run(["system", "property", "list", "--format", "json"]), result.succeeded,
           let properties = try? ContainerOutputParser.systemProperties(result.stdout),
           let source = KernelSource.from(properties: properties) {
            return source
        }
        let version = (try? await cli.version()) ?? nil
        return KernelSource.builtIn(for: version)
    }

    /// Downloads, checks and installs the kernel, then deletes the archive.
    /// Throws `KernelInstallError`, or `CancellationError` when cancelled during the download.
    /// A cancelled download is deleted. After a network error the partial file stays, so
    /// trying again resumes it.
    public func install(source given: KernelSource? = nil, progress: @escaping @Sendable (KernelInstallStage) -> Void) async throws {
        progress(.preparing)
        let source: KernelSource
        if let given { source = given } else { source = await recommendedSource() }
        let archive: URL
        do {
            archive = try await downloader.fetch(source, progress: progress)
            try Task.checkCancellation()
        } catch is CancellationError {
            downloader.removeDownloads()
            throw CancellationError()
        }

        if !((try? await cli.isServiceRunning()) ?? false) {
            progress(.startingService)
            let start = try await cli.startService()
            guard start.succeeded else {
                var error = KernelInstallError.fromCLI(start, command: "container system start --disable-kernel-install")
                if case .installFailed(let details) = error {
                    error = .other(message: "The container service did not start. Start it from the Dashboard, then try again.", details: details)
                }
                throw error
            }
        }

        progress(.installing)
        let arguments = Self.setArguments(archive: archive, binaryPath: source.binaryPath)
        let result: CommandResult
        do {
            result = try await cli.run(arguments)
        } catch {
            throw KernelInstallError.installFailed(details: "$ container \(arguments.joined(separator: " "))\n\(error.localizedDescription)")
        }
        guard result.succeeded else {
            // The checked archive stays, so Try Again skips the download.
            throw KernelInstallError.fromCLI(result, command: "container " + arguments.joined(separator: " "))
        }
        downloader.removeDownloads()
    }
}
