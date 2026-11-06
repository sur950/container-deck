import Foundation

// Repair after a cluster restart.
//
// Each node of a `container cluster` is a VM that gets a new IP address on most starts.
// The plugin's node entrypoint script (container 1.6.1, ClusterHelper.nodeEntrypointScript)
// rewrites the old IP in the files on the control plane's disk and makes a new API server
// certificate. It does not touch what kubeadm stored inside the cluster, and the kernel
// state the plugin set at create time is gone after a reboot:
//
// - ConfigMap kube-system/kube-proxy still points kube-proxy at https://<old IP>:6443.
//   kube-proxy can not sync, so no Service rules exist and 10.96.0.1 (the in cluster API
//   address) does not answer. kindnet reads nodes through 10.96.0.1, so a kindnet applied
//   after the restart never writes its CNI config and the node stays NotReady ("Waiting
//   for the policy engine"). A cluster made with kindnet looks Ready (the old CNI config
//   is still on disk) but DNS and every Service are down.
// - ConfigMap kube-public/cluster-info (used by kubeadm join) holds the old address too.
// - Workers keep the control plane's old address in /etc/kubernetes/kubelet.conf
//   (the script only fixes a node's own IP, and only on the control plane).
// - net.ipv4.ip_forward and the TCPMSS clamp rules from the plugin's node prep are lost.
//
// The repair below checks each of these with one read only probe per node, then fixes
// only what is stale. It is safe to run on a healthy cluster: the plan is empty.

/// What a probe found on one node.
public struct KubeNodeProbe: Sendable, Equatable {
    /// IP the node recorded on its last boot.
    public var nodeIP: String?
    public var ipForward: Bool?
    /// The plugin's TCPMSS clamp rule is in place.
    public var mssClamp: Bool?
    /// Files in /etc/cni/net.d.
    public var cniFiles: [String]
    /// API server answers /readyz (control plane only).
    public var apiReady: Bool
    /// Server in ConfigMap kube-system/kube-proxy (control plane only).
    public var kubeProxyServer: String?
    /// Server in ConfigMap kube-public/cluster-info (control plane only).
    public var clusterInfoServer: String?
    /// kindnet DaemonSet exists (control plane only).
    public var hasKindnet: Bool
    /// Server in /etc/kubernetes/kubelet.conf.
    public var kubeletServer: String?

    public init(
        nodeIP: String? = nil, ipForward: Bool? = nil, mssClamp: Bool? = nil, cniFiles: [String] = [],
        apiReady: Bool = false, kubeProxyServer: String? = nil, clusterInfoServer: String? = nil,
        hasKindnet: Bool = false, kubeletServer: String? = nil
    ) {
        self.nodeIP = nodeIP
        self.ipForward = ipForward
        self.mssClamp = mssClamp
        self.cniFiles = cniFiles
        self.apiReady = apiReady
        self.kubeProxyServer = kubeProxyServer
        self.clusterInfoServer = clusterInfoServer
        self.hasKindnet = hasKindnet
        self.kubeletServer = kubeletServer
    }
}

/// One fix.
public enum KubeRepairStep: Sendable, Equatable {
    /// ip_forward and the TCPMSS clamp, as the plugin set them at create time.
    case nodeNetwork(node: String)
    /// Points ConfigMap kube-system/kube-proxy at the control plane's current address.
    case kubeProxyServer(from: String, to: String)
    /// Points ConfigMap kube-public/cluster-info at the current address.
    case clusterInfoServer(from: String, to: String)
    /// Restarts kube-proxy (and kindnet, when present) so they read the fixed address.
    case restartNetworkPods(kindnet: Bool)
    /// Points a worker's kubelet at the control plane's current address and restarts it.
    case workerKubelet(node: String, from: String, to: String)

