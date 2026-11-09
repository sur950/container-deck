import Foundation

/// What the installed `container` release does differently, picked once from its version.
///
/// Container Deck supports 1.4 to 1.7 and must keep working on releases it has not seen.
/// Code that depends on a release asks this type instead of comparing version numbers
/// itself, so every difference is listed in one place and unit tested
/// (`PlatformFeaturesTests`). Checked against Apple's source for each release
/// (github.com/apple/container, `Sources/ContainerCommands` and `Sources/ContainerCluster`).
///
/// Unknown newer releases (1.8 and later) get the newest known behaviour. Callers keep a
/// fallback for those and say clearly what failed (`newerThanKnown`).
public struct ContainerPlatformFeatures: Sendable, Equatable {
    /// First release with each change.
    public enum Release {
        /// `container list`, start, stop, kill and delete leave cluster nodes alone,
        /// `cluster list` is one row per cluster with `--format json`, `cluster load-image`
        /// is gone and `cluster create --shared-image-store` replaces it.
        public static let clusterService = SemanticVersion(1, 7, 0)
        /// The plugin is `container cluster`. 1.4.0 to 1.6.0 ship the same feature as
        /// `container k8s` (nodes labelled "k8s", no workers).
        public static let clusterPlugin = SemanticVersion(1, 6, 1)
        /// `k8s create --cni <manifest>` (1.5.0).
        public static let clusterCNIManifest = SemanticVersion(1, 5, 0)
        /// `--cni NONE` and `load-image --node` (1.6.0).
        public static let clusterCNINone = SemanticVersion(1, 6, 0)
        /// Newest release Container Deck was checked against.
        public static let newestKnown = SemanticVersion(1, 7, 1)
    }

    /// The version these answers are for. nil when it could not be read.
    public let version: SemanticVersion?

    public init(version: SemanticVersion?) {
        self.version = version
    }

    /// True from 1.7 on, and for an unknown version (newest known behaviour).
    private var atLeastClusterService: Bool {
        guard let version else { return true }
        return version >= Release.clusterService
    }

    // MARK: Containers

    /// `container list` hides cluster nodes as well as machines (1.7). The direct API sends
    /// the same filter, so both paths list the same containers.
    public var listHidesClusterNodes: Bool { atLeastClusterService }

    /// `container start`, `stop`, `kill` and `delete` answer "not found" for a cluster node (1.7).
    /// Nodes are started and stopped over the direct API instead.
    public var lifecycleSkipsClusterNodes: Bool { atLeastClusterService }

    /// `container stats --format json` has `cpuUtilization`, a fraction of one core (1.7).
    public var statsReportCPUUtilization: Bool { atLeastClusterService }

    /// `container run --cpus` above the number of host cores is refused (1.7).
    public var limitsCPUsToHostCores: Bool { atLeastClusterService }

    // MARK: Kubernetes

    private func atLeast(_ release: SemanticVersion) -> Bool {
        guard let version else { return true }
        return version >= release
    }

    /// `cluster` from 1.6.1, `k8s` in 1.4.0 to 1.6.0. Same subcommands, flags and list table.
    public var clusterCommand: String { atLeast(Release.clusterPlugin) ? "cluster" : "k8s" }

    /// `--workers` (1.6.1). The `k8s` plugin makes one node only.
    public var clusterWorkers: Bool { atLeast(Release.clusterPlugin) }

    /// `--cni <manifest>` (1.5.0).
    public var clusterCNIManifest: Bool { atLeast(Release.clusterCNIManifest) }

    /// `--cni NONE` (1.6.0).
    public var clusterCNINone: Bool { atLeast(Release.clusterCNINone) }

    /// `load-image --node` (1.6.0, gone again in 1.7).
    public var clusterLoadImageNodes: Bool { atLeast(Release.clusterCNINone) }

    /// `container cluster list --format json` (1.7). Older releases print a node table only.
    public var clusterListJSON: Bool { atLeastClusterService }

    /// `container cluster load-image` exists (1.4 to 1.6).
    public var clusterLoadImage: Bool { !atLeastClusterService }

    /// `container cluster create --shared-image-store` (1.7): nodes read images from the
    /// local image store, so a local build needs no load step.
    public var clusterSharedImageStore: Bool { atLeastClusterService }

    /// `container cluster create --workers count=<n>,cpus=<n>,memory=<size>` (1.7).
    public var clusterWorkerGroups: Bool { atLeastClusterService }

    // MARK: Version text

    /// True for a release newer than any Container Deck was checked against.
    public var newerThanKnown: Bool {
        guard let version else { return false }
        return version.major > Release.newestKnown.major
            || (version.major == Release.newestKnown.major && version.minor > Release.newestKnown.minor)
    }

    /// "container 1.8.0", or "this container release" when the version is not known.
    public var releaseName: String {
        version.map { "container \($0)" } ?? "this container release"
    }

    /// Adds a plain note for releases newer than tested, so a failure on 1.8 says why.
    public func explainFailure(_ what: String, details: String) -> DeckError {
        var text = what
        if newerThanKnown {
            text += " \(releaseName) is newer than Container Deck was tested with (up to \(Release.newestKnown.major).\(Release.newestKnown.minor).x)."
        }
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { text += "\n\nDetails: \(trimmed)" }
        return DeckError.commandFailed(text)
    }
}

/// The `container --version` of each CLI path, read once per app session.
/// `ContainerClient.platformFeatures()` uses it when the client was not given a version.
public actor PlatformVersionCache {
    public static let shared = PlatformVersionCache()

    private var versions: [String: SemanticVersion] = [:]

    public init() {}

    /// Stores a version that is already known, for example from the setup checks.
    public func seed(_ path: String, version: SemanticVersion?) {
        guard let version else { return }
        versions[path] = version
    }

    public func forget(_ path: String) {
        versions[path] = nil
    }

    /// The version for `cli`, running `container --version` the first time.
    public func version(for cli: ContainerCLI) async -> SemanticVersion? {
        if let known = versions[cli.path] { return known }
        guard let read = (try? await cli.version()) ?? nil else { return nil }
        versions[cli.path] = read
        return read
    }
}

public extension ContainerClient {
    /// The platform version this client works with: the one it was given, or the CLI's
    /// `--version`, read once per path.
    func resolvedPlatformVersion() async -> SemanticVersion? {
        if let platformVersion { return platformVersion }
        return await PlatformVersionCache.shared.version(for: cli)
    }

    /// What the installed release does differently. See `ContainerPlatformFeatures`.
    func platformFeatures() async -> ContainerPlatformFeatures {
        ContainerPlatformFeatures(version: await resolvedPlatformVersion())
    }

    /// Features from the version the client was given, without running anything. nil
    /// version means the newest known behaviour. Async paths use `platformFeatures()`.
    var knownFeatures: ContainerPlatformFeatures {
        ContainerPlatformFeatures(version: platformVersion)
    }

    /// The same client with its version read (`--version` once per path when not given).
    func withResolvedPlatformVersion() async -> ContainerClient {
        platformVersion == nil ? withPlatformVersion(await resolvedPlatformVersion()) : self
    }

    /// The same client, with a known platform version (no `--version` call needed).
    func withPlatformVersion(_ version: SemanticVersion?) -> ContainerClient {
        var copy = self
        copy.platformVersion = version
        return copy
    }
}
