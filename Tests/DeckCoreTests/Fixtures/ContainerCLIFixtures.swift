import Foundation

/// Recorded `container ... --format json` output, built from the Codable types
/// in apple/container (ManagedContainer, ImageResource, VolumeResource,
/// NetworkResource, StatsReport, DiskUsageStats, ContainerSystemConfig).
enum ContainerCLIFixtures {

    /// `container list --all --format json` (current main: ManagedContainer, sorted keys, ISO 8601 dates).
    static let containerList = #"""
    [{"configuration":{"capAdd":[],"capDrop":[],"creationDate":"2026-10-30T09:12:44Z","dns":{"domain":"test","nameservers":["192.168.64.1"],"options":[],"searchDomains":[]},"id":"web","image":{"descriptor":{"digest":"sha256:1111","mediaType":"application/vnd.oci.image.index.v1+json","size":10229},"reference":"docker.io/library/nginx:latest"},"initProcess":{"arguments":["-g","daemon off;"],"environment":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","NGINX_VERSION=1.27.2","EMPTY="],"executable":"nginx","rlimits":[],"supplementalGroups":[],"terminal":false,"user":{"id":{"gid":0,"uid":0}},"workingDirectory":"/srv"},"labels":{"com.example.team":"web"},"mounts":[{"destination":"/usr/share/nginx/html","options":["ro"],"source":"/Users/me/site","type":{"virtiofs":{}}},{"destination":"/data","options":[],"source":"/Users/me/Library/Application Support/com.apple.container/volumes/webdata/volume.img","type":{"volume":{"cache":{"on":{}},"format":"ext4","name":"webdata","sync":{"fsync":{}}}}}],"networks":[{"network":"default","options":{"hostname":"web"}}],"platform":{"architecture":"arm64","os":"linux"},"publishedPorts":[{"containerPort":80,"count":1,"hostAddress":"0.0.0.0","hostPort":8080,"proto":"tcp"},{"containerPort":53,"count":2,"hostAddress":"127.0.0.1","hostPort":5353,"proto":"udp"}],"publishedSockets":[],"readOnly":false,"resources":{"cpuOverhead":1,"cpus":2,"memoryInBytes":1073741824},"rosetta":false,"runtimeHandler":"container-runtime-linux","ssh":false,"sysctls":{},"useInit":false,"virtualization":false},"id":"web","status":{"networks":[{"hostname":"web.test.","ipv4Address":"192.168.64.3/24","ipv4Gateway":"192.168.64.1","macAddress":"02:42:ac:11:00:02","network":"default"}],"startedDate":"2026-10-30T09:12:46.512Z","state":"running"}},{"configuration":{"creationDate":"2026-10-30T09:12:44Z","id":"db","image":{"descriptor":{"digest":"sha256:2222","mediaType":"application/vnd.oci.image.index.v1+json","size":9000},"reference":"docker.io/library/postgres:17"},"initProcess":{"arguments":[],"environment":["POSTGRES_PASSWORD=secret"],"executable":"docker-entrypoint.sh","terminal":false,"user":{"raw":{"userString":"postgres"}},"workingDirectory":"/"},"labels":{},"mounts":[],"networks":[{"network":"backend","options":{"hostname":"db"}}],"platform":{"architecture":"amd64","os":"linux"},"publishedPorts":[],"readOnly":true,"resources":{"cpus":4,"memoryInBytes":2147483648},"rosetta":true},"id":"db","status":{"networks":[],"state":"stopped"}}]
    """#

    /// 1.x shape (ContainerSnapshot): status is a string, networks sit beside it,
    /// old attachment keys and numeric dates from Swift's default encoder.
    static let containerListLegacy = #"""
    [{"configuration":{"creationDate":783420000,"id":"old","image":{"descriptor":{"digest":"sha256:3333","mediaType":"application/vnd.oci.image.index.v1+json","size":1},"reference":"docker.io/library/alpine:3.20"},"initProcess":{"arguments":["sleep","infinity"],"environment":[],"executable":"/bin/sh","terminal":false,"user":{"id":{"gid":0,"uid":0}},"workingDirectory":"/"},"labels":{},"mounts":[],"networks":["default"],"platform":{"architecture":"arm64","os":"linux"},"publishedPorts":[],"resources":{"cpus":4,"memoryInBytes":1073741824},"rosetta":false,"someNewField":{"x":1}},"networks":[{"address":"192.168.64.5/24","gateway":"192.168.64.1","hostname":"old.","network":"default"}],"startedDate":783420010.5,"status":"running"}, {"broken": true}]
    """#

    /// `container inspect web` (pretty printed, same type as the list).
    static let containerInspect = """
    [
      {
        "configuration" : {
          "creationDate" : "2026-10-30T09:12:44Z",
          "id" : "web",
          "image" : { "descriptor" : { "digest" : "sha256:1111", "mediaType" : "application/vnd.oci.image.index.v1+json", "size" : 10229 }, "reference" : "docker.io/library/nginx:latest" },
          "initProcess" : {
            "arguments" : [ "-g", "daemon off;" ],
            "environment" : [ "PATH=/usr/bin", "GREETING=a=b" ],
            "executable" : "nginx",
            "terminal" : false,
            "user" : { "id" : { "gid" : 101, "uid" : 101 } },
            "workingDirectory" : "/srv"
          },
          "labels" : { },
          "mounts" : [
            { "destination" : "/usr/share/nginx/html", "options" : [ "ro" ], "source" : "/Users/me/site", "type" : { "virtiofs" : { } } },
            { "destination" : "/data", "options" : [ ], "source" : "/vol/webdata/volume.img", "type" : { "volume" : { "cache" : { "on" : { } }, "format" : "ext4", "name" : "webdata", "sync" : { "fsync" : { } } } } },
            { "destination" : "/tmp", "options" : [ ], "source" : "tmpfs", "type" : { "tmpfs" : { } } }
          ],
          "networks" : [ { "network" : "default", "options" : { "hostname" : "web" } } ],
          "platform" : { "architecture" : "arm64", "os" : "linux" },
          "publishedPorts" : [ ],
          "readOnly" : true,
          "resources" : { "cpus" : 2, "memoryInBytes" : 1073741824 },
          "rosetta" : false
        },
        "id" : "web",
        "status" : {
          "networks" : [ { "hostname" : "web.test.", "ipv4Address" : "192.168.64.3/24", "ipv4Gateway" : "192.168.64.1", "macAddress" : "02:42:ac:11:00:02", "network" : "default" } ],
          "startedDate" : "2026-10-30T09:12:46Z",
          "state" : "running"
        }
      }
    ]
    """

    /// `container stats --no-stream --format json` on current main (StatsReport).
    static let statsWithUtilization = """
    [{"blockReadBytes":4096,"blockWriteBytes":8192,"cpuUsageUsec":1234567,"cpuUtilization":0.25,"id":"web","memoryLimitBytes":1073741824,"memoryUsageBytes":52428800,"networkRxBytes":1000,"networkTxBytes":2000,"numProcesses":5}]
    """

    /// 1.x: one sample, cumulative CPU only.
    static func statsCumulative(usec: UInt64) -> String {
        """
        [{"blockReadBytes":0,"blockWriteBytes":0,"cpuUsageUsec":\(usec),"id":"web","memoryLimitBytes":1073741824,"memoryUsageBytes":1048576,"networkRxBytes":10,"networkTxBytes":20,"numProcesses":2}]
        """
    }

    /// `container image list --format json` (ImageResource).
    static let imageList = #"""
    [{"configuration":{"creationDate":"2025-10-08T18:22:15Z","descriptor":{"annotations":{"org.opencontainers.image.ref.name":"latest"},"digest":"sha256:index1","mediaType":"application/vnd.oci.image.index.v1+json","size":10229},"name":"docker.io/library/nginx:latest"},"id":"index1","variants":[{"config":{"architecture":"arm64","config":{"Cmd":["nginx","-g","daemon off;"],"Entrypoint":["/docker-entrypoint.sh"],"Env":["PATH=/usr/local/sbin:/usr/bin","NGINX_VERSION=1.27.2"],"Labels":{"maintainer":"NGINX Docker Maintainers"},"StopSignal":"SIGQUIT","User":"","WorkingDir":""},"created":"2025-10-08T18:22:15Z","history":[{"created":"2025-10-01T00:00:00Z","created_by":"/bin/sh -c #(nop) ADD file:abc in / "},{"created":"2025-10-01T00:00:01Z","created_by":"/bin/sh -c #(nop)  CMD [\"bash\"]","empty_layer":true},{"comment":"buildkit.dockerfile.v0","created":"2025-10-08T18:22:15Z","created_by":"RUN /bin/sh -c apt-get update # buildkit"},{"comment":"buildkit.dockerfile.v0","created_by":"EXPOSE map[80/tcp:{}]","empty_layer":true}],"os":"linux","rootfs":{"diff_ids":["sha256:layer1","sha256:layer2"],"type":"layers"},"variant":"v8"},"digest":"sha256:arm","platform":{"architecture":"arm64","os":"linux","variant":"v8"},"size":72000000},{"config":{"architecture":"amd64","config":{"Cmd":["nginx"]},"created":"2025-10-08T18:22:15Z","os":"linux","rootfs":{"diff_ids":["sha256:amd1"],"type":"layers"}},"digest":"sha256:amd","platform":{"architecture":"amd64","os":"linux"},"size":70000000},{"config":{"architecture":"unknown","os":"unknown","rootfs":{"diff_ids":[],"type":"layers"}},"digest":"sha256:att","platform":{"architecture":"unknown","os":"unknown"},"size":800}]},{"configuration":{"creationDate":"1970-01-01T00:00:00Z","descriptor":{"digest":"sha256:index2","mediaType":"application/vnd.oci.image.manifest.v1+json","size":500},"name":"localhost/my-app:dev"},"id":"index2","variants":[]}]
    """#

    /// `container volume list --format json` (VolumeResource), plus a 1.0 flat item.
    static let volumeList = """
    [{"configuration":{"creationDate":"2026-10-01T10:00:00Z","driver":"local","format":"ext4","labels":{},"name":"webdata","options":{},"sizeInBytes":549755813888,"source":"/Users/me/Library/Application Support/com.apple.container/volumes/webdata/volume.img"},"id":"webdata"},{"configuration":{"creationDate":"2026-10-01T10:00:00Z","driver":"local","format":"ext4","labels":{"com.apple.container.resource.anonymous":""},"name":"3f1c2a","options":{"size":"10G"},"source":"/vol/3f1c2a/volume.img"},"id":"3f1c2a"},{"createdAt":783420000,"driver":"local","format":"ext4","labels":{"team":"data"},"name":"legacy","options":{},"source":"/vol/legacy/volume.img"}]
    """

    /// `container network list --format json` (NetworkResource).
    static let networkList = """
    [{"configuration":{"creationDate":"2026-10-01T10:00:00Z","ipv4Subnet":"192.168.64.0/24","labels":{"com.apple.container.resource.role":"builtin"},"mode":"nat","name":"default","options":{},"plugin":"container-network-vmnet"},"id":"default","status":{"ipv4Gateway":"192.168.64.1","ipv4Subnet":"192.168.64.0/24"}},{"configuration":{"creationDate":"2026-10-02T10:00:00Z","labels":{},"mode":"hostOnly","name":"backend","options":{},"plugin":"container-network-vmnet"},"id":"backend","status":{"ipv4Gateway":"192.168.65.1","ipv4Subnet":"192.168.65.0/24","ipv6Subnet":"fd00:1::/64"}}]
    """

    /// Pre 1.0 network list (NetworkState with config and a state string).
    static let networkListLegacy = """
    [{"config":{"id":"default","mode":"nat","subnet":"192.168.64.0/24"},"id":"default","state":"running","status":{"address":"192.168.64.0/24","gateway":"192.168.64.1"}}]
    """

    /// `container system df --format json` (DiskUsageStats, pretty).
    static let diskUsage = """
    {
      "containers" : { "active" : 1, "reclaimable" : 0, "sizeInBytes" : 1000, "total" : 2 },
      "images" : { "active" : 2, "reclaimable" : 3000, "sizeInBytes" : 9000, "total" : 3 },
      "volumes" : { "active" : 1, "reclaimable" : 500, "sizeInBytes" : 700, "total" : 2 }
    }
    """

    /// `container system property list --format json` (ContainerSystemConfig).
    static let systemProperties = """
    {"build":{"cpus":2,"image":"ghcr.io/apple/container-builder-shim/builder:0.13.1","memory":"2048mb","rosetta":true},"container":{"cpus":4,"dns":{"nameservers":["1.1.1.1"]},"memory":"1gb"},"dns":{"domain":"test"},"kernel":{"binaryPath":"opt/kata/vmlinux","digest":"sha256:abc","url":"https://example.com/kernel.tar.zst"},"network":{},"registry":{"domain":"docker.io"},"vminit":{"image":"ghcr.io/apple/containerization/vminit:0.34.0"}}
    """

    /// Pre 1.0 property list.
    static let systemPropertiesLegacy = """
    [{"id":"build.rosetta","type":"Bool","value":true,"description":"Use Rosetta."},{"id":"dns.domain","type":"String","value":null,"description":""}]
    """

    /// `container registry list --format json` (RegistryResource).
    static let registryList = """
    [{"creationDate":"2026-10-01T10:00:00Z","id":"docker.io","labels":{},"modificationDate":"2026-10-01T10:00:00Z","name":"docker.io","username":"me"},{"creationDate":"2026-10-01T10:00:00Z","id":"ghcr.io","labels":{},"modificationDate":"2026-10-01T10:00:00Z","name":"ghcr.io","username":"me"}]
    """

    static let registryTable = """
    HOSTNAME   USERNAME  MODIFIED              CREATED
    docker.io  me        2026-10-01T10:00:00Z  2026-10-01T10:00:00Z
    """

    /// Output of the listFiles script with `stat` (GNU or busybox).
    static let statListing = """
    directory|4096|1730000000|drwxr-xr-x|etc
    regular file|12|1730000100|-rw-r--r--|hello|world.txt
    regular empty file|0|1730000200|-rw-------|.hidden
    symbolic link|7|1730000300|lrwxrwxrwx|bin
    symbolic link|11|1730000300|lrwxrwxrwx|motd
    LDIR|bin
    """

    /// Output of the listFiles script when `stat` is missing.
    static let lsListing = """
    __DECK_LS__
    total 12
    drwxr-xr-x    1 root     root          4096 Oct 30 09:12 .
    drwxr-xr-x    1 root     root          4096 Oct 30 09:12 ..
    drwxr-xr-x    2 root     root          4096 Oct 30 09:12 conf d
    -rw-r--r--    1 root     root           321 Oct 30 09:12 index.html
    lrwxrwxrwx    1 root     root            11 Oct 30 09:12 log -> /var/log/app
    """
}
