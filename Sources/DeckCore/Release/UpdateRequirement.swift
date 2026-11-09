import Foundation

// Compulsory updates. Pure rules, no AppKit, no network. Unit tested in UpdateRequirementTests.
//
// Versions are x.y.z: x is a breaking change, y a compatible feature release, z a small fix.
// A newer release makes the update compulsory when:
//   1. its major (x) is higher than the running app's (a breaking release), or
//   2. its notes carry a marker line (from the version's CHANGELOG section):
//        <!-- deck-update: required -->               every older version must update
//        <!-- deck-update: required-below 1.2.4 -->   only versions below 1.2.4 must update
// Every newer release counts, not only the latest: on 1.2.1 with 1.3.0 (required) and
// 1.3.1 (not marked) published, the update is still compulsory.
// AppConfig.requiredUpdatesEnabled turns the whole rule off.

// MARK: - Marker

/// The `<!-- deck-update: ... -->` line in a release's notes.
public enum UpdateMarker: Sendable, Equatable {
    /// Every older version must update.
    case required
    /// Only versions below this one must update.
    case requiredBelow(ReleaseVersion)

    /// Text inside the HTML comment, before the value.
    public static let keyword = "deck-update:"

    private static let pattern = #"<!--\s*deck-update:\s*(.*?)\s*-->"#

    /// Reads the first marker in `notes`. nil when there is none or its value is not one we know.
    /// scripts/release_notes.sh refuses to publish an unknown value, so a typo never ships.
    public static func parse(_ notes: String) -> UpdateMarker? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(notes.startIndex..., in: notes)
        for match in regex.matches(in: notes, range: range) {
            guard let valueRange = Range(match.range(at: 1), in: notes) else { continue }
            if let marker = value(String(notes[valueRange])) { return marker }
        }
        return nil
    }

    /// Reads the value part: "required" or "required-below 1.2.4".
    static func value(_ text: String) -> UpdateMarker? {
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        switch words.count {
        case 1 where words[0] == "required":
            return .required
        case 2 where words[0] == "required-below":
            return ReleaseVersion(words[1]).map { .requiredBelow($0) }
        default:
            return nil
        }
    }

    /// The notes without marker comments, for showing them in the app.
    public static func strip(_ notes: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[ \t]*<!--\s*deck-update:.*?-->[ \t]*\n?"#,
                                                   options: [.caseInsensitive]) else { return notes }
        let range = NSRange(notes.startIndex..., in: notes)
        return regex.stringByReplacingMatches(in: notes, range: range, withTemplate: "")
    }
}

// MARK: - Rule

public enum UpdateRequirementReason: String, Sendable, Codable, Equatable {
    /// A newer major version (x).
    case breaking
    /// A release marked as required.
    case critical
}

/// Why the running app must update, and to what.
public struct UpdateRequirement: Sendable, Equatable {
    public let reason: UpdateRequirementReason
    /// The running app stays blocked until it is at least this version.
    public let minimumVersion: ReleaseVersion
    /// The newest release that made the update compulsory.
    public let requiredBy: ReleaseVersion

    public init(reason: UpdateRequirementReason, minimumVersion: ReleaseVersion, requiredBy: ReleaseVersion) {
        self.reason = reason
        self.minimumVersion = minimumVersion
        self.requiredBy = requiredBy
    }
}

public enum UpdateRequirementRule {
    /// The compulsory update for `current`, looking at every release in `releases`.
    /// nil when nothing newer requires it, the running version is unknown (`swift run`),
    /// or the switch is off. Pre-releases never require an update.
    /// Not affected by the "Check for updates automatically" setting or a skipped version.
    public static func evaluate(current: ReleaseVersion?, releases: [AppRelease],
                                enabled: Bool = AppConfig.requiredUpdatesEnabled) -> UpdateRequirement? {
        guard enabled, let current else { return nil }
        var minimum: ReleaseVersion?
        var requiredBy: ReleaseVersion?
        var breaking = false
        for release in releases where !release.isPrerelease && current < release.version {
            guard let (floor, reason) = trigger(release, current: current) else { continue }
            if reason == .breaking { breaking = true }
            minimum = max(minimum ?? floor, floor)
            requiredBy = max(requiredBy ?? release.version, release.version)
        }
        guard let minimum, let requiredBy else { return nil }
        return UpdateRequirement(reason: breaking ? .breaking : .critical, minimumVersion: minimum, requiredBy: requiredBy)
    }

