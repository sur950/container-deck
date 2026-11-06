import Foundation

/// Public GitHub numbers for the About page: stars, forks and downloads of release files.
public struct RepoStats: Sendable, Equatable {
    public var stars: Int
    public var forks: Int
    public var downloads: Int
    public var openIssues: Int

    public init(stars: Int, forks: Int, downloads: Int, openIssues: Int = 0) {
        self.stars = stars
        self.forks = forks
        self.downloads = downloads
        self.openIssues = openIssues
    }
}

public enum RepoStatsError: Error, LocalizedError, Equatable {
    case notPublished
    case rateLimited
    case badResponse(Int)

    public var errorDescription: String? {
        switch self {
        case .notPublished: return "The repository is not public yet."
        case .rateLimited: return "GitHub is busy. Try again later."
        case .badResponse(let code): return "GitHub answered with code \(code)."
        }
    }
}

/// Reads RepoStats from the GitHub REST API. No sign in needed for public repositories.
public struct RepoStatsClient: Sendable {
    public let repository: String
    private let session: URLSession

    public init(repository: String = AppConfig.repository, session: URLSession = .shared) {
        self.repository = repository
        self.session = session
    }

    public func fetch() async throws -> RepoStats {
        let repo = try await get("https://api.github.com/repos/\(repository)")
        // Up to 100 releases is plenty. Download counts are summed over every asset.
        let releases = (try? await get("https://api.github.com/repos/\(repository)/releases?per_page=100")) ?? Data("[]".utf8)
        return try Self.parse(repository: repo, releases: releases)
    }

    private func get(_ url: String) async throws -> Data {
        guard let url = URL(string: url) else { throw RepoStatsError.badResponse(0) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(AppConfig.appName.replacingOccurrences(of: " ", with: ""), forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return data
        case 404: throw RepoStatsError.notPublished
        case 403, 429: throw RepoStatsError.rateLimited
        default: throw RepoStatsError.badResponse(code)
        }
    }

    /// True for release files people install from: `.pkg` and `.dmg`.
    static func isInstaller(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name.hasSuffix(".pkg") || name.hasSuffix(".dmg")
    }

    /// Pure parser, used by tests.
    public static func parse(repository: Data, releases: Data) throws -> RepoStats {
        guard let repo = try JSONSerialization.jsonObject(with: repository) as? [String: Any] else {
            throw RepoStatsError.badResponse(200)
        }
        let list = (try? JSONSerialization.jsonObject(with: releases)) as? [[String: Any]] ?? []
        // Installer downloads only: the .pkg and .dmg. Checksum and signature files are fetched by
        // scripts and the updater, so counting them would inflate the number.
        let downloads = list.reduce(0) { total, release in
            let assets = release["assets"] as? [[String: Any]] ?? []
            return total + assets.reduce(0) { sum, asset in
                guard isInstaller(asset["name"] as? String) else { return sum }
                return sum + (((asset["download_count"] as? NSNumber)?.intValue) ?? 0)
            }
        }
        return RepoStats(
            stars: (repo["stargazers_count"] as? NSNumber)?.intValue ?? 0,
            forks: (repo["forks_count"] as? NSNumber)?.intValue ?? 0,
            downloads: downloads,
            openIssues: (repo["open_issues_count"] as? NSNumber)?.intValue ?? 0
        )
    }
}
