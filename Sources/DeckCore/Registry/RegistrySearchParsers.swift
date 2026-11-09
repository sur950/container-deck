import Foundation

// Pure parsers for registry search answers. Tested with saved real responses.

/// Quay's public search: `GET https://quay.io/api/v1/find/repositories?query=...&page=N`.
public enum QuaySearch {
    public static func url(_ query: String, page: Int) -> URL? {
        var components = URLComponents(string: "https://quay.io/api/v1/find/repositories")
        components?.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "page", value: String(max(page, 1)))]
        return components?.url
    }

    /// Images and whether another page exists.
    public static func parse(_ data: Data) throws -> (images: [RegistryImage], hasMore: Bool) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw DeckError.parse("Quay search")
        }
        var seen = Set<String>()
        var images: [RegistryImage] = []
        for item in results {
            if let kind = item["kind"] as? String, kind != "repository" { continue }
            guard let name = CLIText.nonEmpty(item["name"] as? String) else { continue }
            let namespace = (item["namespace"] as? [String: Any])?["name"] as? String
            guard let owner = CLIText.nonEmpty(namespace) else { continue }
            let path = "\(owner)/\(name)"
            guard seen.insert(path).inserted else { continue }
            images.append(RegistryImage(
                registry: "quay.io",
                repository: path,
                description: RegistryText.summary(item["description"] as? String),
                isPrivate: (item["is_public"] as? Bool).map { !$0 } ?? false
            ))
        }
        return (images, root["has_additional"] as? Bool ?? false)
    }

    /// Quay's tag API, newest first, with dates and sizes:
    /// `GET https://quay.io/api/v1/repository/<org>/<name>/tag/?limit=N&page=N&onlyActiveTags=true`.
    public static func tagsURL(_ repository: String, page: Int, limit: Int = 50) -> URL? {
        var components = URLComponents(string: "https://quay.io/api/v1/repository/\(repository)/tag/")
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "onlyActiveTags", value: "true")
        ]
        return components?.url
    }

    public static func parseTags(_ data: Data, page: Int) throws -> HubPage<HubTag> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["tags"] as? [[String: Any]] else {
            throw DeckError.parse("Quay tags")
        }
        let tags: [HubTag] = list.compactMap { item in
            guard let name = CLIText.nonEmpty(item["name"] as? String) else { return nil }
            let size = (item["size"] as? NSNumber)?.uint64Value ?? 0
            var date: Date?
            if let text = item["last_modified"] as? String { date = Self.dateFormatter.date(from: text) }
            if date == nil, let start = (item["start_ts"] as? NSNumber)?.doubleValue { date = Date(timeIntervalSince1970: start) }
            return HubTag(name: name, sizeBytes: size, lastUpdated: date)
        }
        let more = root["has_additional"] as? Bool ?? false
        return HubPage(items: tags, nextPage: more && !tags.isEmpty ? page + 1 : nil)
    }

    /// "Sat, 24 Oct 2026 17:31:25 -0000"
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}

/// Harbor's search: `GET /api/v2.0/search?q=...`. Works without a sign in for
/// public projects, and with basic credentials for private ones.
public enum HarborSearch {
    public static func url(source: RegistrySource, query: String) -> URL? {
        var components = URLComponents(string: "\(source.scheme)://\(source.host)/api/v2.0/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// nil when the answer is not Harbor's search shape (so the host is not a Harbor).
    public static func parse(_ data: Data, registry: String) -> [RegistryImage]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["repository"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        return list.compactMap { item in
            guard let name = CLIText.nonEmpty(item["repository_name"] as? String), seen.insert(name).inserted else { return nil }
            let artifacts = (item["artifact_count"] as? NSNumber)?.intValue
            let description = artifacts.map { $0 == 1 ? "1 artifact" : "\($0) artifacts" } ?? ""
            return RegistryImage(
                registry: registry,
                repository: name,
                description: description,
                pullCount: (item["pull_count"] as? NSNumber)?.intValue ?? 0,
                isPrivate: (item["project_public"] as? Bool).map { !$0 } ?? false
            )
        }
    }
}

/// The Distribution catalog: `GET /v2/_catalog?n=1000`, filtered here by the query.
public enum RegistryCatalog {
    public static let pageSize = 1000
    public static let maxPages = 10
    public static let maxResults = 100

    public static func url(source: RegistrySource) -> URL? {
        URL(string: "\(source.scheme)://\(source.apiHost)/v2/_catalog?n=\(pageSize)")
    }

    public static func parse(_ data: Data) -> [String]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["repositories"] as? [Any] else { return nil }
        return list.compactMap { CLIText.nonEmpty($0 as? String) }
    }

    /// Names that contain every word of the query, best matches first, at most `maxResults`.
    public static func filter(_ names: [String], query: String) -> [String] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
        guard !words.isEmpty else { return Array(names.sorted().prefix(maxResults)) }
        let matches = names.filter { name in
            let lower = name.lowercased()
            return words.allSatisfy { lower.contains($0) }
        }
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        return Array(matches.sorted { a, b in
            let ta = RegistrySearchMerge.tier(repository: a, query: needle)
            let tb = RegistrySearchMerge.tier(repository: b, query: needle)
            return ta != tb ? ta < tb : a < b
        }.prefix(maxResults))
    }
}

/// GitHub's Packages API, the only way to list ghcr.io images. Needs the token
/// saved for ghcr.io (a personal access token with read:packages).
public enum GitHubPackages {
    public static let pageSize = 100
    public static let maxPages = 5

