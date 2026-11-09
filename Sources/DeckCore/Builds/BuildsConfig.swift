import Foundation

/// Settings for the Builds feature (history, logs, builder).
public enum BuildsConfig {
    /// UserDefaults key for "keep the last N builds". The app's PrefKey uses the same string.
    public static let historyLimitKey = "buildsHistoryLimit"
    public static let defaultHistoryLimit = 50
    public static let historyLimitChoices = [10, 25, 50, 100, 200]

    /// Lines kept per build log, in memory and on disk.
    public static let maxLogLines = 4000

    /// Folder inside Application Support/<bundle id>.
    public static let folderName = "Builds"
    public static let historyFileName = "history.json"
    public static let logsFolderName = "logs"

    /// Environment variable that moves the history folder (tests, separate app copies).
    public static let directoryOverrideVariable = "DECK_BUILDS_DIR"

    /// Name of the BuildKit container `container builder start` creates.
    public static let builderContainerID = "buildkit"

    /// The history file for the app. Application Support/<bundle id>/Builds.
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[directoryOverrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent(AppConfig.dataID, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// The limit from preferences, clamped to a sane range.
    public static func historyLimit(_ defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: historyLimitKey)
        return value <= 0 ? defaultHistoryLimit : min(max(value, 1), 1000)
    }
}
