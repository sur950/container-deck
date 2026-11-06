import XCTest
@testable import DeckCore

// MARK: - Fakes

/// Answers XPC requests from a handler. A nil answer means "never reply".
final class FakeTransport: XPCTransport, @unchecked Sendable {
    typealias Handler = @Sendable (XPCRequest) -> Result<XPCReply, APIError>?
    let serviceName: String
    private let lock = NSLock()
    private var handler: Handler
    private var recorded: [XPCRequest] = []
    var delay: TimeInterval = 0

    init(_ serviceName: String = "fake", handler: @escaping Handler) {
        self.serviceName = serviceName
        self.handler = handler
    }

    var requests: [XPCRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var routes: [String] { requests.map(\.route) }

    func setHandler(_ handler: @escaping Handler) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    func send(_ request: XPCRequest, completion: @escaping @Sendable (Result<XPCReply, APIError>) -> Void) {
        lock.lock()
        recorded.append(request)
        let handler = self.handler
        lock.unlock()
        guard let result = handler(request) else { return }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { completion(result) }
        } else {
            completion(result)
        }
    }
}

private func data(_ text: String) -> XPCValue { .data(Data(text.utf8)) }

/// A daemon made of the recorded 1.6.1 replies. Content blobs are written to a temp folder.
final class RecordedDaemon: @unchecked Sendable {
    let folder: URL
    let api: FakeTransport
    let images: FakeTransport

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("deck-api-blobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (digest, text) in APIFixtures.alpineBlobs {
            try Data(text.utf8).write(to: folder.appendingPathComponent(digest.replacingOccurrences(of: ":", with: "_")))
        }
        let folder = self.folder
        api = FakeTransport("apiserver") { request in
            switch request.route {
            case APIRoute.ping:
                return .success(XPCReply(APIFixtures.ping.mapValues { .string($0) }))
            case APIRoute.containerList:
                return .success(XPCReply([APIKey.containers: RecordedDaemon.filteredList(request)]))
            case APIRoute.containerStats:
                if request.string(APIKey.id) == "deck-demo-web" {
                    return .success(XPCReply([APIKey.statistics: data(APIFixtures.containerStats)]))
                }
                return .success(XPCReply([APIKey.error: data(APIFixtures.notFoundError)]))
            case APIRoute.volumeList:
                return .success(XPCReply([APIKey.volumes: data(APIFixtures.volumeList)]))
            case APIRoute.networkList:
                return .success(XPCReply([APIKey.networkResources: data(APIFixtures.networkList)]))
            case APIRoute.systemDiskUsage:
                return .success(XPCReply([APIKey.diskUsageStats: data(APIFixtures.systemDiskUsage)]))
            default:
                return .success(XPCReply())
            }
        }
        images = FakeTransport("images") { request in
            switch request.route {
            case APIRoute.imageList:
                return .success(XPCReply([APIKey.imageDescriptions: data(APIFixtures.imageList)]))
            case APIRoute.contentGet:
                let digest = request.string(APIKey.digest) ?? ""
                let file = folder.appendingPathComponent(digest.replacingOccurrences(of: ":", with: "_"))
                if FileManager.default.fileExists(atPath: file.path) {
                    return .success(XPCReply([APIKey.contentPath: .string(file.path)]))
                }
                return .success(XPCReply([APIKey.error: data(#"{"code":"notFound","message":"content with digest \#(digest) not found"}"#)]))
            default:
                return .success(XPCReply())
            }
        }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    var settings: DirectAPISettings {
        DirectAPISettings(registryDomain: { "docker.io" }, configuredInfraImages: { [] }, sshAuthSocket: { nil }, fileExists: { _ in true })
    }

    func client(cache: CPUSampleCache = CPUSampleCache()) -> DirectAPIClient {
        DirectAPIClient(apiServer: api, imageService: images, settings: settings, statsCache: cache)
    }

    /// Applies ids, status and the machine label filter like the daemon does.
    static func filteredList(_ request: XPCRequest) -> XPCValue {
        let all = (try? JSONSerialization.jsonObject(with: Data(APIFixtures.containerList.utf8))) as? [[String: Any]] ?? []
        let filters = request.data(APIKey.listFilters).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let ids = filters["ids"] as? [String] ?? []
        let status = filters["status"] as? String
        let kept = all.filter { item in
            let id = (item["configuration"] as? [String: Any])?["id"] as? String ?? ""
            if !ids.isEmpty && !ids.contains(id) { return false }
            if let status, item["status"] as? String != status { return false }
            return true
        }
        return .data((try? JSONSerialization.data(withJSONObject: kept)) ?? Data("[]".utf8))
    }
}

// MARK: - Decoding recorded replies

final class DirectAPIDecodingTests: XCTestCase {
    func testPingReply() async throws {
        let daemon = try RecordedDaemon()
        let health = try await daemon.client().ping()
        XCTAssertEqual(health.version, "1.6.1")
        XCTAssertEqual(health.semanticVersion, SemanticVersion(1, 6, 1))
        XCTAssertEqual(health.appName, "container-apiserver")
        XCTAssertEqual(health.appRoot, "/Users/me/Library/Application Support/com.apple.container/")
        XCTAssertEqual(health.installRoot, "/usr/local/")
        XCTAssertNil(health.logRoot)
    }

    func testPingWithoutVersionIsMalformed() async throws {
        let transport = FakeTransport { _ in .success(XPCReply()) }
        let client = DirectAPIClient(apiServer: transport, imageService: transport)
        do {
            _ = try await client.ping()
            XCTFail("Expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .malformedReply("ping apiServerVersion"))
            XCTAssertTrue(error.isTransportFailure)
        }
    }

    func testContainerListMapsToSummaries() async throws {
        let daemon = try RecordedDaemon()
        let list = try await daemon.client().listContainers(all: true)
        XCTAssertEqual(list.map(\.id), ["buildkit", "deck-demo-stopped", "deck-demo-worker", "deck-demo-web"])

        let web = try XCTUnwrap(list.first { $0.id == "deck-demo-web" })
        XCTAssertEqual(web.name, "deck-demo-web")
        XCTAssertEqual(web.image, "docker.io/library/nginx:alpine")
        XCTAssertEqual(web.state, .running)
        XCTAssertEqual(web.ipAddress, "192.168.65.2")
        XCTAssertEqual(web.hostname, "deck-demo-web")
        XCTAssertEqual(web.ports, [PortMapping(hostPort: 18090, containerPort: 80, proto: "tcp")])
        XCTAssertEqual(web.platform, "linux/arm64/v8")
        XCTAssertEqual(web.cpus, 4)
        XCTAssertEqual(web.memoryBytes, 1_073_741_824)
        XCTAssertEqual(web.labels, ["app": "demo"])
        XCTAssertEqual(web.command, ["/docker-entrypoint.sh", "nginx", "-g", "daemon off;"])

        let stopped = try XCTUnwrap(list.first { $0.id == "deck-demo-stopped" })
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.ipAddress)
        XCTAssertEqual(stopped.hostname, "deck-demo-stopped")
    }

    /// Dates in API replies are seconds since 2001 (Swift's default JSONEncoder).
    func testDatesAreSecondsSince2001() async throws {
        let daemon = try RecordedDaemon()
        let list = try await daemon.client().listContainers()
        let web = try XCTUnwrap(list.first { $0.id == "deck-demo-web" })
        let created = try XCTUnwrap(web.createdAt)
        let started = try XCTUnwrap(web.startedAt)
        XCTAssertEqual(created.timeIntervalSinceReferenceDate, 815_575_180.147131, accuracy: 0.001)
        XCTAssertEqual(started.timeIntervalSinceReferenceDate, 815_575_180.748777, accuracy: 0.001)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: created), 2026)

        XCTAssertEqual(APIDecode.isoDate(sinceReferenceDate: 0), "2001-01-01T00:00:00.000Z")
        let volumes = try await daemon.client().listVolumeSummaries()
        let volume = try XCTUnwrap(volumes.first)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: try XCTUnwrap(volume.createdAt)), 2026)
    }