    public var title: String {
        switch self {
        case .nodeNetwork(let node): return "Restored the network settings on \(node)"
        case .kubeProxyServer: return "Pointed kube-proxy at the new node address"
        case .clusterInfoServer: return "Updated the join address"
        case .restartNetworkPods(let kindnet): return kindnet ? "Restarted kube-proxy and kindnet" : "Restarted kube-proxy"
        case .workerKubelet(let node, _, _): return "Pointed the kubelet on \(node) at the new address"
        }
    }

    /// Fixes kube-proxy or worker addresses (the cause of a NotReady node or broken DNS).
    public var fixesAddress: Bool {
        switch self {
        case .kubeProxyServer, .workerKubelet: return true
        default: return false
        }
    }
}

/// What a repair did.
public struct KubeRepairReport: Sendable, Equatable {
    public var steps: [KubeRepairStep]
    /// Control plane address used.
    public var address: String?
    /// Set when the API server never answered, so nothing inside the cluster was checked.
    public var apiUnreachable: Bool
    /// Set when the repair itself failed.
    public var failure: String?

    public init(steps: [KubeRepairStep] = [], address: String? = nil, apiUnreachable: Bool = false, failure: String? = nil) {
        self.steps = steps
        self.address = address
        self.apiUnreachable = apiUnreachable
        self.failure = failure
    }

    public var changed: Bool { !steps.isEmpty }
    public var fixedAddresses: Bool { steps.contains(where: \.fixesAddress) }

    /// One line for a toast.
    public var summary: String {
        if let failure { return "Could not check the cluster network. \(failure)" }
        if apiUnreachable { return "The API server did not answer, so the cluster was not checked." }
        if fixedAddresses { return "The node got a new address. Network settings were updated." }
        if changed { return "Network settings were restored." }
        return "Nothing needed a fix."
    }
}

public enum KubeRestartRepair {
    static let marker = "deck-probe"

    // MARK: Probe

    /// Read only script. Prints `key=value` lines.
    public static func probeScript(controlPlane: Bool) -> String {
        var lines = [
            "echo \(marker)=1",
            "echo node_ip=$(cat /etc/.container-cluster-last-ip 2>/dev/null)",
            "echo ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)",
            "if iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null; then echo mss=1; else echo mss=0; fi",
            "echo cni_files=$(ls /etc/cni/net.d 2>/dev/null | tr '\\n' ',')",
            "echo kubelet_server=$(sed -n 's/^ *server: *//p' /etc/kubernetes/kubelet.conf 2>/dev/null | head -1)",
        ]
        if controlPlane {
            lines += [
                "export KUBECONFIG=/etc/kubernetes/admin.conf",
                "echo api_ready=$(kubectl get --raw=/readyz --request-timeout=3s 2>/dev/null)",
                "echo kube_proxy_server=$(kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.kubeconfig\\.conf}' --request-timeout=5s 2>/dev/null | sed -n 's/^ *server: *//p' | head -1)",
                "echo cluster_info_server=$(kubectl -n kube-public get configmap cluster-info -o jsonpath='{.data.kubeconfig}' --request-timeout=5s 2>/dev/null | sed -n 's/^ *server: *//p' | head -1)",
                "echo kindnet=$(kubectl -n kube-system get daemonset kindnet -o name --request-timeout=5s 2>/dev/null)",
            ]
        }
        return lines.joined(separator: "\n")
    }

