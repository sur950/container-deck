import Foundation

public struct PlatformRelease: Sendable, Equatable {
    public let version: String
    public let packageName: String
    public let packageURL: URL
}

/// Downloads and installs Apple's signed `container` package from GitHub Releases.
public struct PlatformInstaller: Sendable {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/apple/container/releases/latest")!

    let runner: any CommandRunning
    let session: URLSession

    public init(runner: any CommandRunning, session: URLSession = .shared) {
        self.runner = runner
        self.session = session
    }

    public func latestRelease() async throws -> PlatformRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ContainerDeck", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if let http = response as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 429 {
                throw DeckError.network("GitHub is limiting requests. Try again in a few minutes.")
            }
            throw DeckError.network("GitHub did not return the latest release.")
        }
        return try Self.parseRelease(data)
    }

    static func parseRelease(_ data: Data) throws -> PlatformRelease {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        struct Release: Decodable {
            let tag_name: String
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let packages = release.assets.filter { $0.name.lowercased().hasSuffix(".pkg") }
        // "unsigned" also contains "signed", so rule it out first.
        func isUnsigned(_ name: String) -> Bool { name.lowercased().contains("unsigned") }
        let signed = packages.filter { !isUnsigned($0.name) }
        guard let asset = signed.first(where: { $0.name.lowercased().contains("signed") }) ?? signed.first else {
            throw DeckError.noInstallerFound
        }
        return PlatformRelease(
            version: release.tag_name,
            packageName: asset.name,
            packageURL: asset.browser_download_url
        )
    }

    /// Downloads the package into a fresh temporary folder.
    public func download(_ release: PlatformRelease) async throws -> URL {
        let (tempURL, response) = try await session.download(from: release.packageURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DeckError.network("Could not download \(release.packageName).")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainerDeck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(release.packageName)
        try FileManager.default.moveItem(at: tempURL, to: target)
        return target
    }

    /// Makes sure the package is signed by Apple before we install it.
    public func verifySignature(of package: URL) async throws {
        let result = try await runner.run("/usr/sbin/pkgutil", ["--check-signature", package.path])
        let text = result.stdout
        guard result.succeeded, text.contains("Status: signed"), text.contains("Apple Inc.") else {
            throw DeckError.signatureInvalid(result.failureMessage)
        }
    }

    /// Installs the package. macOS asks for an admin password once.
    public func install(_ package: URL) async throws {
        let admin = PrivilegedRunner(runner: runner)
        try await admin.run("/usr/sbin/installer", ["-pkg", package.path, "-target", "/"]).orThrow()
        try? FileManager.default.removeItem(at: package.deletingLastPathComponent())
    }
}