    func testUnknownStateDecodesAsUnknown() throws {
        let paused = APIFixtures.containerList.replacingOccurrences(of: #""status":"stopped""#, with: #""status":"paused""#)
        XCTAssertNotEqual(paused, APIFixtures.containerList, "fixture has a stopped container")
        let list = try APIDecode.containers(Data(paused.utf8))
        XCTAssertEqual(list.first { $0.id == "deck-demo-stopped" }?.state, .unknown)
        XCTAssertEqual(list.count, 4, "One odd state does not drop the list")

        // A future daemon with an object status still reads.
        let objectStatus = #"[{"configuration":{"id":"x","image":{"reference":"r"}},"status":{"state":"hibernating","networks":[]}}]"#
        XCTAssertEqual(try APIDecode.containers(Data(objectStatus.utf8)).first?.state, .unknown)
        // A missing status too.
        let noStatus = #"[{"configuration":{"id":"y"}}]"#
        XCTAssertEqual(try APIDecode.containers(Data(noStatus.utf8)).first?.state, .unknown)
    }

    func testInspectDetailAndRawJSONLikeCLI() async throws {
        let daemon = try RecordedDaemon()
        let detail = try await daemon.client().inspectContainer("deck-demo-web")
        XCTAssertEqual(detail.summary.id, "deck-demo-web")
        XCTAssertEqual(detail.entrypoint, ["/docker-entrypoint.sh"])
        XCTAssertEqual(detail.arguments, ["nginx", "-g", "daemon off;"])
        XCTAssertEqual(detail.user, "0:0")
        XCTAssertTrue(detail.env.contains(EnvVar(key: "MODE", value: "demo")))
        XCTAssertEqual(detail.mounts, [MountInfo(type: "volume", source: "deck-demo-data", destination: "/usr/share/nginx/html/data")])
        XCTAssertEqual(detail.networks.first?.network, "deck-demo-net")
        XCTAssertEqual(detail.networks.first?.ipAddress, "192.168.65.2")
        // Same shape as `container inspect`: status object, ISO dates, id at the top.
        XCTAssertTrue(detail.rawJSON.contains(#""state" : "running""#), detail.rawJSON)
        XCTAssertTrue(detail.rawJSON.contains(#""id" : "deck-demo-web""#))
        XCTAssertTrue(detail.rawJSON.contains("\"creationDate\" : \"2026-"))
        // The request asked for that one id.
        let filters = try XCTUnwrap(daemon.api.requests.last?.data(APIKey.listFilters))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: filters) as? NSDictionary, ["ids": ["deck-demo-web"], "labels": [:]] as NSDictionary)
    }

    func testInspectUnknownIDGoesToCLI() async throws {
        let daemon = try RecordedDaemon()
        do {
            _ = try await daemon.client().inspectContainer("nope")
            XCTFail("Expected needsCLI")
        } catch let error as APIError {
            guard case .needsCLI = error else { return XCTFail("\(error)") }
        }
    }

    func testListFiltersMatchCLI() async throws {
        let daemon = try RecordedDaemon()
        let client = daemon.client()
        _ = try await client.listContainers(all: true)
        _ = try await client.listContainers(all: false)
        let decoded = try daemon.api.requests.compactMap { $0.data(APIKey.listFilters) }.map { try JSONSerialization.jsonObject(with: $0) as? NSDictionary }
        XCTAssertEqual(decoded[0], ["ids": [], "labels": ["com.apple.container.plugin": "^(?!machine$)"]] as NSDictionary)
        XCTAssertEqual(decoded[1], ["ids": [], "labels": ["com.apple.container.plugin": "^(?!machine$)"], "status": "running"] as NSDictionary)
        let running = try await client.listContainers(all: false)
        XCTAssertEqual(running.map(\.id), ["buildkit", "deck-demo-worker", "deck-demo-web"])
    }

    func testStatsRawTotals() async throws {
        let daemon = try RecordedDaemon()
        let cache = CPUSampleCache()
        let client = daemon.client(cache: cache)
        let stats = try await client.stats(["deck-demo-web"])
        let web = try XCTUnwrap(stats.first)
        XCTAssertEqual(web.id, "deck-demo-web")
        XCTAssertEqual(web.cpuUsageUsec, 38_371)
        XCTAssertEqual(web.memoryUsageBytes, 16_539_648)
        XCTAssertEqual(web.memoryLimitBytes, 1_073_741_824)
        XCTAssertEqual(web.netRxBytes, 1_193_838)
        XCTAssertEqual(web.netTxBytes, 602)
        XCTAssertEqual(web.blockReadBytes, 10_617_856)
        XCTAssertEqual(web.blockWriteBytes, 147_456)
        XCTAssertEqual(web.pids, 6)
        XCTAssertEqual(web.cpuPercent, 0, "First sample has no percent yet")
        XCTAssertNil(web.reportedCPUPercent, "The daemon only gives cumulative CPU time")
    }

    func testStatsForAllRunningSkipsFailures() async throws {
        let daemon = try RecordedDaemon()
        // buildkit and deck-demo-worker answer notFound in the fake, like a container that just stopped.
        let stats = try await daemon.client().stats()
        XCTAssertEqual(stats.map(\.id), ["deck-demo-web"])
        let asked = daemon.api.requests.filter { $0.route == APIRoute.containerStats }.compactMap { $0.string(APIKey.id) }
        XCTAssertEqual(Set(asked), ["buildkit", "deck-demo-worker", "deck-demo-web"])
    }

    func testStatsForMissingContainerGoesToCLI() async throws {
        let daemon = try RecordedDaemon()
        do {
            _ = try await daemon.client().stats(["missing"])
            XCTFail("Expected needsCLI")
        } catch let error as APIError {
            XCTAssertEqual(error, .needsCLI("no such container: missing"))
        }
    }

    func testVolumesNetworksAndDiskUsage() async throws {
        let daemon = try RecordedDaemon()
        let client = daemon.client()
        let volumes = try await client.listVolumes()
        XCTAssertEqual(volumes.map(\.name), ["deck-demo-data"])
        XCTAssertEqual(volumes.first?.backingPath, "/Users/me/Library/Application Support/com.apple.container/volumes/deck-demo-data/volume.img")
        XCTAssertEqual(volumes.first?.usedBy, ["deck-demo-web"])
        XCTAssertEqual(volumes.first?.isAnonymous, false)

        let networks = try await client.listNetworks()
        XCTAssertEqual(networks.map(\.name), ["deck-demo-net", "default"])
        let demo = try XCTUnwrap(networks.first)
        XCTAssertEqual(demo.subnet, "192.168.65.0/24")
        XCTAssertEqual(demo.gateway, "192.168.65.1")
        XCTAssertEqual(demo.ipv6Subnet, "fd3c:507c:de5a:f964::/64")
        XCTAssertFalse(demo.isBuiltin)
        XCTAssertEqual(demo.attachedContainers.sorted(), ["deck-demo-web", "deck-demo-worker"])
        XCTAssertTrue(networks[1].isBuiltin)

        let usage = try await client.diskUsage()
        XCTAssertEqual(usage.images.total, 6)
        XCTAssertEqual(usage.images.active, 3)
        XCTAssertEqual(usage.images.sizeBytes, 3_054_493_696)
        XCTAssertEqual(usage.containers.reclaimableBytes, 249_237_504)
        XCTAssertEqual(usage.volumes.sizeBytes, 39_882_752)
    }

    func testServerErrorReply() async throws {
        let transport = FakeTransport { _ in .success(XPCReply([APIKey.error: data(APIFixtures.notFoundError)])) }
        do {
            _ = try await transport.call(XPCRequest(route: APIRoute.containerStats))
            XCTFail("Expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(code: "notFound", message: "container with ID deck-test-api-missing not found"))
            XCTAssertFalse(error.isTransportFailure)
            XCTAssertFalse(error.isRequestRejected)
            XCTAssertEqual(error.localizedDescription, "container with ID deck-test-api-missing not found")
        }
        let rejected = APIError.server(code: "internalError", message: "keyNotFound(CodingKeys(stringValue: \"ids\"))")
        XCTAssertTrue(rejected.isRequestRejected)
        XCTAssertTrue(rejected.isTransportFailure)
    }
}

// MARK: - Images

final class DirectAPIImageTests: XCTestCase {
    func testImageListFromContentStore() async throws {
        let daemon = try RecordedDaemon()
        // Only alpine:latest has its blobs in the fixture. Others are skipped, builder and init are hidden.
        let images = try await daemon.client().listImages()
        XCTAssertEqual(images.map(\.reference), ["docker.io/library/alpine:latest"])
        let alpine = try XCTUnwrap(images.first)
        XCTAssertEqual(alpine.digest, "sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a")
        // Values `container image list --format json` printed for the same image.
        XCTAssertEqual(alpine.sizeBytes, 4_192_140)
        XCTAssertEqual(alpine.platforms, ["linux/amd64", "linux/arm/v6", "linux/arm/v7", "linux/arm64/v8", "linux/386", "linux/ppc64le", "linux/riscv64", "linux/s390x"])
        XCTAssertEqual(try XCTUnwrap(alpine.createdAt).timeIntervalSince(try XCTUnwrap(DeckDate.parse("2026-10-21T22:34:15Z"))), 0, accuracy: 1)
        // Attestation manifests are not fetched for a list.
        let fetched = daemon.images.requests.filter { $0.route == APIRoute.contentGet }.count
        XCTAssertLessThan(fetched, 1 + 16 + 16)
    }

    func testBlobsAreCached() async throws {
        let daemon = try RecordedDaemon()
        let client = daemon.client()
        _ = try await client.listImages()
        let first = daemon.images.requests.count
        _ = try await client.listImages()
        let second = daemon.images.requests.count - first
        // Second list: imageList plus the index lookups of the images without blobs.
        XCTAssertLessThan(second, first)
    }

    func testInspectImageByShortName() async throws {
        let daemon = try RecordedDaemon()
        let detail = try await daemon.client().inspectImage("alpine")
        XCTAssertEqual(detail.summary.reference, "docker.io/library/alpine:latest")
        XCTAssertEqual(detail.config.cmd, ["/bin/sh"])
        XCTAssertEqual(detail.layers.count, 1)
        XCTAssertTrue(detail.rawJSON.contains("\"variants\""))
    }

    func testUnknownImageGoesToCLI() async throws {
        let daemon = try RecordedDaemon()
        do {
            _ = try await daemon.client().inspectImage("does-not-exist")
            XCTFail("Expected needsCLI")
        } catch let error as APIError {
            guard case .needsCLI = error else { return XCTFail("\(error)") }
        }
    }

    func testTagAndDeleteRequests() async throws {
        let daemon = try RecordedDaemon()
        let client = daemon.client()
        try await client.tagImage("alpine", as: "my/alpine:v1")
        let tag = try XCTUnwrap(daemon.images.requests.last)
        XCTAssertEqual(tag.route, APIRoute.imageTag)
        XCTAssertEqual(tag.string(APIKey.imageReference), "docker.io/library/alpine:latest")
        XCTAssertEqual(tag.string(APIKey.imageNewReference), "docker.io/my/alpine:v1")

        try await client.deleteImage("docker.io/library/alpine:3.22")
        let routes = daemon.images.routes.suffix(2)
        XCTAssertEqual(Array(routes), [APIRoute.imageDelete, APIRoute.imageCleanupOrphanedBlobs])
        let delete = try XCTUnwrap(daemon.images.requests.first { $0.route == APIRoute.imageDelete })
        XCTAssertEqual(delete.string(APIKey.imageReference), "docker.io/library/alpine:3.22")
        XCTAssertEqual(delete.bool(APIKey.garbageCollect), false)

        // The builder image is skipped quietly, like the CLI.
        let before = daemon.images.routes.count
        try await client.deleteImage("ghcr.io/apple/container-builder-shim/builder:0.13.2")
        XCTAssertFalse(daemon.images.routes[before...].contains(APIRoute.imageDelete))
    }

    func testReferenceNormalization() {
        let n = { (text: String) in APIImageReference.normalize(text) }
        XCTAssertEqual(n("alpine"), "docker.io/library/alpine:latest")
        XCTAssertEqual(n("alpine:3.22"), "docker.io/library/alpine:3.22")
        XCTAssertEqual(n("grafana/grafana"), "docker.io/grafana/grafana:latest")
        XCTAssertEqual(n("docker.io/nginx"), "docker.io/library/nginx:latest")
        XCTAssertEqual(n("ghcr.io/apple/x:1"), "ghcr.io/apple/x:1")
        XCTAssertEqual(n("localhost:5000/app"), "localhost:5000/app:latest")
        XCTAssertEqual(n("a@sha256:" + String(repeating: "a", count: 64)), "docker.io/library/a@sha256:" + String(repeating: "a", count: 64))
        XCTAssertNil(n("Upper/Case"))
        XCTAssertNil(n(""))
        XCTAssertEqual(APIImageReference.normalize("alpine", defaultDomain: "registry.example.com"), "registry.example.com/alpine:latest")
    }

    func testInfraImagesAreHidden() {
        let settings = DirectAPISettings(registryDomain: { "docker.io" }, configuredInfraImages: { ["my/builder:1"] }, sshAuthSocket: { nil }, fileExists: { _ in true })
        XCTAssertTrue(settings.isInfraImage("ghcr.io/apple/container-builder-shim/builder:0.13.2"))
        XCTAssertTrue(settings.isInfraImage("ghcr.io/apple/containerization/vminit:0.53.0"))
        XCTAssertTrue(settings.isInfraImage("my/builder:1"))
        XCTAssertFalse(settings.isInfraImage("docker.io/library/alpine:latest"))
    }
}

// MARK: - Requests for changes

final class DirectAPIRequestTests: XCTestCase {
    private func client(_ transport: FakeTransport, fileExists: Bool = true) -> DirectAPIClient {
        DirectAPIClient(apiServer: transport, imageService: transport, settings: DirectAPISettings(
            registryDomain: { "docker.io" }, configuredInfraImages: { [] }, sshAuthSocket: { "/tmp/agent.sock" }, fileExists: { _ in fileExists }))
    }

    func testStartBootstrapsThenStartsTheInitProcess() async throws {
        let daemon = try RecordedDaemon()
        let api = DirectAPIClient(apiServer: daemon.api, imageService: daemon.images, settings: DirectAPISettings(
            registryDomain: { "docker.io" }, configuredInfraImages: { [] }, sshAuthSocket: { "/tmp/agent.sock" }, fileExists: { _ in true }))
        try await api.startContainer("deck-demo-stopped")
        let routes = daemon.api.routes
        XCTAssertEqual(routes, [APIRoute.containerList, APIRoute.containerBootstrap, APIRoute.containerStartProcess])
        let bootstrap = daemon.api.requests[1]
        XCTAssertEqual(bootstrap.string(APIKey.id), "deck-demo-stopped")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(bootstrap.data(APIKey.dynamicEnv))) as? [String: String], ["SSH_AUTH_SOCK": "/tmp/agent.sock"])
        let start = daemon.api.requests[2]
        XCTAssertEqual(start.string(APIKey.processIdentifier), "deck-demo-stopped")
    }

    func testStartOfRunningContainerDoesNothing() async throws {
        let daemon = try RecordedDaemon()
        try await daemon.client().startContainer("deck-demo-web")
        XCTAssertEqual(daemon.api.routes, [APIRoute.containerList])
    }

    func testStartWithMissingSharedFolderGoesToCLI() async throws {
        let daemon = try RecordedDaemon()
        let api = DirectAPIClient(apiServer: daemon.api, imageService: daemon.images, settings: DirectAPISettings(
            registryDomain: { "docker.io" }, configuredInfraImages: { [] }, sshAuthSocket: { nil }, fileExists: { _ in false }))
        // buildkit shares a host folder. Make it stopped so start gets to the folder check.
        var items = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(APIFixtures.containerList.utf8)) as? [[String: Any]])
        for index in items.indices { items[index]["status"] = "stopped" }
        let stopped = try JSONSerialization.data(withJSONObject: items)
        daemon.api.setHandler { request in
            request.route == APIRoute.containerList ? .success(XPCReply([APIKey.containers: .data(stopped)])) : .success(XPCReply())
        }
        do {
            try await api.startContainer("buildkit")
            XCTFail("Expected needsCLI")
        } catch let error as APIError {
            guard case .needsCLI(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("/Users/me/Library/Application Support/com.apple.container/builder"))
        }
        XCTAssertFalse(daemon.api.routes.contains(APIRoute.containerBootstrap))
    }

