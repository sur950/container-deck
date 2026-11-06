import Foundation
import CryptoKit

/// Gets `cloudflared` for quick tunnels. Two ways, both started by the person:
/// Homebrew (`brew install cloudflared`), or a direct download of Cloudflare's signed
/// release into Application Support, checked against the SHA-256 GitHub publishes.
public struct CloudflaredInstaller: Sendable {
    public struct Release: Sendable, Equatable {
        public var version: String
        public var downloadURL: URL
        public var sha256: String
        public var size: Int?
    }

    let runner: any CommandRunning
    let destination: URL

    public init(runner: any CommandRunning = ProcessRunner(), destination: URL = DomainsConfig.toolsDirectory()) {
        self.runner = runner
        self.destination = destination
    }

    public var installedPath: String { destination.appendingPathComponent("cloudflared").path }

    /// Reads the latest release from GitHub's API JSON. Needs a published digest.
    public static func release(fromJSON data: Data, asset: String = DomainsConfig.cloudflaredAsset) throws -> Release {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let size: Int?
                let digest: String?
                let browser_download_url: String
            }
            let tag_name: String
            let assets: [Asset]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw DeckError.parse("the cloudflared release list")
        }
        guard let match = payload.assets.first(where: { $0.name == asset }),
              let url = URL(string: match.browser_download_url) else {
            throw DeckError.commandFailed("The latest cloudflared release has no \(asset).")
        }
        guard let digest = match.digest, digest.hasPrefix("sha256:"), digest.count == 7 + 64 else {
            throw DeckError.commandFailed("The cloudflared release has no checksum, so it was not installed.")
        }
        return Release(version: payload.tag_name, downloadURL: url, sha256: String(digest.dropFirst(7)).lowercased(), size: match.size)
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ data: Data, expected: String) throws {
        let actual = sha256Hex(of: data)
        guard actual == expected.lowercased() else {
            throw DeckError.signatureInvalid("Checksum did not match (expected \(expected.prefix(12)), got \(actual.prefix(12))).")
        }
    }

    /// Downloads, checks the checksum and the code signature, then installs into Application Support.
    public func installDirect(session: URLSession = .shared) async throws -> String {
        let api = URL(string: "https://api.github.com/repos/\(DomainsConfig.cloudflaredRepository)/releases/latest")!
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (json, _) = try await session.data(for: request)
        let release = try Self.release(fromJSON: json)
        let (archive, response) = try await session.data(from: release.downloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DeckError.network("Download failed with status \(http.statusCode).")
        }
        try Self.verify(archive, expected: release.sha256)

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("deck-cloudflared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent(DomainsConfig.cloudflaredAsset)
        try archive.write(to: file)
        try await runner.run("/usr/bin/tar", ["-xzf", file.path, "-C", work.path]).orThrow()
        let binary = work.appendingPathComponent("cloudflared")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw DeckError.commandFailed("The cloudflared download did not contain the program.")
        }
        try await runner.run("/usr/bin/codesign", ["--verify", "--strict", binary.path]).orThrow()

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent("cloudflared")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: binary, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target.path
    }

    /// `brew install cloudflared`.
    public func installWithHomebrew(brew: String) async throws {
        try await runner.run(brew, ["install", "cloudflared"]).orThrow()
    }

    public func remove() throws {
        let target = destination.appendingPathComponent("cloudflared")
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    /// `cloudflared --version` first line, like "cloudflared version 2026.3.0 (built ...)".
    public func version(at path: String) async -> String? {
        guard let result = try? await runner.run(path, ["--version"]), result.succeeded else { return nil }
        let text = result.stdout.isEmpty ? result.stderr : result.stdout
        return SemanticVersion.firstMatch(in: text).map { "\($0)" } ?? text.split(separator: "\n").first.map(String.init)
    }
}