    /// Whether one newer release requires the update, and the lowest version that satisfies it.
    static func trigger(_ release: AppRelease, current: ReleaseVersion) -> (ReleaseVersion, UpdateRequirementReason)? {
        let version = release.version
        if version.major > current.major {
            return (ReleaseVersion(version.major, 0, 0), .breaking)
        }
        switch UpdateMarker.parse(release.notes) {
        case .required:
            return (version, .critical)
        case .requiredBelow(let below) where current < below:
            return (min(below, version), .critical)
        default:
            return nil
        }
    }

    /// True when the latest release alone cannot decide, so the releases list must be read:
    /// a newer version exists and the latest release does not require the update by itself.
    public static func needsReleaseList(current: ReleaseVersion?, latest: AppRelease,
                                        enabled: Bool = AppConfig.requiredUpdatesEnabled) -> Bool {
        guard enabled, let current, current < latest.version else { return false }
        return evaluate(current: current, releases: [latest], enabled: enabled) == nil
    }
}

// MARK: - Launch check

public enum RequiredUpdatePolicy {
    public enum LaunchCheck: Sendable, Equatable {
        /// The normal automatic check runs (it also learns about compulsory updates).
        case automatic
        /// One quiet check that only looks for a compulsory update.
        case requiredOnly
        case none
    }

    /// What to check after launch. Turning off automatic checks never turns off compulsory updates.
    public static func launchCheck(automaticChecks: Bool,
                                   enabled: Bool = AppConfig.requiredUpdatesEnabled) -> LaunchCheck {
        if automaticChecks { return .automatic }
        return enabled ? .requiredOnly : .none
    }
}

// MARK: - Remembered state

/// A compulsory update as the app shows and remembers it, so the screen still shows on an
/// offline launch until the app is updated.
public struct RequiredUpdate: Codable, Sendable, Equatable {
    /// The app is blocked until it runs at least this version.
    public var minimumVersion: String
    /// The newest release, the one Install installs.
    public var version: String
    public var reason: UpdateRequirementReason
    public var pageURL: URL?
    public var notes: String

    public init(minimumVersion: String, version: String, reason: UpdateRequirementReason, pageURL: URL?, notes: String) {
        self.minimumVersion = minimumVersion
        self.version = version
        self.reason = reason
        self.pageURL = pageURL
        self.notes = notes
    }

    public init(_ requirement: UpdateRequirement, latest: AppRelease) {
        self.init(minimumVersion: requirement.minimumVersion.description,
                  version: max(latest.version, requirement.requiredBy).description,
                  reason: requirement.reason, pageURL: latest.pageURL, notes: latest.notes)
    }

    /// True while `current` is below the minimum version. Unknown versions are never blocked.
    public func blocks(current: ReleaseVersion?) -> Bool {
        guard let current, let minimum = ReleaseVersion(minimumVersion) else { return false }
        return current < minimum
    }
}

/// Keeps the last compulsory update in UserDefaults.
public struct RequiredUpdateStore: @unchecked Sendable {
    public static let defaultsKey = "requiredUpdate"

    let defaults: UserDefaults
    let key: String

    public init(defaults: UserDefaults = .standard, key: String = RequiredUpdateStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// The remembered update while it still blocks `current`. Clears it once the running
    /// version is at or above its minimum. Never blocks with the switch off.
    public func load(current: ReleaseVersion?, enabled: Bool = AppConfig.requiredUpdatesEnabled) -> RequiredUpdate? {
        guard enabled, let data = defaults.data(forKey: key) else { return nil }
        guard let update = try? JSONDecoder().decode(RequiredUpdate.self, from: data) else {
            clear()
            return nil
        }
        if update.blocks(current: current) { return update }
        if current != nil { clear() }
        return nil
    }

    public func save(_ update: RequiredUpdate) {
        guard let data = try? JSONEncoder().encode(update) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    /// After a check: remember a compulsory update, or forget it when the check could see
    /// every release that matters and none requires one. Returns what the app should show.
    @discardableResult
    public func record(_ result: UpdateCheckResult, enabled: Bool = AppConfig.requiredUpdatesEnabled) -> RequiredUpdate? {
        if enabled, let requirement = result.requirement {
            let update = RequiredUpdate(requirement, latest: result.latest)
            save(update)
            return update
        }
        if result.requirementIsComplete || !enabled {
            clear()
            return nil
        }
        // The releases list could not be read: keep what was remembered.
        return load(current: result.current, enabled: enabled)
    }
}
