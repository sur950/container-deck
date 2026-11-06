import Foundation

/// Where a build was started.
public enum BuildOrigin: String, Codable, Sendable, CaseIterable {
    /// The Build sheet on the Images screen.
    case imageSheet
    /// The Builds screen (new build or rebuild).
    case buildsScreen
    /// A Compose stack (`up` with a build section).
    case compose
    /// Anything else that calls `trackedBuild`.
    case other

    public var title: String {
        switch self {
        case .imageSheet: return "Images"
        case .buildsScreen: return "Builds"
        case .compose: return "Compose"
        case .other: return "Other"
        }
    }

    /// Unknown values from a newer app version read as `.other`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BuildOrigin(rawValue: raw) ?? .other
    }
}

public enum BuildStatus: String, Codable, Sendable, CaseIterable {
    case running, succeeded, failed, cancelled
    /// Was running when the app quit or crashed.
    case interrupted

    public var isFinished: Bool { self != .running }

    public var title: String {
        switch self {
        case .running: return "Building"
        case .succeeded: return "Built"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BuildStatus(rawValue: raw) ?? .interrupted
    }
}

/// Everything needed to run a build again. A Codable copy of `BuildOptions`.
public struct BuildSpec: Codable, Sendable, Hashable {
    public var contextDir: String
    public var dockerfile: String?
    public var tags: [String]
    public var buildArgs: [EnvVar]
    public var platform: String
    public var target: String?
    public var noCache: Bool

    public init(_ options: BuildOptions) {
        contextDir = options.contextDir
        dockerfile = options.dockerfile
        tags = options.tags
        buildArgs = options.buildArgs
        platform = options.platform
        target = options.target
        noCache = options.noCache
    }

    public var options: BuildOptions {
        BuildOptions(contextDir: contextDir, dockerfile: dockerfile, tags: tags, buildArgs: buildArgs,
                     platform: platform, target: target, noCache: noCache)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contextDir = try c.decodeIfPresent(String.self, forKey: .contextDir) ?? ""
        dockerfile = try c.decodeIfPresent(String.self, forKey: .dockerfile)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        buildArgs = try c.decodeIfPresent([EnvVar].self, forKey: .buildArgs) ?? []
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "linux/arm64"
        target = try c.decodeIfPresent(String.self, forKey: .target)
        noCache = try c.decodeIfPresent(Bool.self, forKey: .noCache) ?? false
    }

    /// "linux/amd64" becomes "amd64".
    public var shortPlatform: String {
        platform.hasPrefix("linux/") ? String(platform.dropFirst("linux/".count)) : platform
    }

    /// The Dockerfile path shown to people. Relative to the context when inside it.
    public var dockerfileDisplay: String {
        guard let file = CLIText.nonEmpty(dockerfile) else { return "Dockerfile" }
        let prefix = contextDir.hasSuffix("/") ? contextDir : contextDir + "/"
        return file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : file
    }
}

/// One build, running or finished. Saved in the history file. The log is kept apart.
public struct BuildRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var spec: BuildSpec
    public var status: BuildStatus
    public var origin: BuildOrigin
    /// For Compose: the service name. For a rebuild: nothing.
    public var originDetail: String?
    public var startedAt: Date
    public var finishedAt: Date?
    /// Why it failed, in one line.
    public var message: String?
    /// Last BuildKit step seen, like "RUN npm ci".
    public var lastStep: String?
    /// Step counter of the last step, like 2 of 5.
    public var stepIndex: Int?
    public var stepCount: Int?
    public var logLineCount: Int

    public init(id: UUID = UUID(), spec: BuildSpec, status: BuildStatus = .running, origin: BuildOrigin,
                originDetail: String? = nil, startedAt: Date = Date(), finishedAt: Date? = nil,
                message: String? = nil, lastStep: String? = nil, stepIndex: Int? = nil, stepCount: Int? = nil,
                logLineCount: Int = 0) {
        self.id = id
        self.spec = spec
        self.status = status
        self.origin = origin
        self.originDetail = originDetail
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.message = message
        self.lastStep = lastStep
        self.stepIndex = stepIndex
        self.stepCount = stepCount
        self.logLineCount = logLineCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        spec = try c.decode(BuildSpec.self, forKey: .spec)
        status = try c.decodeIfPresent(BuildStatus.self, forKey: .status) ?? .interrupted
        origin = try c.decodeIfPresent(BuildOrigin.self, forKey: .origin) ?? .other
        originDetail = try c.decodeIfPresent(String.self, forKey: .originDetail)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date(timeIntervalSince1970: 0)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        lastStep = try c.decodeIfPresent(String.self, forKey: .lastStep)
        stepIndex = try c.decodeIfPresent(Int.self, forKey: .stepIndex)
        stepCount = try c.decodeIfPresent(Int.self, forKey: .stepCount)
        logLineCount = try c.decodeIfPresent(Int.self, forKey: .logLineCount) ?? 0
    }

    /// First tag, or "image" when none was given.
    public var title: String { spec.tags.first ?? "image" }

    /// Seconds from start to end, or to `now` while running.
    public func duration(now: Date = Date()) -> TimeInterval {
        max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    /// "Step 2 of 5" when known.
    public var stepText: String? {
        guard let stepIndex, let stepCount else { return nil }
        return "Step \(stepIndex) of \(stepCount)"
    }
}

/// Reads BuildKit plain progress lines (`--progress plain`).
public enum BuildProgressParser {
    public struct Step: Sendable, Hashable {
        public var index: Int
        public var count: Int
        public var title: String
    }

    /// "#5 [linux/arm64 1/2] RUN echo hi" gives step 1 of 2, "RUN echo hi".
    /// Stage names come before the counter: "[build 2/4]", "[linux/amd64 stage 3/5]".
    public static func step(in line: String) -> Step? {
        let text = CLIText.strippingANSI(line).trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#"), let open = text.firstIndex(of: "["), let close = text[open...].firstIndex(of: "]") else {
            return nil
        }
        let inside = text[text.index(after: open)..<close]
        guard let counter = inside.split(separator: " ").last else { return nil }
        let parts = counter.split(separator: "/")
        guard parts.count == 2, let index = Int(parts[0]), let count = Int(parts[1]), count > 0 else { return nil }
        let title = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return Step(index: index, count: count, title: title)
    }

    /// The image reference BuildKit prints as the last line of a good build.
    public static func builtReference(in lines: [String]) -> String? {
        for line in lines.reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if text.hasPrefix("#") || text.hasPrefix("Error") || text.contains(" ") { return nil }
            return text
        }
        return nil
    }

    /// One line that says why a build failed. Prefers "Error:", then BuildKit's "ERROR:".
    public static func failureMessage(in lines: [String]) -> String? {
        if let message = CLIFailure.message(in: lines) {
            return cleanFailure(message)
        }
        for line in lines.reversed() {
            let text = CLIText.strippingANSI(line).trimmingCharacters(in: .whitespaces)
            if let range = text.range(of: "ERROR: ") {
                return cleanFailure(String(text[range.upperBound...]))
            }
        }
        return nil
    }

    /// `unknown: "failed to solve: process ..."` becomes `process ...`.
    static func cleanFailure(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespaces)
        for prefix in ["unknown: ", "internalError: ", "interrupted: "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        if text.hasPrefix("failed to solve: ") {
            text = String(text.dropFirst("failed to solve: ".count))
        }
        return text
    }
}
