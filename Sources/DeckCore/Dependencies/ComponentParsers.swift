import Foundation

/// Pure parsers for installed versions (read only commands) and for the places the newest
/// versions come from (GitHub, PyPI, Homebrew's API, LM Studio's install script).
public enum ComponentParsers {
    // MARK: Installed versions

    /// `container --version`: "container CLI version 1.6.1 (build: release, commit: aa8d76b)".
    public static func containerVersion(_ text: String) -> ToolVersion? {
        firstAfter("version", in: text) ?? ToolVersion.firstMatch(in: text)
    }

    /// `ollama -v`: "ollama version is 0.16.2". When the server and the command differ it adds
    /// "Warning: client version is 0.16.3". The command's own version wins.
    public static func ollamaVersion(_ text: String) -> ToolVersion? {
        for line in text.split(whereSeparator: \.isNewline) {
            let lower = line.lowercased()
            if lower.contains("client version is") { return ToolVersion.firstMatch(in: String(line)) }
        }
        for line in text.split(whereSeparator: \.isNewline) where line.lowercased().contains("version is") {
            return ToolVersion.firstMatch(in: String(line))
        }
        return nil
    }

    /// Ollama's `GET /api/version`: `{"version":"0.16.2"}`.
    public static func ollamaAPIVersion(_ data: Data) -> ToolVersion? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["version"] as? String else { return nil }
        return ToolVersion(text)
    }

    /// `lms daemon status`: "llmster v0.0.27+1 is running (PID: 53383)". nil when it shows no version.
    public static func llmsterVersion(_ text: String) -> ToolVersion? {
        guard let range = text.range(of: "llmster v", options: .caseInsensitive) else { return nil }
        return ToolVersion(String(text[range.upperBound...]))
    }

    /// Folders in ~/.lmstudio/llmster, like "0.0.27-1". The newest wins.
    public static func llmsterVersion(folders: [String]) -> ToolVersion? {
        folders.compactMap { name -> ToolVersion? in
            guard let first = name.first, first.isNumber else { return nil }
            return ToolVersion(name)
        }.max()
    }

    /// `lms daemon --help` lists an `update` command (lms 0.4 and later).
    public static func lmsHasDaemonUpdate(_ help: String) -> Bool {
        help.split(whereSeparator: \.isNewline).contains { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            return words.first == "update"
        }
    }

    /// `uv --version`: "uv 0.9.28 (Homebrew 2026-01-29)".
    public static func uvVersion(_ text: String) -> ToolVersion? {
        firstAfter("uv", in: text)
    }

    /// `uv tool list`: "mlx-lm v0.32.2".
    public static func uvToolVersion(_ text: String, package: String) -> ToolVersion? {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ")
            if words.count >= 2, words[0] == package { return ToolVersion(String(words[1])) }
        }
        return nil
    }

    /// `cloudflared --version`: "cloudflared version 2026.3.0 (built 2026-03-06T12:53:40Z)".
    public static func cloudflaredVersion(_ text: String) -> ToolVersion? {
        firstAfter("version", in: text)
    }

    /// `ngrok version`: "ngrok version 3.24.0".
    public static func ngrokVersion(_ text: String) -> ToolVersion? {
        firstAfter("version", in: text)
    }

    /// `tailscale version`: the first line is the version, like "1.104.5".
    public static func tailscaleVersion(_ text: String) -> ToolVersion? {
        text.split(whereSeparator: \.isNewline).first.flatMap { ToolVersion(String($0)) }
    }

    /// `kubectl version --client -o json`, or the text form "Client Version: v1.35.0".
    public static func kubectlVersion(_ text: String) -> ToolVersion? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let client = object["clientVersion"] as? [String: Any], let git = client["gitVersion"] as? String {
            return ToolVersion(git)
        }
        return firstAfter("Client Version:", in: text)
    }

    /// `helm version --short`: "v4.1.0+g4553a0a".
    public static func helmVersion(_ text: String) -> ToolVersion? {
        ToolVersion.firstMatch(in: text)
    }

    /// CFBundleShortVersionString of an app's Info.plist.
    public static func appVersion(infoPlist data: Data) -> ToolVersion? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let text = plist["CFBundleShortVersionString"] as? String else { return nil }
        return ToolVersion(text)
    }

    /// `id -Gn`: the groups of the person. Admins can approve the password prompt.
    public static func isAdmin(groups text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).contains("admin")
    }

    /// The version in the Homebrew Cellar path a command links to, like
    /// "/opt/homebrew/Cellar/ollama/0.16.2/bin/ollama". nil when it is not a Homebrew formula.
    public static func homebrewFormula(resolvedPath: String) -> (name: String, version: ToolVersion?)? {
        let parts = resolvedPath.split(separator: "/").map(String.init)
        guard let cellar = parts.firstIndex(of: "Cellar"), cellar + 1 < parts.count else { return nil }
        let name = parts[cellar + 1]
        let version = cellar + 2 < parts.count ? ToolVersion(parts[cellar + 2]) : nil
        return (name, version)
    }

    // MARK: Newest versions

    public struct GitHubRelease: Sendable, Equatable {
        public var version: ToolVersion
        public var tag: String
        public var pageURL: URL
        public var isPrerelease: Bool
        public var assets: [Asset]
        /// Release notes in GitHub Markdown.
        public var body: String = ""

        public struct Asset: Sendable, Equatable {
            public var name: String
            public var url: URL
            public var size: Int?
            /// "sha256:<hex>" when GitHub publishes one.
            public var digest: String?
        }

        /// Apple's signed installer package ("container-1.7.1-installer-signed.pkg"), never the unsigned one.
        public var signedPackage: Asset? {
            let packages = assets.filter { $0.name.lowercased().hasSuffix(".pkg") && !$0.name.lowercased().contains("unsigned") }
            return packages.first { $0.name.lowercased().contains("signed") } ?? packages.first
        }
    }

    /// GitHub `GET /repos/<owner>/<repo>/releases` (a list) or `/releases/latest` (one object).
    /// Drafts and tags that are not versions are skipped.
    public static func githubReleases(_ data: Data) throws -> [GitHubRelease] {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int?
            let digest: String?
        }
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
            let prerelease: Bool?
            let draft: Bool?
            let assets: [Asset]?
            let body: String?
        }
        let decoder = JSONDecoder()
        let list: [Release]
        if let many = try? decoder.decode([Release].self, from: data) {
            list = many
        } else if let one = try? decoder.decode(Release.self, from: data) {
            list = [one]
        } else {
            throw DeckError.parse("the GitHub release list")
        }
        return list.compactMap { release in
            guard release.draft != true, let version = ToolVersion(release.tag_name) else { return nil }
            let assets = (release.assets ?? []).map {
                GitHubRelease.Asset(name: $0.name, url: $0.browser_download_url, size: $0.size, digest: $0.digest)
            }
            return GitHubRelease(version: version, tag: release.tag_name, pageURL: release.html_url,
                                 isPrerelease: release.prerelease == true || version.isPrerelease, assets: assets,
                                 body: release.body ?? "")
        }
    }

    /// PyPI `GET /pypi/<package>/json`: every release that has files and is not yanked, plus `info.version`.
    public static func pypiVersions(_ data: Data) throws -> (latest: ToolVersion?, all: [ToolVersion]) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeckError.parse("the PyPI answer")
        }
        let info = object["info"] as? [String: Any]
        let latest = (info?["version"] as? String).flatMap(ToolVersion.init)
        var all: [ToolVersion] = []
        if let releases = object["releases"] as? [String: Any] {
            for (key, value) in releases {
                guard let files = value as? [[String: Any]], !files.isEmpty,
                      files.contains(where: { ($0["yanked"] as? Bool) != true }),
                      let version = ToolVersion(key) else { continue }
                all.append(version)
            }
        }
        if all.isEmpty, let latest { all = [latest] }
        return (latest, all)
    }

    /// formulae.brew.sh `api/formula/<name>.json`: `versions.stable`. A disabled formula (it can't
    /// be installed any more, like kubernetes-cli@1.32) counts as missing.
    public static func homebrewFormulaVersion(_ data: Data) throws -> ToolVersion {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["disabled"] as? Bool != true,
              let versions = object["versions"] as? [String: Any], let stable = versions["stable"] as? String,
              let version = ToolVersion(stable) else {
            throw DeckError.parse("the Homebrew formula")
        }
        return version
    }

    /// formulae.brew.sh `api/cask/<name>.json`: `version` ("0.4.28,2" reads as 0.4.28.2) and `auto_updates`.
    public static func homebrewCaskVersion(_ data: Data) throws -> (version: ToolVersion, autoUpdates: Bool) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["version"] as? String, let version = ToolVersion(text) else {
            throw DeckError.parse("the Homebrew cask")
        }
        return (version, object["auto_updates"] as? Bool ?? false)
    }

    /// npm registry `GET /<package>/latest`: the package.json of the `latest` tag, `version`.
    public static func npmLatestVersion(_ data: Data) throws -> ToolVersion {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["version"] as? String, let version = ToolVersion(text) else {
            throw DeckError.parse("the npm registry answer")
        }
        return version
    }

    /// npm registry `GET /<package>` (full or abbreviated): every version in `versions`, without
    /// deprecated ones.
    public static func npmVersions(_ data: Data) throws -> [ToolVersion] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = object["versions"] as? [String: Any] else {
            throw DeckError.parse("the npm registry answer")
        }
        return versions.compactMap { key, value in
            if let info = value as? [String: Any], info["deprecated"] is String { return nil }
            return ToolVersion(key)
        }
    }

    /// How an agent tool was installed, from where its command really lives.
    /// `/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe` is npm under /opt/homebrew.
    public static func agentInstallMethod(resolvedPath path: String, home: String) -> InstallMethod? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let formula = homebrewFormula(resolvedPath: path) { return .homebrewFormula(formula.name) }
        if let index = parts.firstIndex(of: "Caskroom"), index + 1 < parts.count { return .homebrewCask(parts[index + 1]) }
        if let index = parts.firstIndex(of: "node_modules"), index + 1 < parts.count, index >= 2, parts[index - 1] == "lib" {
            var package = parts[index + 1]
            if package.hasPrefix("@"), index + 2 < parts.count { package += "/" + parts[index + 2] }
            let prefix = parts[..<(index - 1)].joined(separator: "/")
            return .npmGlobal(package: package, prefix: prefix.isEmpty ? "/" : prefix)
        }
        if let range = path.range(of: "/uv/tools/") {
            let rest = path[range.upperBound...]
            if let name = rest.split(separator: "/").first { return .uvTool(String(name)) }
        }
        if let range = path.range(of: "/pipx/venvs/") {
            let rest = path[range.upperBound...]
            if let name = rest.split(separator: "/").first { return .pipx(String(name)) }
        }
        // Claude Code's native installer keeps versions in ~/.local/share/claude and links ~/.local/bin/claude.
        if path.hasPrefix(home + "/.local/share/claude/") || path.hasPrefix(home + "/.claude/local/") {
            return .selfUpdater(path)
        }
        return nil
    }

    /// LM Studio's install script names the llmster version it installs: `APP_VERSION="0.0.27-1"`.
    public static func lmStudioScriptVersion(_ script: String) -> ToolVersion? {
        for line in script.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("APP_VERSION=") else { continue }
            let value = trimmed.dropFirst("APP_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return ToolVersion(value)
        }
        return nil
    }

    /// A few plain lines from release notes for a short prompt. List items win over prose. When a
    /// list has sections ("- Core" with items under it), only the items are used. Markdown marks,
    /// links (kept as their text), headings, legends and "Full Changelog" lines are left out.
    public static func notesSummary(_ markdown: String, maxLines: Int = 5) -> [String] {
        struct Item { var text: String; var indent: Int }
        var items: [Item] = []
        var prose: [String] = []
        for raw in markdown.split(whereSeparator: \.isNewline) {
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            var line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("```") || line.hasPrefix("<!--") || line.hasPrefix("|") { continue }
            if lower.contains("full changelog") || lower.hasPrefix("new contributors") || lower.contains("denotes") { continue }
            var isItem = false
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(2))
                isItem = true
            }
            line = cleanNotesLine(line)
            guard !line.isEmpty else { continue }
            if isItem { items.append(Item(text: line, indent: indent)) } else { prose.append(line) }
        }
        let nested = items.filter { $0.indent > 0 }
        let chosen = !nested.isEmpty ? nested.map(\.text) : (!items.isEmpty ? items.map(\.text) : prose)
        return Array(chosen.prefix(maxLines)).map { $0.count > 140 ? String($0.prefix(139)) + "…" : $0 }
    }

    static func cleanNotesLine(_ text: String) -> String {
        var line = text
        line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #" by @[A-Za-z0-9-]+ in https?://\S+"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        // Leading emoji legends like "⌨️" or "👩‍💻".
        let scalars = line.unicodeScalars.drop { scalar in
            scalar == " " || scalar.value == 0xFE0F || scalar.value == 0x200D || (scalar.properties.isEmoji && scalar.value > 0x2000)
        }
        line = String(String.UnicodeScalarView(scalars))
        return line.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Helpers

    /// The version right after `word`, like "1.6.1" in "container CLI version 1.6.1 (build...)".
    static func firstAfter(_ word: String, in text: String) -> ToolVersion? {
        guard let range = text.range(of: word + " ", options: .caseInsensitive) ?? text.range(of: word, options: .caseInsensitive) else {
            return nil
        }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return ToolVersion(rest)
    }
}
