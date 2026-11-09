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
    /// A compulsory update (UpdateRequirementRule), from every release the check read.
    public let requirement: UpdateRequirement?
    /// False when the releases list was needed but could not be read, so `requirement`
    /// only knows the latest release. A remembered compulsory update is kept then.
    public let requirementIsComplete: Bool

    public init(latest: AppRelease, current: ReleaseVersion?,
                requirement: UpdateRequirement? = nil, requirementIsComplete: Bool = true) {
        self.latest = latest
        self.current = current
        self.requirement = requirement
        self.requirementIsComplete = requirementIsComplete
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
        try Self.parseRelease(try await get("releases/latest"))
    }

    /// Fetches the newest releases, newest first, for the compulsory update rule.
    /// One page is enough: only releases newer than the running app matter.
    public func recentReleases(count: Int = 50) async throws -> [AppRelease] {
        try Self.parseReleaseList(try await get("releases?per_page=\(min(max(count, 1), 100))"))
    }

    /// GET on the repository's API. 404 means no release yet.
    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/\(path)") else {
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
            return data
        case 404:
            throw UpdateCheckError.noRelease
        default:
            throw UpdateCheckError.badResponse(status)
        }
    }

    /// Fetches the latest release and compares it with `currentVersion`
    /// (the app's CFBundleShortVersionString).
    /// Usually one request. The releases list is read too only when a newer version exists
    /// and the latest release alone does not make the update compulsory.
    public func check(currentVersion: String?) async throws -> UpdateCheckResult {
        let latest = try await latestRelease()
        let current = currentVersion.flatMap { ReleaseVersion($0) }
        guard UpdateRequirementRule.needsReleaseList(current: current, latest: latest) else {
            return Self.evaluate(latest: latest, currentVersion: currentVersion)
        }
        do {
            let releases = try await recentReleases()
            return Self.evaluate(latest: latest, currentVersion: currentVersion, releases: releases)
        } catch {
            // Rate limited or offline after the first call: still report the update itself.
            return Self.evaluate(latest: latest, currentVersion: currentVersion, requirementIsComplete: false)
        }
    }

    /// Compares `latest` with the running version. `releases` are other published releases
    /// the compulsory update rule should also look at.
    public static func evaluate(latest: AppRelease, currentVersion: String?, releases: [AppRelease] = [],
                                requirementIsComplete: Bool = true) -> UpdateCheckResult {
        let current = currentVersion.flatMap { ReleaseVersion($0) }
        let requirement = UpdateRequirementRule.evaluate(current: current, releases: [latest] + releases)
        return UpdateCheckResult(latest: latest, current: current, requirement: requirement,
                                 requirementIsComplete: requirementIsComplete)
    }

    /// Reads the GitHub "get release" JSON.
    public static func parseRelease(_ data: Data) throws -> AppRelease {
        let release: GitHubRelease
        do {
            release = try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw DeckError.parse("the GitHub release")
        }
        return try makeRelease(release)
    }

    /// Reads the GitHub "list releases" JSON. Drafts and tags that are not versions are skipped.
    public static func parseReleaseList(_ data: Data) throws -> [AppRelease] {
        let list: [GitHubRelease]
        do {
            list = try decoder.decode([GitHubRelease].self, from: data)
        } catch {
            throw DeckError.parse("the GitHub releases")
        }
        return list.filter { $0.draft != true }.compactMap { try? makeRelease($0) }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeRelease(_ release: GitHubRelease) throws -> AppRelease {
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

/// The fields of a GitHub release that the updater reads.
private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int?
    }
    let tag_name: String
    let name: String?
    let body: String?
    let html_url: URL
    let published_at: Date?
    let prerelease: Bool?
    let draft: Bool?
    let assets: [Asset]?
}
