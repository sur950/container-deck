import Foundation

/// The owner's rule for system tool versions: nothing is blocked.
///
/// Every tool, Apple container included, can update to its newest release from the app, and
/// people can install any older or newer version elsewhere. Each tool has one tested version
/// (`AppConfig.componentTested`): the release line Container Deck was verified with. It is shown
/// as information, and it is where "Switch to the tested version" goes when a feature the app
/// uses is found broken on another version (`ComponentHealthProbe`, `ComponentHealth.report`).
///
/// Pure, so it is unit tested.
public enum ComponentGate {
    /// The tested version of one tool.
    public struct Tested: Sendable, Equatable {
        /// The release line, like [1, 7] for 1.7.x or [3] for 3.x.
        public var line: [Int]
        /// A verified release, used when no list of releases is published.
        public var version: ToolVersion?

        public init(line: [Int], version: ToolVersion? = nil) {
            self.line = line.isEmpty ? [0] : line
            self.version = version
        }

        public init(_ config: AppConfig.ComponentTested) {
            self.init(line: ToolVersion(config.line)?.parts ?? [0], version: config.version.flatMap(ToolVersion.init))
        }

        /// The version is in the tested line: 1.7.1 is in 1.7, 0.0.27-1 is in 0.0.27.
        public func matches(_ version: ToolVersion) -> Bool {
            version.parts.count >= line.count && Array(version.parts.prefix(line.count)) == line
        }

        /// "1.7.x".
        public var text: String { line.map(String.init).joined(separator: ".") + ".x" }

        /// Where a switch goes: the newest published release of the line, else the verified release.
        public func target(published: [ToolVersion]) -> ToolVersion? {
            published.filter { !$0.isPrerelease && matches($0) }.max() ?? version
        }
    }

    /// The tested version for a component id. Apple container follows `apiSupportedVersions`.
    /// nil when there is none (MCP images, tools with date versions and no list).
    public static func tested(for id: String) -> Tested? {
        if id == "container" { return Tested(AppConfig.containerTested) }
        return AppConfig.componentTested[id].map(Tested.init)
    }

    public enum Verdict: Sendable, Equatable {
        case notInstalled
        case upToDate
        /// A newer release to update to. Never blocked.
        case update(to: ToolVersion)
        /// No release list to compare with.
        case unknown
    }

    public struct Decision: Sendable, Equatable {
        public var verdict: Verdict

        public var status: ComponentStatus {
            switch verdict {
            case .notInstalled: return .notInstalled
            case .upToDate: return .upToDate
            case .update: return .updateAvailable
            case .unknown: return .unknown
            }
        }
    }

    /// - Parameters:
    ///   - installed: the version on this Mac, nil when the tool is not installed.
    ///   - available: published versions (any order). Pre-releases are skipped.
    public static func evaluate(installed: ToolVersion?, available: [ToolVersion]) -> Decision {
        guard let installed else { return Decision(verdict: .notInstalled) }
        guard let newest = available.filter({ !$0.isPrerelease }).max() else { return Decision(verdict: .unknown) }
        return Decision(verdict: newest > installed ? .update(to: newest) : .upToDate)
    }
}
