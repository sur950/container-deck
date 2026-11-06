import Foundation
import CryptoKit

/// Installs the `container compose` plugin the app ships with into
/// /usr/local/libexec/container-plugins/compose. Needs one admin prompt.
/// Apple's installer wipes that folder on upgrade, so the app checks again
/// and offers to put it back. Never runs on its own.
public struct ComposePluginInstaller: Sendable {
    public enum Status: String, Sendable, Equatable {
        /// This build has no plugin binary next to the app (a plain `swift run` without it).
        case notBundled
        case notInstalled
        /// It was installed before and is gone now, most likely after a `container` upgrade.
        case removedByUpgrade
        /// Installed, but a different build than the one in the app.
        case outdated
        case installed
    }

    /// The plugin binary inside the app (or next to the dev build). nil when missing.
    public var bundledBinary: String?
    public var installDirectory: String
    public var fileExists: @Sendable (String) -> Bool
    public var readFile: @Sendable (String) -> Data?

    public init(
        bundledBinary: String? = ComposePluginInstaller.defaultBundledBinary(),
        installDirectory: String = ComposePlugin.installDirectory,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        readFile: @escaping @Sendable (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    ) {
        self.bundledBinary = bundledBinary
        self.installDirectory = installDirectory
        self.fileExists = fileExists
        self.readFile = readFile
    }

    public var installedBinary: String { "\(installDirectory)/bin/\(ComposePlugin.name)" }
    public var installedConfig: String { "\(installDirectory)/config.toml" }

    /// `Contents/MacOS/container-compose` in the app, or next to the dev executable.
    public static func defaultBundledBinary() -> String? {
        let candidates = [
            Bundle.main.url(forAuxiliaryExecutable: ComposePlugin.executableName)?.path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(ComposePlugin.executableName).path
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Where things stand. `previouslyInstalled` is the app's memory of an earlier install.
    public func status(previouslyInstalled: Bool) -> Status {
        let present = fileExists(installedBinary) && fileExists(installedConfig)
        guard present else {
            if bundledBinary == nil { return .notBundled }
            return previouslyInstalled ? .removedByUpgrade : .notInstalled
        }
        guard let bundledBinary else { return .installed }
        guard let ours = readFile(bundledBinary), let theirs = readFile(installedBinary) else { return .outdated }
        return Self.digest(ours) == Self.digest(theirs) ? .installed : .outdated
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Commands that copy the binary and `configFile` into place. Run as admin.
    public func installCommands(binary: String, configFile: String) -> [[String]] {
        [
            ["/bin/mkdir", "-p", "\(installDirectory)/bin"],
            ["/usr/bin/install", "-m", "0755", binary, installedBinary],
            ["/usr/bin/install", "-m", "0644", configFile, installedConfig]
        ]
    }

    public func removeCommands() -> [[String]] {
        [["/bin/rm", "-rf", installDirectory]]
    }

    /// Copies the plugin into place with one admin prompt.
    public func install(runner: any CommandRunning) async throws {
        guard let bundledBinary else {
            throw DeckError.commandFailed("This build does not include the container compose command.")
        }
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("deck-compose-config-\(UUID().uuidString).toml")
        try ComposePlugin.configTOML.write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: config) }
        try await PrivilegedRunner(runner: runner).run(installCommands(binary: bundledBinary, configFile: config.path)).orThrow()
    }

    public func remove(runner: any CommandRunning) async throws {
        try await PrivilegedRunner(runner: runner).run(removeCommands()).orThrow()
    }

    /// Asks Apple's CLI for the plugin. True when `container compose version` answers.
    /// False also when the container services are not running (plugins need them).
    public static func verify(client: ContainerClient) async -> Bool {
        guard let result = try? await client.runner.run(client.cliPath, [ComposePlugin.name, "version"]) else { return false }
        return result.succeeded && result.stdout.contains("container compose version")
    }
}
