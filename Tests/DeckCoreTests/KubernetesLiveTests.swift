import XCTest
@testable import DeckCore

/// Runs against the real `container cluster` plugin. Off unless DECK_LIVE_KUBERNETES=1.
/// Makes a one node cluster (about a minute with the node image pulled), reads it through
/// the Kubernetes API with the app's own client, loads an image, then deletes the cluster.
/// Set DECK_LIVE_KUBERNETES_CLUSTER=<name> to use a running cluster instead and keep it.
final class KubernetesLiveTests: XCTestCase {
    private let cli = "/usr/local/bin/container"

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["DECK_LIVE_KUBERNETES"] == "1" else {
            throw XCTSkip("Set DECK_LIVE_KUBERNETES=1 to run the live Kubernetes test.")
        }
        guard FileManager.default.isExecutableFile(atPath: cli) else { throw XCTSkip("container is not installed") }
    }

    func testLiveClusterLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deck-k8s-live-\(UUID().uuidString)")
        setenv(KubernetesConfig.directoryOverrideVariable, directory.path, 1)
        defer {
            unsetenv(KubernetesConfig.directoryOverrideVariable)
            try? FileManager.default.removeItem(at: directory)
        }
        let client = ContainerClient(cliPath: cli)
        let supported = await client.clusterSupported()
        guard supported else { throw XCTSkip("This container tool has no cluster command.") }

        let existing = ProcessInfo.processInfo.environment["DECK_LIVE_KUBERNETES_CLUSTER"]
        let name = existing ?? "deck-v2-k8s-live"
        var created = false
        if existing == nil {
            let options = KubeClusterOptions(name: name, workers: 0, cni: .kindnet, cpus: 2, memory: "3G")
            var lines: [String] = []
            let started = Date()
            for try await line in client.createCluster(options) { lines.append(line) }
            created = true
            print("cluster create took \(Int(Date().timeIntervalSince(started))) s, last line: \(lines.last ?? "")")
        }

        do {
            let clusters = try await client.listClusters()
            let cluster = try XCTUnwrap(clusters.first(where: { $0.name == name }))
            XCTAssertEqual(cluster.state, .running)
            XCTAssertNotNil(cluster.apiServerHostPort)

            let config = try await client.appKubeconfig(name)
            XCTAssertNil(config.credentials()?.token)
            let mode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)

            let api = try await KubeAPIClient.make(config, context: name)
            let version = try await api.version()
            XCTAssertTrue(version?.hasPrefix("v1.") ?? false)
            let nodes = try await api.nodes()
            XCTAssertEqual(nodes.map(\.name), cluster.nodes.map(\.name))
            let namespaces = try await api.namespaces()
            XCTAssertTrue(namespaces.contains(where: { $0.name == "kube-system" }))
            let pods = try await api.pods(namespace: "kube-system")
            XCTAssertTrue(pods.contains(where: { $0.name.hasPrefix("kube-apiserver") }))
            let services = try await api.services()
            XCTAssertTrue(services.contains(where: { $0.name == "kubernetes" }))
            _ = try await api.deployments()
            _ = try await api.events()

            // Logs of the API server pod, without follow.
            if let apiserver = pods.first(where: { $0.name.hasPrefix("kube-apiserver") }) {
                var count = 0
                for try await _ in api.podLogs(namespace: "kube-system", pod: apiserver.name, follow: false, tail: 5) { count += 1 }
                XCTAssertGreaterThan(count, 0)
            }

            // Load a small local image into the node, no registry.
            let images = try await client.listImages()
            if let alpine = images.first(where: { $0.reference.contains("library/alpine:") }) {
                try await client.loadImage(intoCluster: name, image: alpine.reference)
            }
        } catch {
            if created { try? await client.deleteCluster(name) }
            throw error
        }

        if created {
            try await client.deleteCluster(name)
            let after = try await client.listClusters()
            XCTAssertFalse(after.contains(where: { $0.name == name }))
        }
    }
}
