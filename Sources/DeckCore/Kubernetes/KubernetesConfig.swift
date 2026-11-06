import Foundation

/// Settings for the Kubernetes feature. Facts come from Apple's `container cluster`
/// plugin (container 1.6.1, `Sources/ContainerCluster`).
public enum KubernetesConfig {
    /// Label the plugin puts on every node container.
    public static let pluginLabel = "com.apple.container.plugin"
    public static let pluginName = "cluster"
    /// Node role label. "control-plane,worker" with no workers, else "control-plane" or "worker".
    public static let roleLabel = "com.apple.container.resource.role"
    public static let controlPlaneRole = "control-plane"
    public static let workerRole = "worker"

    /// The plugin's default cluster name.
    public static let defaultClusterName = "cluster-dev"
    /// Port of the API server inside the control plane node.
    public static let apiServerPort = 6443

    /// The node image the plugin uses when none is given (pinned by digest).
    public static let defaultNodeImage = "docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95"
    public static let defaultVersion = "v1.35.5"
    public static let nodeImageRepository = "docker.io/kindest/node"
    /// Versions offered in the create sheet. The first is the plugin default.
    /// Others are kind node images that may need a newer plugin.
    public static let versions = ["v1.35.5", "v1.36.4", "v1.35.8", "v1.34.11", "v1.33.12"]

    /// `--cni` value that skips the network plugin.
    public static let noCNI = "NONE"

    /// Most workers the plugin accepts.
    public static let maxWorkers = 1024

    /// kubeadm needs at least 2 CPUs and about 2 GB per node.
    public static let minCPUs = 2
    public static let minMemoryGB = 2

    /// Same rule as the plugin: a quarter of the Mac, at least 2.
    public static func defaultCPUs(processors: Int = ProcessInfo.processInfo.processorCount) -> Int {
        max(processors / 4, minCPUs)
    }

    public static func defaultMemoryGB(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        max(Int(physicalMemory / 1_073_741_824) / 4, minMemoryGB)
    }

    /// Node image for a version tag. The default version uses the plugin's pinned image.
    public static func nodeImage(forVersion version: String) -> String {
        let tag = version.hasPrefix("v") ? version : "v\(version)"
        if tag == defaultVersion { return defaultNodeImage }
        return "\(nodeImageRepository):\(tag)"
    }

    /// "v1.35.5" from "docker.io/kindest/node:v1.35.5@sha256:...". nil when the reference has no tag.
    public static func version(fromNodeImage image: String) -> String? {
        let nameAndTag = image.split(separator: "@").first.map(String.init) ?? image
        guard let slash = nameAndTag.lastIndex(of: "/") ?? nameAndTag.indices.first,
              let colon = nameAndTag[slash...].lastIndex(of: ":") else { return nil }
        let tag = String(nameAndTag[nameAndTag.index(after: colon)...])
        return tag.isEmpty ? nil : tag
    }

    // MARK: - Cluster names

    /// The plugin names the control plane node after the cluster and workers "<name>-worker-<n>"
    /// (`ClusterConfiguration.workerName`). It then waits with `kubectl wait node/<container name>`,
    /// but Kubernetes registers nodes under lowercase RFC 1123 names. A name with capital letters
    /// (or dots and underscores, which container names allow) never matches and the worker wait
    /// times out. So cluster names are DNS labels: lowercase letters, digits and dashes.
    public static let workerNameInfix = "-worker-"
    /// Most characters in a DNS label, and in a container name.
    public static let maxNodeNameLength = 63
    /// Longest cluster name that still leaves room for "-worker-1024".
    public static let maxNameLength = maxNodeNameLength - workerNameInfix.count - String(maxWorkers).count
    /// Container names need at least 2 characters, and the control plane node uses the cluster name.
    public static let minNameLength = 2

    /// Why a cluster name is not allowed. nil from `nameProblem` means the name is fine.
    public enum NameProblem: Equatable, Sendable {
        case empty, tooShort, tooLong, badCharacters, badStart, badEnd

        /// Short text for the create sheet.
        public var message: String {
            switch self {
            case .empty: return "Enter a name."
            case .tooShort: return "Use at least \(KubernetesConfig.minNameLength) characters."
            case .tooLong: return "Use \(KubernetesConfig.maxNameLength) characters or fewer."
            case .badCharacters: return "Use only lowercase letters, numbers and dashes."
            case .badStart: return "Start with a letter."
            case .badEnd: return "End with a letter or number."
            }
        }
    }

    /// Checks a cluster name. Rules: lowercase letters, digits and dashes, starts with a letter,
    /// ends with a letter or digit, 2 to `maxNameLength` characters.
    public static func nameProblem(_ name: String) -> NameProblem? {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, let last = scalars.last else { return .empty }
        func isLower(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) }
        func isDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) }
        guard scalars.allSatisfy({ isLower($0) || isDigit($0) || $0 == "-" }) else { return .badCharacters }
        guard isLower(first) else { return .badStart }
        guard isLower(last) || isDigit(last) else { return .badEnd }
        if scalars.count < minNameLength { return .tooShort }
        if scalars.count > maxNameLength { return .tooLong }
        return nil
    }

    public static func isValidName(_ name: String) -> Bool {
        nameProblem(name) == nil
    }

    /// What the name field keeps while the user types: capital letters become lowercase.
    /// Other characters stay, so the sheet can say what is wrong.
    public static func normalizedNameInput(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }))
    }

    /// Container name of the nth worker (1 based), as the plugin makes it.
    public static func workerName(cluster: String, index: Int) -> String {
        "\(cluster)\(workerNameInfix)\(index)"
    }

    // MARK: - Files

    /// Folder inside Application Support/<bundle id> for kubeconfigs the app reads.
    public static let folderName = "Kubernetes"
    /// Environment variable that moves the folder (tests, separate app copies).
    public static let directoryOverrideVariable = "DECK_KUBERNETES_DIR"

    public static var appDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[directoryOverrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent(AppConfig.bundleID, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Private kubeconfig the app uses to talk to a cluster.
    public static func appKubeconfig(for cluster: String) -> URL {
        appDirectory.appendingPathComponent("\(cluster).kubeconfig")
    }

    /// File that remembers how each cluster was created (for Recreate).
    public static var recipesFile: URL {
        appDirectory.appendingPathComponent("clusters.json")
    }

    /// `~/.kube/config`, where kubectl looks by default.
    public static var defaultKubeconfig: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kube/config")
    }

    /// `~/.kube/<cluster>.kubeconfig`, a file with only this cluster.
    public static func standaloneKubeconfig(for cluster: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kube/\(cluster).kubeconfig")
    }

    // MARK: - API

    /// Seconds before an API call gives up.
    public static let requestTimeout: TimeInterval = 10
    /// Lines of a pod log read at first.
    public static let logTailLines = 500
    /// Lines kept in the log view.
    public static let maxLogLines = 4000
}