    /// Reads the probe output. nil when it is not probe output (exec failed early).
    public static func parseProbe(_ output: String) -> KubeNodeProbe? {
        var values: [String: String] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        guard values[marker] == "1" else { return nil }
        func text(_ key: String) -> String? {
            guard let value = values[key], !value.isEmpty else { return nil }
            return value
        }
        func flag(_ key: String) -> Bool? {
            switch values[key] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return KubeNodeProbe(
            nodeIP: text("node_ip"),
            ipForward: flag("ip_forward"),
            mssClamp: flag("mss"),
            cniFiles: (values["cni_files"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty },
            apiReady: values["api_ready"] == "ok",
            kubeProxyServer: text("kube_proxy_server"),
            clusterInfoServer: text("cluster_info_server"),
            hasKindnet: (values["kindnet"] ?? "").contains("kindnet"),
            kubeletServer: text("kubelet_server")
        )
    }

    // MARK: Plan

    /// "https://192.168.64.113:6443".
    public static func serverURL(_ address: String) -> String {
        let host = address.contains(":") ? "[\(address)]" : address
        return "https://\(host):\(KubernetesConfig.apiServerPort)"
    }

    /// "192.168.64.113/24" becomes "192.168.64.113".
    public static func bareAddress(_ address: String?) -> String? {
        guard let address else { return nil }
        let bare = address.split(separator: "/").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return bare.isEmpty ? nil : bare
    }

    /// Fixes for a cluster from the probes. `address` is the control plane's current IP.
    /// Workers maps node name to its probe.
    public static func plan(controlPlane: String, address: String, controlPlaneProbe: KubeNodeProbe, workers: [(name: String, probe: KubeNodeProbe)] = []) -> [KubeRepairStep] {
        var steps: [KubeRepairStep] = []
        let server = serverURL(address)
        if controlPlaneProbe.ipForward == false || controlPlaneProbe.mssClamp == false {
            steps.append(.nodeNetwork(node: controlPlane))
        }
        for worker in workers where worker.probe.ipForward == false || worker.probe.mssClamp == false {
            steps.append(.nodeNetwork(node: worker.name))
        }
        var restart = false
        if controlPlaneProbe.apiReady {
            if let current = controlPlaneProbe.kubeProxyServer, current != server {
                steps.append(.kubeProxyServer(from: current, to: server))
                restart = true
            }
            if let current = controlPlaneProbe.clusterInfoServer, current != server {
                steps.append(.clusterInfoServer(from: current, to: server))
            }
        }
        for worker in workers {
            if let current = worker.probe.kubeletServer, current != server {
                steps.append(.workerKubelet(node: worker.name, from: current, to: server))
            }
        }
        if restart {
            steps.append(.restartNetworkPods(kindnet: controlPlaneProbe.hasKindnet))
        }
        return steps
    }

    // MARK: Fix scripts

    /// The node to run a step on (the control plane unless it is about one node).
    public static func node(for step: KubeRepairStep, controlPlane: String) -> String {
        switch step {
        case .nodeNetwork(let node), .workerKubelet(let node, _, _): return node
        default: return controlPlane
        }
    }

    /// `sed` expression that swaps any `server: https://...:6443` for the new one.
    static func serverSed(_ server: String) -> String {
        "s#server: https://[^ ]*:\(KubernetesConfig.apiServerPort)#server: \(server)#"
    }

    /// Shell script for one step.
    public static func script(for step: KubeRepairStep) -> String {
        let kubectl = "KUBECONFIG=/etc/kubernetes/admin.conf kubectl --request-timeout=10s"
        switch step {
        case .nodeNetwork:
            return [
                "sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true",
                "sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true",
                "sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || true",
                "for chain in OUTPUT FORWARD; do",
                "  iptables -t mangle -C $chain -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || iptables -t mangle -A $chain -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220",
                "done",
            ].joined(separator: "\n")
        case .kubeProxyServer(_, let to):
            return "set -e\n\(kubectl) -n kube-system get configmap kube-proxy -o yaml | sed -E '\(serverSed(to))' | \(kubectl) replace -f -"
        case .clusterInfoServer(_, let to):
            return "set -e\n\(kubectl) -n kube-public get configmap cluster-info -o yaml | sed -E '\(serverSed(to))' | \(kubectl) replace -f -"
        case .restartNetworkPods(let kindnet):
            var lines = ["set -e", "\(kubectl) -n kube-system rollout restart daemonset/kube-proxy"]
            if kindnet {
                // kindnet reads nodes through kube-proxy's Service rules. Started together, its
                // first reads fail and it backs off for about 30 s before it routes to other nodes.
                lines.append("KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system rollout status daemonset/kube-proxy --timeout=60s >/dev/null 2>&1 || true")
                lines.append("\(kubectl) -n kube-system rollout restart daemonset/kindnet")
            }
            return lines.joined(separator: "\n")
        case .workerKubelet(_, _, let to):
            return [
                "set -e",
                "for f in /etc/kubernetes/kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf; do",
                "  [ -f \"$f\" ] && sed -i -E '\(serverSed(to))' \"$f\"",
                "done",
                "systemctl restart kubelet",
            ].joined(separator: "\n")
        }
    }
}

// MARK: - Running it

public extension ContainerClient {
    /// Runs the read only probe on a node.
    func probeClusterNode(_ node: String, controlPlane: Bool) async throws -> KubeNodeProbe {
        let result = try await exec(node, ["/bin/sh", "-c", KubeRestartRepair.probeScript(controlPlane: controlPlane)])
        guard let probe = KubeRestartRepair.parseProbe(result.stdout) else {
            throw DeckError.commandFailed("Could not check node \(node). \(result.failureMessage)")
        }
        return probe
    }

    /// Probes a running cluster and works out what a restart left stale, without changing
    /// anything. Waits up to `apiWait` seconds for the API server to answer.
    func clusterRepairPlan(_ cluster: KubeCluster, apiWait: TimeInterval = 0) async throws -> (address: String, steps: [KubeRepairStep], apiReady: Bool) {
        guard let control = cluster.controlPlane else {
            throw DeckError.commandFailed("The cluster has no control plane node.")
        }
        let deadline = Date().addingTimeInterval(apiWait)
        var probe = try await probeClusterNode(control.name, controlPlane: true)
        while !probe.apiReady, Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            probe = try await probeClusterNode(control.name, controlPlane: true)
        }
        // The container list knows the address the VM has now. The node's own marker is the
        // same value and serves when the list has none.
        guard let address = KubeRestartRepair.bareAddress(control.ipAddress) ?? probe.nodeIP else {
            throw DeckError.commandFailed("The control plane has no IP address yet.")
        }
        var workers: [(name: String, probe: KubeNodeProbe)] = []
        for worker in cluster.workers where worker.state == .running {
            workers.append((worker.name, try await probeClusterNode(worker.name, controlPlane: false)))
        }
        let steps = KubeRestartRepair.plan(controlPlane: control.name, address: address, controlPlaneProbe: probe, workers: workers)
        return (address, steps, probe.apiReady)
    }

    /// Checks a running cluster after a start and fixes what the restart left stale (see
    /// the notes at the top of this file). Safe on a healthy cluster.
    @discardableResult
    func repairClusterAfterStart(_ cluster: KubeCluster, apiWait: TimeInterval = 90) async throws -> KubeRepairReport {
        guard let control = cluster.controlPlane else { return KubeRepairReport() }
        let plan = try await clusterRepairPlan(cluster, apiWait: apiWait)
        for step in plan.steps {
            let node = KubeRestartRepair.node(for: step, controlPlane: control.name)
            let result = try await exec(node, ["/bin/sh", "-c", KubeRestartRepair.script(for: step)])
            guard result.succeeded else {
                throw DeckError.commandFailed("\(step.title) failed. \(result.failureMessage)")
            }
        }
        return KubeRepairReport(steps: plan.steps, address: plan.address, apiUnreachable: !plan.apiReady)
    }

    /// Starts a stopped cluster, then repairs what the restart left stale. A start that
    /// worked but a repair that failed comes back as a report with `failure` set.
    func startClusterAndRepair(_ cluster: KubeCluster, apiWait: TimeInterval = 90) async throws -> KubeRepairReport {
        try await startCluster(cluster)
        // Read the nodes again for the addresses they got on this start.
        let fresh = (try? await listClusters())?.first(where: { $0.name == cluster.name }) ?? cluster
        do {
            return try await repairClusterAfterStart(fresh, apiWait: apiWait)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var report = KubeRepairReport()
            report.failure = error.localizedDescription
            return report
        }
    }
}