    public static func userPackagesURL() -> URL? {
        URL(string: "https://api.github.com/user/packages?package_type=container&per_page=\(pageSize)")
    }

    public static func userOrgsURL() -> URL? {
        URL(string: "https://api.github.com/user/orgs?per_page=\(pageSize)")
    }

    public static func orgPackagesURL(_ org: String) -> URL? {
        guard let name = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else { return nil }
        return URL(string: "https://api.github.com/orgs/\(name)/packages?package_type=container&per_page=\(pageSize)")
    }

    public static func headers(token: String) -> [String: String] {
        ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "Authorization": "Bearer \(token)"]
    }

    /// Container packages as ghcr.io images ("owner/name", lower case).
    public static func parsePackages(_ data: Data) throws -> [RegistryImage] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw DeckError.parse("GitHub packages")
        }
        return list.compactMap { item in
            if let type = item["package_type"] as? String, type != "container" { return nil }
            guard let name = CLIText.nonEmpty(item["name"] as? String),
                  let owner = CLIText.nonEmpty((item["owner"] as? [String: Any])?["login"] as? String) else { return nil }
            let versions = (item["version_count"] as? NSNumber)?.intValue
            let visibility = item["visibility"] as? String
            var parts: [String] = []
            if let visibility { parts.append(visibility.prefix(1).uppercased() + visibility.dropFirst()) }
            if let versions { parts.append(versions == 1 ? "1 version" : "\(versions) versions") }
            return RegistryImage(
                registry: "ghcr.io",
                repository: "\(owner)/\(name)".lowercased(),
                description: parts.joined(separator: ", "),
                isPrivate: visibility == "private" || visibility == "internal",
                pageURL: (item["html_url"] as? String).flatMap(URL.init(string:))
            )
        }
    }

    /// Org logins from `/user/orgs`.
    public static func parseOrgs(_ data: Data) -> [String] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { CLIText.nonEmpty($0["login"] as? String) }
    }

    /// Packages whose name or owner contains every word of the query.
    public static func filter(_ images: [RegistryImage], query: String) -> [RegistryImage] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
        guard !words.isEmpty else { return images }
        return images.filter { image in words.allSatisfy { image.repository.contains($0) } }
    }
}

/// Tag lists from the registry API: `GET /v2/<name>/tags/list`.
public enum RegistryTagList {
    public static let pageSize = 1000
    public static let maxPages = 5

    public static func url(source: RegistrySource, repository: String) -> URL? {
        URL(string: "\(source.scheme)://\(source.apiHost)/v2/\(repository)/tags/list?n=\(pageSize)")
    }

    public static func parse(_ data: Data) -> [String]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if root["tags"] is NSNull { return [] }
        guard let list = root["tags"] as? [Any] else { return nil }
        return list.compactMap { CLIText.nonEmpty($0 as? String) }
    }

    /// "latest" first, then version tags newest first (1.10 before 1.9), then
    /// the other names in order.
    public static func sorted(_ tags: [String]) -> [String] {
        let unique = Array(Set(tags))
        func isVersion(_ tag: String) -> Bool {
            let body = tag.hasPrefix("v") ? tag.dropFirst() : Substring(tag)
            return body.first?.isNumber == true
        }
        return unique.sorted { a, b in
            if a == "latest" || b == "latest" { return a == "latest" && b != "latest" }
            let va = isVersion(a), vb = isVersion(b)
            if va != vb { return va }
            if va { return a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedDescending }
            return a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
    }

    /// True when a tag list stopped at the page limit, so more tags exist.
    public static func isCapped(_ count: Int) -> Bool {
        count >= pageSize * maxPages
    }
}

/// Short plain text from a registry description, which is often a whole
/// README with HTML and badges.
public enum RegistryText {
    public static func summary(_ raw: String?, limit: Int = 200) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        // Escaped marks ("\\*NIX") survive as plain characters.
        let kept: [(String, String)] = [("\\*", "\u{E000}"), ("\\_", "\u{E001}"), ("\\`", "\u{E002}")]
        var text = raw
        for (escaped, mark) in kept { text = text.replacingOccurrences(of: escaped, with: mark) }
        text = text.replacingOccurrences(of: #"\\([\\\[\]()#+.!{}-])"#, with: "$1", options: .regularExpression)
        let replacements: [(String, String)] = [
            (#"```[\s\S]*?```"#, " "),                 // code blocks
            (#"<[^>]+>"#, " "),                        // HTML tags
            (#"!\[[^\]]*\]\([^)]*\)"#, " "),           // images and badges
            (#"\[!\[[^\]]*\]\([^)]*\)\]\([^)]*\)"#, " "),
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),         // links keep their text
            (#"\[([^\]]*)\]\[[^\]]*\]"#, "$1"),        // reference links
            (#"(?m)^\s*\[[^\]]+\]:\s*\S+.*$"#, " "),   // link definitions
            (#"(?m)^\s{0,3}#{1,6}\s*"#, ""),            // headings
            (#"[*_`]{1,3}"#, "")                        // emphasis and code marks
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "\u{E000}", with: "*")
            .replacingOccurrences(of: "\u{E001}", with: "_")
            .replacingOccurrences(of: "\u{E002}", with: "`")
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // The first paragraph that reads like a sentence, else the first one.
        let pick = paragraphs.first { $0.split(separator: " ").count >= 4 } ?? paragraphs.first ?? ""
        guard pick.count > limit else { return pick }
        return String(pick.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