    func testFailedStartIsStoppedAgain() async throws {
        let daemon = try RecordedDaemon()
        let list = RecordedDaemon.filteredList
        daemon.api.setHandler { request in
            switch request.route {
            case APIRoute.containerList: return .success(XPCReply([APIKey.containers: list(request)]))
            case APIRoute.containerStartProcess: return .success(XPCReply([APIKey.error: data(#"{"code":"internalError","message":"boom"}"#)]))
            default: return .success(XPCReply())
            }
        }
        do {
            try await daemon.client().startContainer("deck-demo-stopped")
            XCTFail("Expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(code: "internalError", message: "boom"))
        }
        XCTAssertEqual(daemon.api.routes.last, APIRoute.containerStop)
    }

    func testStopKillDeleteRequests() async throws {
        let transport = FakeTransport { _ in .success(XPCReply()) }
        let api = client(transport)
        try await api.stopContainer("web")
        try await api.killContainer("web")
        try await api.deleteContainer("web", force: true)
        let requests = transport.requests
        XCTAssertEqual(requests.map(\.route), [APIRoute.containerStop, APIRoute.containerKill, APIRoute.containerDelete])
        let stop = try JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].data(APIKey.stopOptions))) as? NSDictionary
        XCTAssertEqual(stop, ["timeoutInSeconds": 5] as NSDictionary, "nil signal is left out like Apple's encoder")
        XCTAssertEqual(requests[1].string(APIKey.signal), "KILL")
        XCTAssertEqual(requests[1].string(APIKey.processIdentifier), "web")
        XCTAssertEqual(requests[2].bool(APIKey.forceDelete), true)

        try await api.stopContainer("web", timeoutSeconds: 1, signal: "SIGTERM")
        let custom = try JSONSerialization.jsonObject(with: try XCTUnwrap(transport.requests.last?.data(APIKey.stopOptions))) as? NSDictionary
        XCTAssertEqual(custom, ["timeoutInSeconds": 1, "signal": "SIGTERM"] as NSDictionary)
    }

    func testVolumeAndNetworkCreateRequests() async throws {
        let transport = FakeTransport { request in
            if request.route == APIRoute.networkList { return .success(XPCReply([APIKey.networkResources: data(APIFixtures.networkList)])) }
            return .success(XPCReply())
        }
        let api = client(transport)
        try await api.createVolume(name: "v1", size: "1G", labels: ["a": "b", "": "skip"])
        let volume = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(volume.string(APIKey.volumeName), "v1")
        XCTAssertEqual(volume.string(APIKey.volumeDriver), "local")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(volume.data(APIKey.volumeDriverOpts))) as? [String: String], ["size": "1G"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(volume.data(APIKey.volumeLabels))) as? [String: String], ["a": "b"])

        try await api.createNetwork(name: "n1", subnet: "10.9.0.0/24", subnetV6: nil, internal: true, labels: ["x": "y"])
        let network = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(network.string(APIKey.networkId), "n1")
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(network.data(APIKey.networkConfig))) as? [String: Any])
        XCTAssertEqual(config["name"] as? String, "n1")
        XCTAssertEqual(config["mode"] as? String, "hostOnly")
        XCTAssertEqual(config["ipv4Subnet"] as? String, "10.9.0.0/24")
        XCTAssertNil(config["ipv6Subnet"])
        XCTAssertEqual(config["plugin"] as? String, "container-network-vmnet")
        XCTAssertEqual(config["labels"] as? [String: String], ["x": "y"])
        // Seconds since 2001, like Apple's encoder.
        let created = try XCTUnwrap(config["creationDate"] as? Double)
        XCTAssertEqual(created, Date().timeIntervalSinceReferenceDate, accuracy: 60)

        // The builtin network goes to the CLI for its message. Others are deleted.
        do {
            try await api.deleteNetwork("default")
            XCTFail("Expected needsCLI")
        } catch let error as APIError {
            guard case .needsCLI = error else { return XCTFail("\(error)") }
        }
        try await api.deleteNetwork("deck-demo-net")
        XCTAssertEqual(transport.requests.last?.route, APIRoute.networkDelete)
        XCTAssertEqual(transport.requests.last?.string(APIKey.networkId), "deck-demo-net")
    }

    func testMessageEncodingKeepsRouteAndValues() {
        var request = XPCRequest(route: APIRoute.containerKill)
        request.set(APIKey.id, "web")
        request.set(APIKey.forceDelete, true)
        request.set("n", UInt64(7))
        request.set(APIKey.listFilters, data: Data("{}".utf8))
        let message = XPCConnection.makeMessage(request)
        let values = XPCConnection.readDictionary(message)
        if case .string(let route)? = values[APIKey.route] { XCTAssertEqual(route, "containerKill") } else { XCTFail("route") }
        if case .string(let id)? = values[APIKey.id] { XCTAssertEqual(id, "web") } else { XCTFail("id") }
        if case .bool(let flag)? = values[APIKey.forceDelete] { XCTAssertTrue(flag) } else { XCTFail("bool") }
        if case .uint64(let number)? = values["n"] { XCTAssertEqual(number, 7) } else { XCTFail("uint64") }
        XCTAssertEqual(XPCReply(values).data(APIKey.listFilters), Data("{}".utf8))
    }
}

