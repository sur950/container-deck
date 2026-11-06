import XCTest
import CryptoKit
@testable import DeckCore

final class EngineDockerAPITests: XCTestCase {

    func testParseImages() throws {
        let json = """
        [{"Containers":-1,"Created":1700000000,"Id":"sha256:aaa","Labels":null,"ParentId":"","RepoDigests":["nginx@sha256:111"],"RepoTags":["nginx:latest","nginx:1.27"],"SharedSize":-1,"Size":187000000},
         {"Created":1700000100,"Id":"sha256:bbb","RepoDigests":[],"RepoTags":["myapp:dev"],"Size":52000000},
         {"Created":1700000200,"Id":"sha256:ccc","RepoDigests":["<none>@<none>"],"RepoTags":["<none>:<none>"],"Size":1000}]
        """
        let images = try DockerAPIParser.parseImages(json)
        XCTAssertEqual(images.count, 3)
        XCTAssertEqual(images[0].repoTags, ["nginx:latest", "nginx:1.27"])
        XCTAssertEqual(images[0].repoDigests, ["nginx@sha256:111"])
        XCTAssertEqual(images[0].size, 187_000_000)
        XCTAssertEqual(images[0].created, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(images[2].repoTags, [])
        XCTAssertEqual(images[2].repoDigests, [])
        XCTAssertEqual(try DockerAPIParser.parseImages("null"), [])
        XCTAssertThrowsError(try DockerAPIParser.parseImages("{oops"))
    }

    func testParseVersionInfoInspect() throws {
        let version = try DockerAPIParser.parseVersion(#"{"Platform":{"Name":"Docker Desktop 4.36.0 (175267)"},"Version":"27.3.1","ApiVersion":"1.47","Components":[{"Name":"Engine","Version":"27.3.1"}]}"#)
        XCTAssertEqual(version.version, "27.3.1")
        XCTAssertEqual(version.apiVersion, "1.47")
        XCTAssertFalse(version.isPodman)

        let podman = try DockerAPIParser.parseVersion(#"{"Platform":{"Name":"linux/arm64/fedora-40"},"Components":[{"Name":"Podman Engine"}],"Version":"5.2.3"}"#)
        XCTAssertTrue(podman.isPodman)

        let info = try DockerAPIParser.parseInfo(#"{"ID":"X1","Name":"colima","OperatingSystem":"Ubuntu 24.04 LTS","ServerVersion":"27.1.1","Images":4}"#)
        XCTAssertEqual(info.id, "X1")
        XCTAssertEqual(info.name, "colima")
        XCTAssertEqual(info.images, 4)

        let inspect = try DockerAPIParser.parseImageInspect(#"{"Id":"sha256:aaa","Architecture":"amd64","Os":"linux","Size":1}"#)
        XCTAssertEqual(inspect.architecture, "amd64")
        XCTAssertEqual(inspect.os, "linux")
    }

    func testEscaping() {
        XCTAssertEqual(DockerAPIParser.escapeQuery("ghcr.io/a/b:1.0"), "ghcr.io%2Fa%2Fb%3A1.0")
        XCTAssertEqual(DockerAPIParser.escapePath("ghcr.io/a/b:1.0"), "ghcr.io/a/b:1.0")
    }

    func testParseSize() {
        XCTAssertEqual(DockerAPIParser.parseSize("8.5MB"), 8_500_000)
        XCTAssertEqual(DockerAPIParser.parseSize("1 GiB"), 1_073_741_824)
        XCTAssertEqual(DockerAPIParser.parseSize("512kB"), 512_000)
        XCTAssertEqual(DockerAPIParser.parseSize("12B"), 12)
        XCTAssertEqual(DockerAPIParser.parseSize("n/a"), 0)
    }

    func testNerdctlParsing() {
        let text = """
        {"CreatedAt":"2024-05-01 10:20:30 +0000 UTC","Digest":"sha256:d1","ID":"abc","Platform":"linux/arm64","Repository":"docker.io/library/redis","Size":"40.1MB","Tag":"7"}
        {"Repository":"<none>","Tag":"<none>","ID":"zzz"}
        not json
        """
        let images = NerdctlEngine.parseImages(text)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.reference, "docker.io/library/redis:7")
        XCTAssertEqual(images.first?.platform, "linux/arm64")
        XCTAssertEqual(images.first?.sizeBytes, 40_100_000)
        XCTAssertNotNil(images.first?.createdAt)
    }

    func testImagesPerTagAndMerge() {
        let docker = DetectedEngine(id: "socket:/a", kind: .dockerDesktop, name: "Docker Desktop", state: .running)
        let orb = DetectedEngine(id: "socket:/b", kind: .orbStack, name: "OrbStack", state: .running)
        let entries = [
            DockerImageEntry(id: "sha256:aaa", repoTags: ["nginx:latest", "nginx:1.27"], repoDigests: ["nginx@sha256:1"], size: 10),
            DockerImageEntry(id: "sha256:bbb", repoTags: ["myapp:dev"], size: 20)
        ]
        let details = ["sha256:aaa": DockerImageInspect(architecture: "arm64", os: "linux"),
                       "sha256:bbb": DockerImageInspect(architecture: "amd64", os: "linux")]
        let fromDocker = EngineCatalog.images(from: entries, details: details, engine: docker)
        XCTAssertEqual(fromDocker.count, 3)
        XCTAssertTrue(fromDocker[0].canPullFromRegistry)
        XCTAssertFalse(fromDocker[2].canPullFromRegistry)
        XCTAssertTrue(fromDocker[2].isAmd64)

        let fromOrb = EngineCatalog.images(
            from: [DockerImageEntry(id: "sha256:other", repoTags: ["docker.io/library/nginx:latest"], size: 10)],
            details: [:], engine: orb
        )
        let merged = EngineCatalog.merge([fromDocker, fromOrb], localReferences: ["docker.io/library/nginx:1.27"])
        XCTAssertEqual(merged.count, 3, "nginx:latest shows once")
        let latest = merged.first { $0.normalizedReference == "docker.io/library/nginx:latest" }
        XCTAssertEqual(latest?.engineName, "Docker Desktop")
        XCTAssertEqual(latest?.alsoIn, ["OrbStack"])
        XCTAssertEqual(merged.first { $0.reference == "nginx:1.27" }?.alreadyHere, true)
        XCTAssertEqual(merged.first { $0.reference == "myapp:dev" }?.alreadyHere, false)
    }

    func testDiskSpaceEstimate() {
        let images = [
            EngineImage(engineID: "e", engineName: "E", imageID: "1", reference: "a", sizeBytes: 100),
            EngineImage(engineID: "e", engineName: "E", imageID: "2", reference: "b", sizeBytes: 50)
        ]
        XCTAssertEqual(EngineImporter.requiredBytes(for: images), 300)
        XCTAssertEqual(
            EngineImporter.packArguments(layout: "/w/oci", output: "/w/out.tar"),
            ["COPYFILE_DISABLE=1", "/usr/bin/tar", "-cf", "/w/out.tar", "-C", "/w/oci", "oci-layout", "index.json", "blobs"]
        )
    }

    func testImportStep() {
        XCTAssertEqual(ImportStep.exporting(done: 50, total: 100).fraction, 0.5)
        XCTAssertNil(ImportStep.loading.fraction)
        XCTAssertTrue(ImportStep.done(method: "x").isFinished)
        XCTAssertTrue(ImportStep.loading.isActive)
        XCTAssertFalse(ImportStep.waiting.isActive)
    }
}

final class EngineOCITests: XCTestCase {

    private func sha(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testDockerManifestParsing() throws {
        let json = #"[{"Config":"abc.json","RepoTags":["app:1"],"Layers":["l1/layer.tar","l2/layer.tar"]},{"Config":"def.json","RepoTags":null,"Layers":[]}]"#
        let entries = try OCIArchive.parseDockerManifest(Data(json.utf8))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0], OCIArchive.DockerArchiveEntry(config: "abc.json", repoTags: ["app:1"], layers: ["l1/layer.tar", "l2/layer.tar"]))
        XCTAssertEqual(entries[1].repoTags, [])
        XCTAssertThrowsError(try OCIArchive.parseDockerManifest(Data("[]".utf8)))
    }

    func testLayerMediaType() {
        XCTAssertEqual(OCIArchive.detectLayerMediaType(header: [0x1F, 0x8B, 0x08, 0x00]), OCIArchive.layerGzipMediaType)
        XCTAssertEqual(OCIArchive.detectLayerMediaType(header: [0x28, 0xB5, 0x2F, 0xFD]), OCIArchive.layerZstdMediaType)
        XCTAssertEqual(OCIArchive.detectLayerMediaType(header: [0x61, 0x62, 0x63, 0x00]), OCIArchive.layerMediaType)
        XCTAssertEqual(OCIArchive.detectLayerMediaType(header: []), OCIArchive.layerMediaType)
    }

    func testPlatformFromConfig() {
        let config = Data(#"{"architecture":"arm64","os":"linux","variant":"v8","config":{}}"#.utf8)
        XCTAssertEqual(OCIArchive.platform(fromConfig: config), OCIArchive.Platform(architecture: "arm64", os: "linux", variant: "v8"))
        XCTAssertNil(OCIArchive.platform(fromConfig: Data("{}".utf8)))
    }

    func testManifestAndIndexJSON() throws {
        let config = OCIArchive.Descriptor(mediaType: OCIArchive.configMediaType, digest: "sha256:c", size: 10)
        let layer = OCIArchive.Descriptor(mediaType: OCIArchive.layerMediaType, digest: "sha256:l", size: 20)
        let manifestData = try OCIArchive.imageManifest(config: config, layers: [layer])
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 2)
        XCTAssertEqual(manifest["mediaType"] as? String, "application/vnd.oci.image.manifest.v1+json")
        XCTAssertEqual((manifest["config"] as? [String: Any])?["digest"] as? String, "sha256:c")
        XCTAssertEqual((manifest["layers"] as? [[String: Any]])?.first?["mediaType"] as? String, "application/vnd.oci.image.layer.v1.tar")
        // Media types keep their slashes unescaped.
        XCTAssertFalse(String(decoding: manifestData, as: UTF8.self).contains("\\/"))

        let entry = OCIArchive.indexEntry(
            manifestDigest: OCIArchive.sha256Digest(manifestData), manifestSize: Int64(manifestData.count),
            platform: OCIArchive.Platform(architecture: "arm64", os: "linux"), reference: "app:1"
        )
        let indexData = try OCIArchive.index(manifests: [entry])
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: indexData) as? [String: Any])
        let first = try XCTUnwrap((index["manifests"] as? [[String: Any]])?.first)
        let annotations = try XCTUnwrap(first["annotations"] as? [String: String])
        XCTAssertEqual(annotations[OCIArchive.appleNameKey], "docker.io/library/app:1")
        XCTAssertEqual(annotations[OCIArchive.ociRefNameKey], "docker.io/library/app:1")
        XCTAssertEqual(first["digest"] as? String, sha(manifestData))
        XCTAssertEqual((first["platform"] as? [String: Any])?["architecture"] as? String, "arm64")
        XCTAssertNil((first["platform"] as? [String: Any])?["variant"])
    }

    func testPatchedIndex() throws {
        let tagOnly = Data(#"{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:x","size":1,"annotations":{"org.opencontainers.image.ref.name":"latest"}}]}"#.utf8)
        let patched = try XCTUnwrap(try OCIArchive.patchedIndex(tagOnly, reference: "redis:latest"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: patched) as? [String: Any])
        let annotations = (root["manifests"] as? [[String: Any]])?.first?["annotations"] as? [String: String]
        XCTAssertEqual(annotations?[OCIArchive.appleNameKey], "docker.io/library/redis:latest")
        XCTAssertEqual(annotations?[OCIArchive.ociRefNameKey], "latest")

        let named = Data(#"{"schemaVersion":2,"manifests":[{"digest":"sha256:x","annotations":{"io.containerd.image.name":"docker.io/library/redis:7"}}]}"#.utf8)
        XCTAssertNil(try OCIArchive.patchedIndex(named, reference: "redis:7"))
    }

    func testPrunedIndex() throws {
        let nested = Data(#"{"schemaVersion":2,"manifests":[{"digest":"sha256:arm","platform":{"architecture":"arm64","os":"linux"}},{"digest":"sha256:amd","platform":{"architecture":"amd64","os":"linux"}}]}"#.utf8)
        let pruned = try XCTUnwrap(try OCIArchive.prunedIndex(nested) { $0 == "sha256:arm" })
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: pruned) as? [String: Any])
        XCTAssertEqual((root["manifests"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(try OCIArchive.prunedIndex(nested) { _ in true })
        XCTAssertNil(try OCIArchive.prunedIndex(nested) { _ in false })
    }

    func testConvertDockerArchiveOnDisk() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("deck-oci-test-\(UUID().uuidString)")
        let source = root.appendingPathComponent("src")
        let output = root.appendingPathComponent("oci")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: source.appendingPathComponent("l1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("l2"), withIntermediateDirectories: true)

        let config = Data(#"{"architecture":"amd64","os":"linux","rootfs":{"type":"layers","diff_ids":[]}}"#.utf8)
        let layer1 = Data("plain layer one".utf8)
        let layer2 = Data([0x1F, 0x8B, 0x08, 0x00, 0x01, 0x02])
        try config.write(to: source.appendingPathComponent("cfg.json"))
        try layer1.write(to: source.appendingPathComponent("l1/layer.tar"))
        try layer2.write(to: source.appendingPathComponent("l2/layer.tar"))
        let manifest = #"[{"Config":"cfg.json","RepoTags":["myapp:dev"],"Layers":["l1/layer.tar","l2/layer.tar","l1/layer.tar"]}]"#
        try Data(manifest.utf8).write(to: source.appendingPathComponent("manifest.json"))
        XCTAssertEqual(OCIArchive.kind(ofExtracted: source), .dockerArchive)

        let refs = try OCIArchive.convertDockerArchive(at: source, to: output, fallbackReference: "fallback:1")
        XCTAssertEqual(refs, ["docker.io/library/myapp:dev"])
        XCTAssertEqual(OCIArchive.kind(ofExtracted: output), .ociLayout)

        let blobs = output.appendingPathComponent("blobs/sha256")
        XCTAssertTrue(fm.fileExists(atPath: blobs.appendingPathComponent(OCIArchive.encoded(sha(config))).path))
        XCTAssertTrue(fm.fileExists(atPath: blobs.appendingPathComponent(OCIArchive.encoded(sha(layer1))).path))
        XCTAssertTrue(fm.fileExists(atPath: blobs.appendingPathComponent(OCIArchive.encoded(sha(layer2))).path))

        let indexData = try Data(contentsOf: output.appendingPathComponent("index.json"))
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: indexData) as? [String: Any])
        let entry = try XCTUnwrap((index["manifests"] as? [[String: Any]])?.first)
        let manifestDigest = try XCTUnwrap(entry["digest"] as? String)
        let manifestData = try Data(contentsOf: blobs.appendingPathComponent(OCIArchive.encoded(manifestDigest)))
        XCTAssertEqual(sha(manifestData), manifestDigest)
        XCTAssertEqual(entry["size"] as? Int, manifestData.count)
        XCTAssertEqual((entry["platform"] as? [String: Any])?["architecture"] as? String, "amd64")

        let imageManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let layers = try XCTUnwrap(imageManifest["layers"] as? [[String: Any]])
        XCTAssertEqual(layers.count, 3)
        XCTAssertEqual(layers[0]["digest"] as? String, sha(layer1))
        XCTAssertEqual(layers[1]["mediaType"] as? String, OCIArchive.layerGzipMediaType)
        XCTAssertEqual(layers[2]["digest"] as? String, sha(layer1), "A reused layer keeps its digest")
        XCTAssertEqual((imageManifest["config"] as? [String: Any])?["digest"] as? String, sha(config))

        let layout = try String(contentsOf: output.appendingPathComponent("oci-layout"), encoding: .utf8)
        XCTAssertTrue(layout.contains("1.0.0"))
    }

    func testNormalizeOCILayoutPrunesMissingPlatforms() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("deck-oci-norm-\(UUID().uuidString)")
        let blobs = dir.appendingPathComponent("blobs/sha256")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)

        let armManifest = Data(#"{"schemaVersion":2}"#.utf8)
        try armManifest.write(to: blobs.appendingPathComponent(OCIArchive.encoded(sha(armManifest))))
        let nested = Data("""
        {"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
          {"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\(sha(armManifest))","size":\(armManifest.count),"platform":{"architecture":"arm64","os":"linux"}},
          {"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:0000","size":10,"platform":{"architecture":"amd64","os":"linux"}}]}
        """.utf8)
        try nested.write(to: blobs.appendingPathComponent(OCIArchive.encoded(sha(nested))))
        let index = Data("""
        {"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"\(sha(nested))","size":\(nested.count),"annotations":{"org.opencontainers.image.ref.name":"1.0"}}]}
        """.utf8)
        try index.write(to: dir.appendingPathComponent("index.json"))
        try OCIArchive.ociLayoutFile().write(to: dir.appendingPathComponent("oci-layout"))

        XCTAssertTrue(try OCIArchive.normalizeOCILayout(at: dir, reference: "tool:1.0"))
        let newIndex = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("index.json"))) as? [String: Any])
        let entry = try XCTUnwrap((newIndex["manifests"] as? [[String: Any]])?.first)
        let newDigest = try XCTUnwrap(entry["digest"] as? String)
        XCTAssertNotEqual(newDigest, sha(nested))
        let newNested = try Data(contentsOf: blobs.appendingPathComponent(OCIArchive.encoded(newDigest)))
        XCTAssertEqual(sha(newNested), newDigest)
        XCTAssertEqual(entry["size"] as? Int, newNested.count)
        let nestedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: newNested) as? [String: Any])
        XCTAssertEqual((nestedRoot["manifests"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((entry["annotations"] as? [String: String])?[OCIArchive.appleNameKey], "docker.io/library/tool:1.0")
    }
}
