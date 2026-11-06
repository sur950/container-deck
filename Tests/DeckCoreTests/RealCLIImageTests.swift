import XCTest
@testable import DeckCore

// Output recorded from Apple's `container` CLI 1.6.1 on macOS 27 (Apple silicon)
// and from the Docker Hub API on 2026-11-05. Trimmed to a few platforms, values unchanged.

enum RealCLIImageFixtures {
    /// `container image list --format json` (alpine:latest trimmed to amd64, arm64 and one attestation).
    static let imageList = #"""
[{"configuration":{"creationDate":"2026-10-21T22:34:15Z","descriptor":{"digest":"sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a","mediaType":"application/vnd.oci.image.index.v1+json","size":9218},"name":"docker.io/library/alpine:latest"},"id":"be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a","variants":[{"config":{"architecture":"amd64","config":{"Cmd":["/bin/sh"],"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"WorkingDir":"/"},"created":"2026-10-21T22:37:22.870489069Z","history":[{"comment":"buildkit.dockerfile.v0","created":"2026-10-21T22:37:22.870489069Z","created_by":"ADD alpine-minirootfs-3.24.3-x86_64.tar.gz / # buildkit"},{"comment":"buildkit.dockerfile.v0","created":"2026-10-21T22:37:22.870489069Z","created_by":"CMD [\"/bin/sh\"]","empty_layer":true}],"os":"linux","rootfs":{"diff_ids":["sha256:75c137aedfb2760f88629236cb7b797630aed0c3d91d626d1d1bb694878fc2ba"],"type":"layers"}},"digest":"sha256:c26612752c78b18faacd63c7d50f4592c2e7b0f25e0e20e82bd74e465c57ab0d","platform":{"architecture":"amd64","os":"linux"},"size":3854742},{"config":{"architecture":"arm64","config":{"Cmd":["/bin/sh"],"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"WorkingDir":"/"},"created":"2026-10-21T22:51:39.084385804Z","history":[{"comment":"buildkit.dockerfile.v0","created":"2026-10-21T22:51:39.084385804Z","created_by":"ADD alpine-minirootfs-3.24.3-aarch64.tar.gz / # buildkit"},{"comment":"buildkit.dockerfile.v0","created":"2026-10-21T22:51:39.084385804Z","created_by":"CMD [\"/bin/sh\"]","empty_layer":true}],"os":"linux","rootfs":{"diff_ids":["sha256:a278e6f39431cd0ed74238a3d377893ad0d905d68b676bf9a65529080669756b"],"type":"layers"},"variant":"v8"},"digest":"sha256:e311ae748be7f56ae5cba304bc488f0786df68ee507513f654a5cc8597cffb42","platform":{"architecture":"arm64","os":"linux","variant":"v8"},"size":4192140},{"config":{"architecture":"unknown","config":{},"os":"unknown","rootfs":{"diff_ids":["sha256:3ec36f3670df56d1b1d4323910cf6747576cb31e5e5d32c64715339876d86f20","sha256:3da1513d2124248e6e2a526d532ff365833915ce1abe0813bfc5344190827406"],"type":"layers"}},"digest":"sha256:964745728d174226819257152a79b34561fe7321472eb9c8e32f461cbc7969c2","platform":{"architecture":"unknown","os":"unknown"},"size":86391}]},{"configuration":{"creationDate":"2026-11-05T12:27:30Z","descriptor":{"annotations":{"com.apple.containerization.image.name":"docker.io/library/deck-test-build:v1","io.containerd.image.name":"docker.io/library/deck-test-build:v1","org.opencontainers.image.created":"2026-11-05T12:27:30Z","org.opencontainers.image.ref.name":"v1"},"digest":"sha256:b737cfb8399d6b1a6953d49a08460a7aa8904b99dd056d66e05d47555df24c63","mediaType":"application/vnd.oci.image.index.v1+json","size":374},"name":"docker.io/library/deck-test-build:v1"},"id":"b737cfb8399d6b1a6953d49a08460a7aa8904b99dd056d66e05d47555df24c63","variants":[{"config":{"architecture":"arm64","config":{"Cmd":["cat","/greeting.txt"],"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"WorkingDir":"/"},"created":"2026-11-05T12:27:30.188615336Z","history":[{"comment":"buildkit.dockerfile.v0","created":"2026-10-21T22:51:39.084385804Z","created_by":"ADD alpine-minirootfs-3.24.3-aarch64.tar.gz / # buildkit"},{"comment":"buildkit.dockerfile.v0","created":"2026-10-21T22:51:39.084385804Z","created_by":"CMD [\"/bin/sh\"]","empty_layer":true},{"comment":"buildkit.dockerfile.v0","created":"2026-11-05T12:27:30.188615336Z","created_by":"ARG GREETING=hello","empty_layer":true},{"comment":"buildkit.dockerfile.v0","created":"2026-11-05T12:27:30.188615336Z","created_by":"RUN |1 GREETING=hello /bin/sh -c echo \"$GREETING\" > /greeting.txt # buildkit"},{"comment":"buildkit.dockerfile.v0","created":"2026-11-05T12:27:30.188615336Z","created_by":"CMD [\"cat\" \"/greeting.txt\"]","empty_layer":true}],"os":"linux","rootfs":{"diff_ids":["sha256:a278e6f39431cd0ed74238a3d377893ad0d905d68b676bf9a65529080669756b","sha256:dea7e1706b45b76bf447da4194ab67b4a7c4d5103a326231cfc01eacc94b2ec6"],"type":"layers"}},"digest":"sha256:e4d7e60ac56a805c4f43799fdd97e515d56aed8c600ec3e7348605dbb68ae839","platform":{"architecture":"arm64","os":"linux"},"size":4192446}]}]
"""#

    /// `container image inspect alpine:latest` (trimmed the same way).
    static let imageInspect = #"""
[
  {
    "configuration": {
      "creationDate": "2026-10-21T22:34:15Z",
      "descriptor": {
        "digest": "sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a",
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "size": 9218
      },
      "name": "docker.io/library/alpine:latest"
    },
    "id": "be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a",
    "variants": [
      {
        "config": {
          "architecture": "amd64",
          "config": {
            "Cmd": [
              "/bin/sh"
            ],
            "Env": [
              "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            ],
            "WorkingDir": "/"
          },
          "created": "2026-10-21T22:37:22.870489069Z",
          "history": [
            {
              "comment": "buildkit.dockerfile.v0",
              "created": "2026-10-21T22:37:22.870489069Z",
              "created_by": "ADD alpine-minirootfs-3.24.3-x86_64.tar.gz / # buildkit"
            },
            {
              "comment": "buildkit.dockerfile.v0",
              "created": "2026-10-21T22:37:22.870489069Z",
              "created_by": "CMD [\"/bin/sh\"]",
              "empty_layer": true
            }
          ],
          "os": "linux",
          "rootfs": {
            "diff_ids": [
              "sha256:75c137aedfb2760f88629236cb7b797630aed0c3d91d626d1d1bb694878fc2ba"
            ],
            "type": "layers"
          }
        },
        "digest": "sha256:c26612752c78b18faacd63c7d50f4592c2e7b0f25e0e20e82bd74e465c57ab0d",
        "platform": {
          "architecture": "amd64",
          "os": "linux"
        },
        "size": 3854742
      },
      {
        "config": {
          "architecture": "arm64",
          "config": {
            "Cmd": [
              "/bin/sh"
            ],
            "Env": [
              "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            ],
            "WorkingDir": "/"
          },
          "created": "2026-10-21T22:51:39.084385804Z",
          "history": [
            {
              "comment": "buildkit.dockerfile.v0",
              "created": "2026-10-21T22:51:39.084385804Z",
              "created_by": "ADD alpine-minirootfs-3.24.3-aarch64.tar.gz / # buildkit"
            },
            {
              "comment": "buildkit.dockerfile.v0",
              "created": "2026-10-21T22:51:39.084385804Z",
              "created_by": "CMD [\"/bin/sh\"]",
              "empty_layer": true
            }
          ],
          "os": "linux",
          "rootfs": {
            "diff_ids": [
              "sha256:a278e6f39431cd0ed74238a3d377893ad0d905d68b676bf9a65529080669756b"
            ],
            "type": "layers"
          },
          "variant": "v8"
        },
        "digest": "sha256:e311ae748be7f56ae5cba304bc488f0786df68ee507513f654a5cc8597cffb42",
        "platform": {
          "architecture": "arm64",
          "os": "linux",
          "variant": "v8"
        },
        "size": 4192140
      },
      {
        "config": {
          "architecture": "unknown",
          "config": {},
          "os": "unknown",
          "rootfs": {
            "diff_ids": [
              "sha256:3ec36f3670df56d1b1d4323910cf6747576cb31e5e5d32c64715339876d86f20",
              "sha256:3da1513d2124248e6e2a526d532ff365833915ce1abe0813bfc5344190827406"
            ],
            "type": "layers"
          }
        },
        "digest": "sha256:964745728d174226819257152a79b34561fe7321472eb9c8e32f461cbc7969c2",
        "platform": {
          "architecture": "unknown",
          "os": "unknown"
        },
        "size": 86391
      }
    ]
  }
]
"""#

    /// `container image pull busybox:latest` piped (default progress is plain when not a terminal).
    static let pullOutput = #"""
[1/2] Fetching image [0s]
[1/2] Fetching image [1s]
[1/2] Fetching image [2s]
[1/2] Fetching image (1 of 18 blobs) [3s]
[1/2] Fetching image (4 of 18 blobs) [4s]
[1/2] Fetching image (7 of 18 blobs) [5s]
[1/2] Fetching image (13 of 18 blobs) [6s]
[1/2] Fetching image (16 of 18 blobs) [7s]
[1/2] Fetching image 0% (18 of 52 blobs, 19 KB/16.7 MB, 2 KB/s) [8s]
[1/2] Fetching image 12% (20 of 52 blobs, 2.1/16.7 MB, 2 KB/s) [9s]
[1/2] Fetching image 12% (23 of 52 blobs, 2.1/16.7 MB, 1.4 MB/s) [10s]
[1/2] Fetching image 13% (23 of 52 blobs, 2.2/16.7 MB, 6 KB/s) [11s]
[1/2] Fetching image 23% (26 of 52 blobs, 3.9/16.7 MB, 1.2 MB/s) [12s]
[1/2] Fetching image 23% (27 of 52 blobs, 3.9/16.7 MB, 387 KB/s) [13s]
[1/2] Fetching image 28% (29 of 52 blobs, 4.8/16.7 MB, 917 KB/s) [14s]
[1/2] Fetching image 30% (30 of 52 blobs, 5.1/16.7 MB, 124 KB/s) [15s]
[1/2] Fetching image 38% (33 of 52 blobs, 6.4/16.7 MB, 124 KB/s) [16s]
[1/2] Fetching image 49% (36 of 52 blobs, 8.2/16.7 MB, 1.1 MB/s) [17s]
[1/2] Fetching image 49% (37 of 52 blobs, 8.2/16.7 MB, 1.1 MB/s) [18s]
[1/2] Fetching image 51% (38 of 52 blobs, 8.5/16.7 MB, 72 KB/s) [19s]
[1/2] Fetching image 62% (41 of 52 blobs, 10.4/16.7 MB, 72 KB/s) [20s]
[1/2] Fetching image 62% (42 of 52 blobs, 10.5/16.7 MB, 1.1 MB/s) [21s]
[1/2] Fetching image 76% (45 of 52 blobs, 12.8/16.7 MB, 684 KB/s) [22s]
[1/2] Fetching image 77% (45 of 52 blobs, 12.9/16.7 MB, 1.6 MB/s) [23s]
[1/2] Fetching image 88% (48 of 52 blobs, 14.7/16.7 MB, 1.3 MB/s) [24s]
[1/2] Fetching image 99% (50 of 52 blobs, 16.7/16.7 MB, 1.3 MB/s) [25s]
[2/2] Unpacking image [26s]
[2/2] Unpacking image for platform linux/amd64 [26s]
[2/2] Unpacking image for platform linux/arm/v5 [26s]
[2/2] Unpacking image for platform linux/arm/v6 0% [26s]
[2/2] Unpacking image for platform linux/arm/v7 0% [26s]
[2/2] Unpacking image for platform linux/arm64 [26s]
[2/2] Unpacking image for platform linux/386 [26s]
[2/2] Unpacking image for platform linux/ppc64le [26s]
[2/2] Unpacking image for platform linux/riscv64 [26s]
[2/2] Unpacking image for platform linux/s390x 0% [26s]
[2/2] Unpacking image for platform linux/s390x 100% (448 entries, 4.0 MB) [27s]
"""#

    /// `container image pull --platform linux/arm64 nosuchimage-deck-zz:latest`, exit 1.
    static let pullFailure = #"""
[1/2] Fetching image [0s]
[1/2] Fetching image [1s]
[1/2] Fetching image [1s]
Error: HTTP request to https://registry-1.docker.io/v2/library/nosuchimage-deck-zz/manifests/latest failed with response: 401 Unauthorized. Reason: Unknown, no credentials found for host registry-1.docker.io
"""#

    /// `container build --progress plain --file .../Dockerfile --tag deck-test-build:v1 --build-arg GREETING=hello --target final <dir>`.
    static let buildOutput = #"""
#1 [resolver] fetching image...docker.io/library/alpine:latest
#1 DONE 0.0s

#2 [internal] load build definition from Dockerfile
#2 transferring dockerfile: 182B 0.0s done
#2 DONE 0.0s

#3 [internal] load .dockerignore
#3 transferring context: 2B done
#3 DONE 0.0s

#4 oci-layout://docker.io/library/alpine:latest@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
#4 resolve docker.io/library/alpine:latest@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a 0.1s done
#4 DONE 0.1s

#4 oci-layout://docker.io/library/alpine:latest@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
#4 sha256:d3531b7a4f217bdc3426c57bcff84c170f086f456a39689d4a615c6d026c4be0 4.19MB / 4.19MB 0.1s done
#4 extracting sha256:d3531b7a4f217bdc3426c57bcff84c170f086f456a39689d4a615c6d026c4be0 0.1s done
#4 DONE 0.2s

#5 [linux/arm64 base 1/2] RUN echo "hello" > /greeting.txt
#5 DONE 0.1s

#6 exporting to oci image format
#6 exporting layers 0.0s done
#6 exporting manifest sha256:e4d7e60ac56a805c4f43799fdd97e515d56aed8c600ec3e7348605dbb68ae839 done
#6 exporting config sha256:15f380183728c66cafe3d1b82344566c92f84fbc1fbe60febe6103c6d260f76d
#6 exporting config sha256:15f380183728c66cafe3d1b82344566c92f84fbc1fbe60febe6103c6d260f76d done
#6 exporting manifest list sha256:b737cfb8399d6b1a6953d49a08460a7aa8904b99dd056d66e05d47555df24c63 done
#6 sending tarball 0.0s done
#6 DONE 0.1s
docker.io/library/deck-test-build:v1
"""#

    /// Last lines of a build whose RUN step exits 3. Exit 1.
    static let buildFailure = #"""
#4 CACHED

#5 [linux/arm64 1/2] RUN exit 3
#5 ERROR: process "/bin/sh -c exit 3" did not complete successfully: exit code: 3
------
 > [linux/arm64 1/2] RUN exit 3:
------
Error: unknown: "failed to solve: process "/bin/sh -c exit 3" did not complete successfully: exit code: 3"
"""#

    /// `container build --file /tmp/nonexist/Dockerfile <dir>`: usage help comes after the error.
    static let buildUsageFailure = """
    Error: file does not exist /tmp/nonexist/Dockerfile
    Usage: build [<options>] [<context-dir>]
      See 'build --help' for more information.
    """

    /// GET /v2/search/repositories/?query=nginx&page=1&page_size=25 (first two results).
    static let hubSearch = #"""
{"count":296024,"next":"https://hub.docker.com/v2/search/repositories/?page=2&page_size=25&query=nginx","previous":"","results":[{"repo_name":"nginx","short_description":"Official build of Nginx.","star_count":21417,"pull_count":13555094009,"repo_owner":"","is_automated":false,"is_official":true},{"repo_name":"nginx/nginx-ingress","short_description":"NGINX and  NGINX Plus Ingress Controllers for Kubernetes","star_count":124,"pull_count":1088404623,"repo_owner":"","is_automated":false,"is_official":false}]}
"""#

    /// GET /v2/search/repositories/ with no matches.
    static let hubSearchEmpty = #"""
{"count":0,"next":"","previous":"","results":[]}
"""#

    /// GET /v2/repositories/library/?ordering=pull_count (first two results).
    static let hubOfficial = #"""
{"count":181,"next":"https://hub.docker.com/v2/repositories/library/?ordering=pull_count&page=2&page_size=25","previous":null,"results":[{"name":"nginx","namespace":"library","description":"Official build of Nginx.","star_count":21417,"pull_count":13555461941,"last_updated":"2026-11-05T10:54:59.049287Z","is_private":false,"status_description":"active"},{"name":"memcached","namespace":"library","description":"Free & open source, high-performance, distributed memory object caching system.","star_count":2473,"pull_count":13433993863,"last_updated":"2026-11-05T11:35:06.437289Z","is_private":false,"status_description":"active"}]}
"""#

    /// GET /v2/repositories/grafana/grafana/tags?page=1&page_size=5 (first tag).
    static let hubTags = #"""
{"count":2045,"next":"https://hub.docker.com/v2/repositories/grafana/grafana/tags?page=2&page_size=5","previous":null,"results":[{"creator":35009,"id":1368656374,"images":[{"architecture":"amd64","variant":null,"digest":"sha256:a12ef1a503a076b5042703ece712bb673281031f44e8d8aa1b2ca61846bddf2f","os":"linux","size":306199628,"last_pushed":"2026-10-27T09:03:40.439979376Z"},{"architecture":"arm64","variant":null,"digest":"sha256:4d1944bc9c1577860a5102907f5a29671720c2ce9e226e021192ca3981c0ad04","os":"linux","size":290742723,"last_pushed":"2026-10-27T09:03:40.932227995Z"},{"architecture":"arm","variant":"v7","digest":"sha256:7308c21847312781bfd388e4942defa545ff3d77d891ec5001dced80b4fd3f00","os":"linux","size":284823167,"last_pushed":"2026-10-27T09:03:41.417103135Z"}],"last_updated":"2026-10-27T09:03:42.725007Z","last_updater":35009,"last_updater_username":"grafana","name":"13.2.5-distroless-slim","repository":135617,"full_size":306199628,"v2":true,"tag_status":"active","tag_last_pulled":"2026-11-05T12:19:58.663968958Z","tag_last_pushed":"2026-10-27T09:03:42.725007Z","media_type":"application/vnd.docker.distribution.manifest.list.v2+json","content_type":"image","digest":"sha256:84157cef34688322cd542b3137f4c6928d1f491143da4228be1f764aa643de52"}]}
"""#

    /// GET /v2/repositories/library/nosuch-deck-zz/tags, status 404.
    static let hubNotFound = #"""
{"message":"object not found","errinfo":{}}
"""#
}

final class RealCLIImageTests: XCTestCase {

    // MARK: image list and inspect

    func testRealImageList() throws {
        let images = try ContainerOutputParser.images(RealCLIImageFixtures.imageList, preferredArchitecture: "arm64")
        XCTAssertEqual(images.map(\.reference), ["docker.io/library/alpine:latest", "docker.io/library/deck-test-build:v1"])

        let alpine = images[0]
        XCTAssertEqual(alpine.shortName, "alpine")
        XCTAssertEqual(alpine.tag, "latest")
        XCTAssertEqual(alpine.digest, "sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a")
        // Attestation manifests ("unknown/unknown") are not platforms.
        XCTAssertEqual(alpine.platforms, ["linux/amd64", "linux/arm64/v8"])
        // The arm64 variant size, like `image ls -v` FULL SIZE. Not the sum of all variants.
        XCTAssertEqual(alpine.sizeBytes, 4_192_140)
        XCTAssertEqual(alpine.createdAt, Date(timeIntervalSince1970: 1_792_622_055))

        let amd = try ContainerOutputParser.images(RealCLIImageFixtures.imageList, preferredArchitecture: "amd64")
        XCTAssertEqual(amd[0].sizeBytes, 3_854_742)

        // Built with `container build`: arm64 without a variant.
        let built = images[1]
        XCTAssertEqual(built.shortName, "deck-test-build")
        XCTAssertEqual(built.tag, "v1")
        XCTAssertEqual(built.platforms, ["linux/arm64"])
        XCTAssertEqual(built.sizeBytes, 4_192_446)
        XCTAssertNotNil(built.createdAt)
    }

    func testRealImageInspect() throws {
        let detail = try ContainerOutputParser.imageDetail(RealCLIImageFixtures.imageInspect, preferredArchitecture: "arm64")
        XCTAssertEqual(detail.summary.reference, "docker.io/library/alpine:latest")
        XCTAssertEqual(detail.summary.sizeBytes, 4_192_140)
        XCTAssertEqual(detail.layers.count, 1)
        XCTAssertEqual(detail.layers.first?.digest, "sha256:a278e6f39431cd0ed74238a3d377893ad0d905d68b676bf9a65529080669756b")
        XCTAssertEqual(detail.layers.first?.createdBy, "ADD alpine-minirootfs-3.24.3-aarch64.tar.gz / # buildkit")
        // `image inspect` has no per layer sizes.
        XCTAssertEqual(detail.layers.first?.sizeBytes, 0)
        XCTAssertEqual(detail.config.cmd, ["/bin/sh"])
        XCTAssertEqual(detail.config.entrypoint, [])
        XCTAssertEqual(detail.config.workingDir, "/")
        XCTAssertEqual(detail.config.env.first?.key, "PATH")
        // Apple's OCI config type drops ExposedPorts.
        XCTAssertEqual(detail.config.exposedPorts, [])
        XCTAssertTrue(detail.rawJSON.contains("\"variants\""))

        let amd = try ContainerOutputParser.imageDetail(RealCLIImageFixtures.imageInspect, preferredArchitecture: "amd64")
        XCTAssertEqual(amd.layers.first?.createdBy, "ADD alpine-minirootfs-3.24.3-x86_64.tar.gz / # buildkit")
    }

    // MARK: pull progress

    private var pullLines: [String] {
        RealCLIImageFixtures.pullOutput.split(separator: "\n").map(String.init)
    }

    func testEveryRealPullLineParses() {
        XCTAssertEqual(pullLines.count, 37)
        for line in pullLines {
            XCTAssertNotNil(PullProgress.parse(line), line)
        }
    }

    func testPullProgressFields() throws {
        let first = try XCTUnwrap(PullProgress.parse("[1/2] Fetching image [0s]"))
        XCTAssertEqual(first, PullProgress(step: 1, totalSteps: 2, title: "Fetching image", elapsedSeconds: 0))
        XCTAssertNil(first.fraction)

        let blobs = try XCTUnwrap(PullProgress.parse("[1/2] Fetching image (4 of 18 blobs) [4s]"))
        XCTAssertNil(blobs.percent)
        XCTAssertEqual(blobs.detail, "4 of 18 blobs")

        let fetching = try XCTUnwrap(PullProgress.parse("[1/2] Fetching image 12% (20 of 52 blobs, 2.1/16.7 MB, 2 KB/s) [9s]"))
        XCTAssertEqual(fetching.title, "Fetching image")
        XCTAssertEqual(fetching.percent, 12)
        XCTAssertEqual(fetching.detail, "20 of 52 blobs, 2.1/16.7 MB, 2 KB/s")
        XCTAssertEqual(fetching.elapsedSeconds, 9)
        XCTAssertEqual(fetching.fraction ?? -1, 0.06, accuracy: 0.0001)

        let unpack = try XCTUnwrap(PullProgress.parse("[2/2] Unpacking image for platform linux/s390x 100% (448 entries, 4.0 MB) [27s]"))
        XCTAssertEqual(unpack.title, "Unpacking image for platform linux/s390x")
        XCTAssertEqual(unpack.fraction, 1)

        let colored = PullProgress.parse("\u{1B}[2K\u{1B}[1G[1/2] Fetching image 50% [3s]")
        XCTAssertEqual(colored?.percent, 50)
    }

    func testNonProgressLinesAreIgnored() {
        XCTAssertNil(PullProgress.parse("Error: image not found: does-not-exist:1"))
        XCTAssertNil(PullProgress.parse("#2 [internal] load build definition from Dockerfile"))
        XCTAssertNil(PullProgress.parse("[internal] load .dockerignore"))
        XCTAssertNil(PullProgress.parse("[1/2]"))
        XCTAssertNil(PullProgress.parse(""))
    }

    func testRealPullCollapsesToOneLinePerStep() {
        var collapsed: [String] = []
        for line in pullLines {
            if let last = collapsed.last, PullProgress.isSameStep(last, line) {
                collapsed[collapsed.count - 1] = line
            } else {
                collapsed.append(line)
            }
        }
        XCTAssertEqual(collapsed.count, 11)
        XCTAssertEqual(collapsed.first, "[1/2] Fetching image 99% (50 of 52 blobs, 16.7/16.7 MB, 1.3 MB/s) [25s]")
        XCTAssertEqual(collapsed.last, "[2/2] Unpacking image for platform linux/s390x 100% (448 entries, 4.0 MB) [27s]")
    }

    func testLineBufferSplitsRealPullInChunks() {
        let data = Data(RealCLIImageFixtures.pullOutput.utf8)
        let buffer = LineBuffer()
        var lines: [String] = []
        var index = 0
        while index < data.count {
            let end = min(index + 17, data.count)
            lines += buffer.append(data.subdata(in: index..<end))
            index = end
        }
        lines += buffer.flush()
        XCTAssertEqual(lines, pullLines)
    }

    func testPullArgumentsForThisMac() {
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner())
        XCTAssertEqual(ImagePlatform.host, "linux/" + ContainerClient.hostArchitecture)
        XCTAssertEqual(
            client.pullArguments("alpine:latest", platform: ImagePlatform.host),
            ["image", "pull", "--platform", ImagePlatform.host, "alpine:latest"]
        )
    }

    // MARK: failures

    func testRealFailureMessages() {
        let pull = RealCLIImageFixtures.pullFailure.split(separator: "\n").map(String.init)
        XCTAssertEqual(
            CLIFailure.message(in: pull),
            "HTTP request to https://registry-1.docker.io/v2/library/nosuchimage-deck-zz/manifests/latest failed with response: 401 Unauthorized. Reason: Unknown, no credentials found for host registry-1.docker.io"
        )

        let build = RealCLIImageFixtures.buildFailure.split(separator: "\n").map(String.init)
        XCTAssertTrue(CLIFailure.message(in: build)?.hasPrefix("unknown: \"failed to solve: process") ?? false)

        // Help text follows the error, so the last line is not the message.
        let usage = RealCLIImageFixtures.buildUsageFailure.split(separator: "\n").map(String.init)
        XCTAssertEqual(CLIFailure.message(in: usage), "file does not exist /tmp/nonexist/Dockerfile")

        let success = RealCLIImageFixtures.buildOutput.split(separator: "\n").map(String.init)
        XCTAssertNil(CLIFailure.message(in: success))
        XCTAssertEqual(success.last, "docker.io/library/deck-test-build:v1")
    }

    // MARK: build

    func testBuildArgumentsMatchRecordedRun() {
        let client = ContainerClient(cliPath: "/usr/local/bin/container", runner: MockRunner())
        let options = BuildOptions(
            contextDir: "/tmp/deck-img-build",
            dockerfile: "/tmp/deck-img-build/Dockerfile",
            tags: ["deck-test-build:v1"],
            buildArgs: [EnvVar(key: "GREETING", value: "hello")],
            platform: "linux/arm64",
            target: "final"
        )
        // Every flag here is accepted by `container build` 1.6.1.
        XCTAssertEqual(client.buildArguments(options), [
            "build", "--progress", "plain", "--file", "/tmp/deck-img-build/Dockerfile",
            "--tag", "deck-test-build:v1", "--build-arg", "GREETING=hello",
            "--platform", "linux/arm64", "--target", "final", "/tmp/deck-img-build"
        ])
    }

    // MARK: Docker Hub

    func testRealHubSearch() throws {
        let page = try DockerHubClient.parseSearch(Data(RealCLIImageFixtures.hubSearch.utf8), page: 1)
        XCTAssertEqual(page.items.map(\.fullName), ["nginx", "nginx/nginx-ingress"])
        XCTAssertEqual(page.items.map(\.isOfficial), [true, false])
        XCTAssertEqual(page.items[0].description, "Official build of Nginx.")
        XCTAssertEqual(page.items[0].starCount, 21417)
        XCTAssertEqual(page.items[0].pullCount, 13_555_094_009)
        XCTAssertEqual(page.nextPage, 2)

        let empty = try DockerHubClient.parseSearch(Data(RealCLIImageFixtures.hubSearchEmpty.utf8), page: 1)
        XCTAssertEqual(empty.items, [])
        XCTAssertNil(empty.nextPage)
    }

    func testRealHubOfficialList() throws {
        let page = try DockerHubClient.parseSearch(Data(RealCLIImageFixtures.hubOfficial.utf8), page: 1)
        XCTAssertEqual(page.items.map(\.fullName), ["nginx", "memcached"])
        XCTAssertTrue(page.items.allSatisfy(\.isOfficial))
        XCTAssertEqual(page.items[0].description, "Official build of Nginx.")
        XCTAssertGreaterThan(page.items[0].pullCount, page.items[1].pullCount)
        XCTAssertEqual(page.nextPage, 2)
    }

    func testOfficialListAsksForMostPulledFirst() {
        // Docker Hub sorts backwards here: "-pull_count" gives the least pulled first.
        let url = DockerHubClient.searchURL("", page: 1).absoluteString
        XCTAssertTrue(url.contains("ordering=pull_count"), url)
        XCTAssertFalse(url.contains("-pull_count"), url)
    }

    func testRealHubTags() throws {
        let page = try DockerHubClient.parseTags(Data(RealCLIImageFixtures.hubTags.utf8), page: 1)
        XCTAssertEqual(page.items.map(\.name), ["13.2.5-distroless-slim"])
        let tag = page.items[0]
        XCTAssertEqual(tag.sizeBytes, 306_199_628)
        XCTAssertEqual(tag.platforms, ["linux/amd64", "linux/arm64", "linux/arm/v7"])
        XCTAssertNotNil(tag.lastUpdated)
        XCTAssertEqual(page.nextPage, 2)
    }
}
