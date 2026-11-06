import Foundation

/// Is the installed `container` tool one this app works with? Drives the
/// version mismatch screen and the Diagnostics view.
public struct VersionCompatibility: Sendable, Equatable {
    public enum Verdict: String, Sendable, Equatable {
        /// Inside the tested range. Direct API and CLI both work.
        case supported
        /// Older than `SetupService.minimumVersion`. The app cannot work with it.
        case tooOld
        /// Works through the container command only, older than the tested API range.
        case olderThanTested
        /// Newer than any release tested. Works through the container command.
        case newerThanTested
        /// The command and the running service are different versions (restart needed).
        case serviceMismatch
        /// The version could not be read.
        case unknown
    }

    public var verdict: Verdict
    public var cliVersion: SemanticVersion?
    public var daemonVersion: SemanticVersion?
    public var minimum: SemanticVersion
    public var supported: Range<SemanticVersion>

    public init(cliVersion: SemanticVersion?, daemonVersion: SemanticVersion?,
                minimum: SemanticVersion = SetupService.minimumVersion,
                supported: Range<SemanticVersion> = AppConfig.apiSupportedVersions) {
        self.cliVersion = cliVersion
        self.daemonVersion = daemonVersion
        self.minimum = minimum
        self.supported = supported
        self.verdict = Self.evaluate(cli: cliVersion, daemon: daemonVersion, minimum: minimum, supported: supported)
    }

    static func evaluate(cli: SemanticVersion?, daemon: SemanticVersion?, minimum: SemanticVersion,
                         supported: Range<SemanticVersion>) -> Verdict {
        guard let version = cli ?? daemon else { return .unknown }
        if version < minimum { return .tooOld }
        if let cli, let daemon, cli != daemon { return .serviceMismatch }
        if version < supported.lowerBound { return .olderThanTested }
        if version >= supported.upperBound { return .newerThanTested }
        return .supported
    }

    /// True when the app should show the full mismatch screen instead of a note.
    public var needsScreen: Bool { verdict == .tooOld || verdict == .serviceMismatch }

    /// True for anything but `supported` and `unknown`.
    public var hasIssue: Bool { verdict != .supported && verdict != .unknown }

    /// Highest release the app is tested with, like "1.6.x".
    public var testedRangeText: String {
        let upper = supported.upperBound
        let last: String
        if upper.patch == 0 && upper.minor > 0 {
            last = "\(upper.major).\(upper.minor - 1).x"
        } else if upper.patch == 0 && upper.minor == 0 {
            last = "\(upper.major - 1).x"
        } else {
            last = "\(upper.major).\(upper.minor).\(upper.patch - 1)"
        }
        return "\(supported.lowerBound) to \(last)"
    }

    public var title: String {
        switch verdict {
        case .supported: return "Container tool is up to date"
        case .tooOld: return "The container tool is too old"
        case .olderThanTested: return "Older container tool"
        case .newerThanTested: return "Newer container tool than tested"
        case .serviceMismatch: return "Container service needs a restart"
        case .unknown: return "Version not known yet"
        }
    }

    public var message: String {
        let installed = cliVersion.map { "\($0)" } ?? "unknown"
        switch verdict {
        case .supported:
            return "Version \(installed) is tested with \(AppConfig.appName)."
        case .tooOld:
            return "Version \(installed) is installed. \(AppConfig.appName) needs \(minimum) or newer. Update the container tool to go on."
        case .olderThanTested:
            return "Version \(installed) works, but only through the container command, which is slower. Tested versions are \(testedRangeText)."
        case .newerThanTested:
            return "Version \(installed) is newer than the versions tested (\(testedRangeText)). \(AppConfig.appName) uses the container command until an update adds support."
        case .serviceMismatch:
            let daemon = daemonVersion.map { "\($0)" } ?? "unknown"
            return "The container command is \(installed) but the running service is \(daemon). This happens after an update. Restart the service so both match."
        case .unknown:
            return "Start the container service to read its version."
        }
    }

    /// Steps people follow to fix the problem. Each has an optional command.
    public var steps: [Step] {
        switch verdict {
        case .supported, .unknown:
            return []
        case .serviceMismatch:
            return [
                Step("Stop the running service", command: "container system stop"),
                Step("Start it again with the new version", command: "container system start"),
                Step("Check that both versions match", command: "container system version")
            ]
        case .newerThanTested:
            return [
                Step("Keep using it. Everything runs through the container command."),
                Step("Check for a \(AppConfig.appName) update in Settings, Updates."),
                Step("Or install a tested release (\(testedRangeText)) from Apple's releases page.", link: Self.releasesURL)
            ]
        case .tooOld, .olderThanTested:
            return [
                Step("Stop the container service", command: "container system stop"),
                Step("Download the newest signed installer (.pkg) from Apple's releases page", link: Self.releasesURL),
                Step("Open the installer and follow the steps. Your images and containers are kept."),
                Step("Start the service again", command: "container system start"),
                Step("Check the version", command: "container --version")
            ]
        }
    }

    public struct Step: Sendable, Equatable, Identifiable {
        public var text: String
        public var command: String?
        public var link: URL?
        public var id: String { text }

        public init(_ text: String, command: String? = nil, link: URL? = nil) {
            self.text = text
            self.command = command
            self.link = link
        }
    }

    public static let releasesURL = URL(string: "https://github.com/\(AppConfig.appleContainerRepository)/releases")!
}
