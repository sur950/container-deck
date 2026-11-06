import Foundation

/// Kubernetes tools on this Mac. Found, never installed.
public struct KubeTools: Sendable, Hashable {
    public var kubectl: String?
    public var k9s: String?
    public var helm: String?
    /// Lens, OpenLens or Freelens app bundle.
    public var lensApp: String?

    public init(kubectl: String? = nil, k9s: String? = nil, helm: String? = nil, lensApp: String? = nil) {
        self.kubectl = kubectl
        self.k9s = k9s
        self.helm = helm
        self.lensApp = lensApp
    }

    public var lensName: String? {
        lensApp.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
    }

    /// Folders searched for command line tools. GUI apps do not get the shell PATH.
    public static func searchFolders(home: String = NSHomeDirectory(), pathEnv: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        var folders = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.rd/bin", "\(home)/.local/bin", "\(home)/bin",
                       "/Applications/Docker.app/Contents/Resources/bin", "/usr/bin"]
        for item in (pathEnv ?? "").split(separator: ":").map(String.init) where !folders.contains(item) && !item.isEmpty {
            folders.append(item)
        }
        return folders
    }

    public static func appFolders(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", "\(home)/Applications"]
    }

    public static let lensAppNames = ["Lens.app", "Freelens.app", "OpenLens.app"]

    public static func detect(
        home: String = NSHomeDirectory(),
        pathEnv: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> KubeTools {
        let folders = searchFolders(home: home, pathEnv: pathEnv)
        func find(_ name: String) -> String? {
            folders.map { "\($0)/\(name)" }.first(where: isExecutable)
        }
        var lens: String?
        outer: for folder in appFolders(home: home) {
            for app in lensAppNames where exists("\(folder)/\(app)") {
                lens = "\(folder)/\(app)"
                break outer
            }
        }
        return KubeTools(kubectl: find("kubectl"), k9s: find("k9s"), helm: find("helm"), lensApp: lens)
    }

    // MARK: - Commands

    static func quote(_ text: String) -> String {
        if text.range(of: #"^[A-Za-z0-9_./:=@%+~-]+$"#, options: .regularExpression) != nil { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Shell line that opens kubectl ready to use for a cluster: shows the nodes, then leaves a shell
    /// with KUBECONFIG set.
    public static func kubectlShellCommand(kubectl: String, kubeconfig: String, context: String) -> String {
        let config = quote(kubeconfig)
        return "export KUBECONFIG=\(config); \(quote(kubectl)) config use-context \(quote(context)) >/dev/null; \(quote(kubectl)) get nodes -o wide; exec \"${SHELL:-/bin/zsh}\" -l"
    }

    public static func k9sCommand(k9s: String, kubeconfig: String, context: String) -> String {
        "\(quote(k9s)) --kubeconfig \(quote(kubeconfig)) --context \(quote(context))"
    }

    /// What the user can paste into a terminal.
    public static func kubectlHint(kubeconfig: String, context: String) -> String {
        "kubectl --kubeconfig \(quote(kubeconfig)) --context \(quote(context)) get pods -A"
    }
}

// MARK: - kubectl runs

public extension KubeTools {
    /// kindnet manifest that ships with the cluster plugin, next to the container tool.
    static func bundledKindnetManifest(cliPath: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        let resolved = (cliPath as NSString).resolvingSymlinksInPath
        let prefix = ((resolved as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let candidates = [
            "\(prefix)/libexec/container/plugins/cluster/resources/kindnet.yaml",
            "/usr/local/libexec/container/plugins/cluster/resources/kindnet.yaml",
        ]
        return candidates.first(where: exists)
    }

    static func applyArguments(kubeconfig: String, context: String, manifest: String) -> [String] {
        ["--kubeconfig", kubeconfig, "--context", context, "apply", "-f", manifest]
    }

    /// `kubectl apply -f <manifest>`. Used to add a CNI to a cluster made without one.
    static func apply(kubectl: String, kubeconfig: String, context: String, manifest: String, runner: any CommandRunning = ProcessRunner()) async throws {
        try await runner.run(kubectl, applyArguments(kubeconfig: kubeconfig, context: context, manifest: manifest)).orThrow()
    }
}
