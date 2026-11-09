import Foundation

/// Limits for stats history and the multi pane log viewer.
public enum ObservabilityConfig {
    // MARK: Stats history

    /// Fine tier: one point every 2 seconds, kept for one hour.
    public static let fineStep = 2
    public static let fineSpan = 60 * 60
    /// Coarse tier: one point a minute, kept for 24 hours.
    public static let coarseStep = 60
    public static let coarseSpan = 24 * 60 * 60
    /// Containers kept on disk. The least recently seen one goes first. The total does not count.
    public static let maxSeries = 24
    /// A container not seen for this long is dropped.
    public static let seriesExpiry: TimeInterval = 24 * 60 * 60
    /// A gap longer than this many steps breaks a chart line.
    public static let gapSteps = 3
    /// Seconds between saves while samples come in. Also saved when the app quits.
    public static let saveInterval: TimeInterval = 120
    /// Key of the series that sums all running containers.
    public static let totalKey = "_total"
    /// File name inside Application Support/<bundle id>/StatsHistory.
    public static let fileName = "history.bin"

    /// The history file. Application Support/<bundle id>/StatsHistory/history.bin.
    public static var historyFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent(AppConfig.dataID, isDirectory: true)
            .appendingPathComponent("StatsHistory", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    // MARK: Logs

    /// Panes in the log viewer.
    public static let maxLogPanes = 4
    /// Lines kept per pane.
    public static let maxLogLines = 10_000
}
