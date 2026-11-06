import XCTest
@testable import DeckCore

/// AppConfig is the one place for product and brand values. scripts/bundle.sh reads the
/// `static let x = "..."` lines as text, so these tests make sure the script and the app agree.
final class AppConfigTests: XCTestCase {
    private var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DeckCore/Config/AppConfig.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Same pattern as cfg() in scripts/bundle.sh.
    private func scriptValue(_ key: String) -> String? {
        let pattern = "static let \(key) = \"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    func testBundleScriptReadsTheSameValues() {
        XCTAssertFalse(source.isEmpty, "AppConfig.swift not found")
        XCTAssertEqual(scriptValue("appName"), AppConfig.appName)
        XCTAssertEqual(scriptValue("bundleID"), AppConfig.bundleID)
        XCTAssertEqual(scriptValue("urlScheme"), AppConfig.urlScheme)
        XCTAssertEqual(scriptValue("company"), AppConfig.company)
        XCTAssertEqual(scriptValue("minimumMacOS"), AppConfig.minimumMacOS)
        XCTAssertEqual(scriptValue("appIconFile"), AppConfig.appIconFile)
    }

    func testValuesAreWellFormed() {
        XCTAssertFalse(AppConfig.appName.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertNotNil(AppConfig.bundleID.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression))
        XCTAssertNotNil(AppConfig.urlScheme.range(of: #"^[a-z][a-z0-9+.-]*$"#, options: .regularExpression))
        XCTAssertNotNil(AppConfig.repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression))
        XCTAssertNotNil(URL(string: AppConfig.websiteURL)?.host)
        XCTAssertNotNil(URL(string: AppConfig.issuesURL)?.host)
        XCTAssertTrue(AppConfig.updateAssetSuffix.hasPrefix("."))
        XCTAssertGreaterThanOrEqual(AppConfig.updateCheckInterval, 60 * 60, "Do not hammer the GitHub API")
        XCTAssertGreaterThan(AppConfig.minimumWindowWidth, 900)
        XCTAssertGreaterThan(AppConfig.defaultRefreshInterval, 0)
    }

    func testColorsAreRGB() {
        for color in [AppConfig.accentLight, AppConfig.accentDark, AppConfig.accentTop, AppConfig.accentBottom] {
            XCTAssertLessThanOrEqual(color, 0xFFFFFF)
        }
    }

    func testBrandFilesExist() {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in [AppConfig.appIconFile, AppConfig.logoFile] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(file).path), "\(file) is missing")
        }
    }

    func testUpdateFeedUsesConfiguredRepository() {
        XCTAssertEqual(UpdateChecker.defaultRepository, AppConfig.repository)
    }

    /// The product was rebranded. Old brand names must not come back through any file.
    func testNoRetiredBrandNames() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let retired = ["geeky" + "ants", "geeky " + "ants", "lake" + "line"]
        let skipDirs: Set<String> = [".git", ".build", "build", ".swiftpm", "DerivedData", ".claude", "node_modules"]
        // Internal working notes are git-ignored and never published, so their history may name old brands.
        let skipFiles: Set<String> = ["CLAUDE.md", "docs/HANDOVER.md", "docs/STATUS.md", "docs/PLAN.md",
                                      "docs/ROADMAP-V2.md", "docs/COMPETITIVE.md", "docs/RELEASING.md"]
        let textExtensions: Set<String> = ["swift", "md", "sh", "yml", "yaml", "plist", "rb", "json", "svg", "entitlements", "txt", "html", "css", "js", "mjs", ""]
        var hits: [String] = []
        let enumerator = FileManager.default.enumerator(at: repo, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            if skipDirs.contains(url.lastPathComponent) { enumerator?.skipDescendants(); continue }
            if skipFiles.contains(url.path.replacingOccurrences(of: repo.path + "/", with: "")) { continue }
            guard textExtensions.contains(url.pathExtension.lowercased()),
                  let text = try? String(contentsOf: url, encoding: .utf8).lowercased() else { continue }
            if retired.contains(where: text.contains) { hits.append(url.path.replacingOccurrences(of: repo.path + "/", with: "")) }
        }
        XCTAssertEqual(hits, [], "Retired brand name found in: \(hits)")
    }
}
