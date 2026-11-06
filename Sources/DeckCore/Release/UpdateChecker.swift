import Foundation

/// One downloadable file attached to a GitHub release.
public struct ReleaseAsset: Sendable, Equatable {
    public let name: String
    public let url: URL
    public let sizeBytes: Int?

    public init(name: String, url: URL, sizeBytes: Int? = nil) {
        self.name = name
        self.url = url
        self.sizeBytes = sizeBytes
    }
}

/// A published Container Deck release.
public struct AppRelease: Sendable, Equatable {
    public let version: ReleaseVersion
    public let tagName: String
    public let title: String
    /// Release notes in GitHub Markdown.
    public let notes: String
    /// The release page on GitHub.
    public let pageURL: URL
    public let publishedAt: Date?
    public let isPrerelease: Bool
    public let assets: [ReleaseAsset]
    /// The disk image to install (`AppConfig.updateAssetSuffix`), if the release has one.
    public let diskImage: ReleaseAsset?

    public init(
        version: ReleaseVersion,
        tagName: String,
        title: String,
        notes: String,
        pageURL: URL,
        publishedAt: Date?,
        isPrerelease: Bool,
        assets: [ReleaseAsset]
    ) {
        self.version = version
        self.tagName = tagName
        self.title = title
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.assets = assets
        self.diskImage = UpdateChecker.pickDiskImage(assets)
    }

    /// The disk image when there is one, else the release page.
    public var downloadURL: URL { diskImage?.url ?? pageURL }

    /// The "<asset>.sha256" (or SHA256SUMS) file for the disk image, if published.
    public var checksumAsset: ReleaseAsset? {
        diskImage.flatMap { UpdateAssets.checksumAsset(for: $0, in: assets) }
    }
}

/// Result of comparing the running app with the latest release.
public struct UpdateCheckResult: Sendable, Equatable {
    public let latest: AppRelease
    /// nil when the running build has no readable version (for example `swift run`).
    public let current: ReleaseVersion?

    public init(latest: AppRelease, current: ReleaseVersion?) {
        self.latest = latest
        self.current = current
    }

    public var isUpdateAvailable: Bool {
        guard let current else { return false }
        return current < latest.version
    }
}

public enum UpdateCheckError: LocalizedError, Equatable {
    case noRelease
    case badResponse(Int)
    case unreadableVersion(String)

    public var errorDescription: String? {
        switch self {
        case .noRelease:
            return "No release is published yet."
        case .badResponse(let code):
            return code == 403 || code == 429
                ? "GitHub is limiting requests right now. Try again later."
                : "GitHub returned an error (\(code))."
        case .unreadableVersion(let tag):
            return "The latest release tag \(tag) is not a version number."
        }
    }
}

/// Checks GitHub Releases for a newer Container Deck. No third party code.
public struct UpdateChecker: Sendable {
    public static let defaultRepository = AppConfig.repository

    public let repository: String
    let session: URLSession

    public init(repository: String = UpdateChecker.defaultRepository, session: URLSession = .shared) {
        self.repository = repository
        self.session = session
    }

    /// The releases page, used when there is nothing better to open.
    public var releasesPageURL: URL? {
        URL(string: "https://github.com/\(repository)/releases")
    }

    /// Fetches the latest published release (drafts and pre-releases are skipped by GitHub).
    public func latestRelease() async throws -> AppRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw DeckError.network("The update address is not valid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ContainerDeck", forHTTPHeaderField: "User-Agent")

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw DeckError.network(error.localizedDescription)
        }
        let (data, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return try Self.parseRelease(data)
        case 404:
            throw UpdateCheckError.noRelease
        default:
            throw UpdateCheckError.badResponse(status)
        }
    }

    /// Fetches the latest release and compares it with `currentVersion`
    /// (the app's CFBundleShortVersionString).
    public func check(currentVersion: String?) async throws -> UpdateCheckResult {
        let latest = try await latestRelease()
        return Self.evaluate(latest: latest, currentVersion: currentVersion)
    }

    public static func evaluate(latest: AppRelease, currentVersion: String?) -> UpdateCheckResult {
        let current = currentVersion.flatMap { ReleaseVersion($0) }
        return UpdateCheckResult(latest: latest, current: current)
    }

    /// Reads the GitHub "get release" JSON.
    public static func parseRelease(_ data: Data) throws -> AppRelease {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int?
        }
        struct Release: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: URL
            let published_at: Date?
            let prerelease: Bool?
            let assets: [Asset]?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release: Release
        do {
            release = try decoder.decode(Release.self, from: data)
        } catch {
            throw DeckError.parse("the GitHub release")
        }
        guard let version = ReleaseVersion(release.tag_name) else {
            throw UpdateCheckError.unreadableVersion(release.tag_name)
        }
        let assets = (release.assets ?? []).map {
            ReleaseAsset(name: $0.name, url: $0.browser_download_url, sizeBytes: $0.size)
        }
        let title = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AppRelease(
            version: version,
            tagName: release.tag_name,
            title: title.isEmpty ? "\(AppConfig.appName) \(version)" : title,
            notes: release.body ?? "",
            pageURL: release.html_url,
            publishedAt: release.published_at,
            isPrerelease: release.prerelease ?? false,
            assets: assets
        )
    }

    /// Picks the installable asset (name ends with `AppConfig.updateAssetSuffix`).
    /// Prefers an Apple silicon or universal build when there are several.
    public static func pickDiskImage(_ assets: [ReleaseAsset]) -> ReleaseAsset? {
        UpdateAssets.pickInstallAsset(assets)
    }
}