// MARK: - Timeouts and cancellation

final class XPCTransportTests: XCTestCase {
    func testTimeoutWithSilentConnection() async throws {
        let silent = FakeTransport { _ in nil }
        let started = Date()
        do {
            _ = try await silent.call(XPCRequest(route: "containerList"), timeout: .milliseconds(200))
            XCTFail("Expected a timeout")
        } catch let error as APIError {
            guard case .timeout(let route, let seconds) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(route, "containerList")
            XCTAssertEqual(seconds, 0.2, accuracy: 0.001)
            XCTAssertTrue(error.isTransportFailure)
            XCTAssertFalse(error.requestNotApplied, "A change that timed out may still run")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testLateReplyAfterTimeoutIsDropped() async throws {
        let slow = FakeTransport { _ in .success(XPCReply(["k": .string("v")])) }
        slow.delay = 0.4
        do {
            _ = try await slow.call(XPCRequest(route: "ping"), timeout: .milliseconds(100))
            XCTFail("Expected a timeout")
        } catch APIError.timeout {
            // expected
        }
        try await Task.sleep(for: .milliseconds(600))
        // A fast reply in time works on the same transport.
        slow.delay = 0
        let reply = try await slow.call(XPCRequest(route: "ping"), timeout: .seconds(1))
        XCTAssertEqual(reply.string("k"), "v")
    }

    func testCancellation() async throws {
        let silent = FakeTransport { _ in nil }
        let task = Task { try await silent.call(XPCRequest(route: "containerLogs"), timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testConnectionErrorsMapToKinds() async throws {
        let down = FakeTransport { request in .failure(.serviceUnavailable(route: request.route)) }
        do {
            _ = try await down.call(XPCRequest(route: "ping"))
        } catch let error as APIError {
            XCTAssertEqual(error, .serviceUnavailable(route: "ping"))
            XCTAssertFalse(error.isTransportFailure, "A stopped daemon is not a reason to use the CLI")
            XCTAssertEqual(error.localizedDescription, "The container services are not running.")
        }
        XCTAssertTrue(APIError.interrupted(route: "x").isTransportFailure)
        XCTAssertTrue(APIError.interrupted(route: "x").requestNotApplied)
    }

    /// The real connection to a service name nobody registered fails fast as unavailable.
    func testRealConnectionToMissingService() async throws {
        let connection = XPCConnection(serviceName: "\(AppConfig.bundleID).missing-service-for-tests")
        do {
            _ = try await connection.call(XPCRequest(route: "ping"), timeout: .seconds(5))
            XCTFail("Expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .serviceUnavailable(route: "ping"))
        }
    }
}

// MARK: - Logs

final class APILogReaderTests: XCTestCase {
    private func file(_ text: String) throws -> (URL, OwnedFileDescriptor) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deck-log-\(UUID().uuidString).log")
        try Data(text.utf8).write(to: url)
        let fd = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        return (url, OwnedFileDescriptor(fd))
    }

    func testTailAndWholeFile() async throws {
        let (url, fd) = try file("one\n\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(at: url) }
        var lines: [String] = []
        try await APILogReader.read(fd, tail: 2, follow: false) { lines.append($0) }
        XCTAssertEqual(lines, ["two", "three"])
        lines = []
        try await APILogReader.read(fd, tail: nil, follow: false) { lines.append($0) }
        XCTAssertEqual(lines, ["one", "", "two", "three"], "Whole file keeps blank lines like the CLI")
        lines = []
        try await APILogReader.read(fd, tail: 0, follow: false) { lines.append($0) }
        XCTAssertEqual(lines, [])
    }

    func testTailAcrossChunks() throws {
        let many = (1...30_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let (url, fd) = try file(many)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = try APILogReader.size(fd.rawValue)
        let lines = try APILogReader.lastLines(fd.rawValue, count: 10_000, end: size)
        XCTAssertEqual(lines.count, 10_000)
        XCTAssertEqual(lines.first, "line 20001")
        XCTAssertEqual(lines.last, "line 30000")
    }

    func testFollowPicksUpNewLines() async throws {
        let (url, fd) = try file("old\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let collector = LineCollector()
        let task = Task {
            try await APILogReader.read(fd, tail: 1, follow: true) { collector.add($0) }
        }
        try await Task.sleep(for: .milliseconds(300))
        let writer = try FileHandle(forWritingTo: url)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("new 1\nnew ".utf8))
        try await Task.sleep(for: .milliseconds(400))
        try writer.write(contentsOf: Data("2\n".utf8))
        try writer.close()
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(collector.lines, ["old", "new 1", "new 2"], "A line split across writes stays one line")
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
