import Foundation

// Output recorded from Apple's `container` CLI 1.6.1 (build release, commit aa8d76b)
// on macOS 27.2, Apple silicon. Home folder paths were shortened to /Users/me.
// Commands that made them:
//
//   container volume create deck-test-ctr-vol
//   container run --detach --name deck-test-ctr-web --env FOO=bar --env "SPACED=a b" \
//     --publish 18080:80 --volume /tmp/deck-ctr-share:/share:ro --volume deck-test-ctr-vol:/data \
//     --cpus 2 --memory 512M --label deck.test=1 --label app=web --workdir /usr/share/nginx nginx:alpine
//   container run --detach --name deck-test-ctr-b --entrypoint sleep --rm nginx:alpine 3600
//   container run --detach --name deck-test-ctr-c --publish 127.0.0.1:18081:80/tcp --publish 18082:53/udp \
//     --mount "type=bind,source=/tmp/deck-ctr-share/with space,target=/sp,readonly" --network default \
//     --label deck.test=1 nginx:alpine
//   container stop deck-test-ctr-c

enum RealCLIFixtures {
    /// `container list --all --format json` (one line, as printed). web and b running, c stopped.
    static let containerList = #"""
[{"configuration":{"capAdd":[],"capDrop":[],"creationDate":"2026-11-05T12:25:30Z","dns":{"nameservers":[],"options":[],"searchDomains":[]},"id":"deck-test-ctr-b","image":{"descriptor":{"digest":"sha256:785835ea65db4bba6f021acc0f3be91b0fef76a53fe41f8588c6698d2aed0606","mediaType":"application/vnd.oci.image.index.v1+json","size":10333},"reference":"docker.io/library/nginx:alpine"},"initProcess":{"arguments":["3600"],"environment":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","NJS_VERSION=1.0.2","ACME_VERSION=0.4.1","NGINX_VERSION=1.31.8","PKG_RELEASE=1","DYNPKG_RELEASE=1","NJS_RELEASE=1"],"executable":"sleep","rlimits":[],"supplementalGroups":[],"terminal":false,"user":{"id":{"gid":0,"uid":0}},"workingDirectory":"/"},"labels":{},"mounts":[],"networks":[{"network":"default","options":{"hostname":"deck-test-ctr-b","mtu":1280}}],"platform":{"architecture":"arm64","os":"linux","variant":"v8"},"publishedPorts":[],"publishedSockets":[],"readOnly":false,"resources":{"cpuOverhead":1,"cpus":4,"memoryInBytes":1073741824},"rosetta":false,"runtimeHandler":"container-runtime-linux","ssh":false,"stopSignal":"SIGQUIT","sysctls":{},"useInit":false,"virtualization":false},"id":"deck-test-ctr-b","status":{"networks":[{"hostname":"deck-test-ctr-b","ipv4Address":"192.168.64.6/24","ipv4Gateway":"192.168.64.1","ipv6Address":"fd3a:ea47:104a:c220:fc01:6bff:fe0d:a710/64","macAddress":"fe:01:6b:0d:a7:10","mtu":1280,"network":"default","variant":"reserved"}],"startedDate":"2026-11-05T12:25:30Z","state":"running"}},{"configuration":{"capAdd":[],"capDrop":[],"creationDate":"2026-11-05T12:24:53Z","dns":{"nameservers":[],"options":[],"searchDomains":[]},"id":"deck-test-ctr-web","image":{"descriptor":{"digest":"sha256:785835ea65db4bba6f021acc0f3be91b0fef76a53fe41f8588c6698d2aed0606","mediaType":"application/vnd.oci.image.index.v1+json","size":10333},"reference":"docker.io/library/nginx:alpine"},"initProcess":{"arguments":["nginx","-g","daemon off;"],"environment":["FOO=bar","NJS_VERSION=1.0.2","DYNPKG_RELEASE=1","NGINX_VERSION=1.31.8","PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","NJS_RELEASE=1","PKG_RELEASE=1","SPACED=a b","ACME_VERSION=0.4.1"],"executable":"/docker-entrypoint.sh","rlimits":[],"supplementalGroups":[],"terminal":false,"user":{"id":{"gid":0,"uid":0}},"workingDirectory":"/usr/share/nginx"},"labels":{"app":"web","deck.test":"1"},"mounts":[{"destination":"/share","options":["ro"],"source":"/tmp/deck-ctr-share","type":{"virtiofs":{}}},{"destination":"/data","options":[],"source":"/Users/me/Library/Application Support/com.apple.container/volumes/deck-test-ctr-vol/volume.img","type":{"volume":{"cache":{"on":{}},"format":"ext4","name":"deck-test-ctr-vol","sync":{"fsync":{}}}}}],"networks":[{"network":"default","options":{"hostname":"deck-test-ctr-web","mtu":1280}}],"platform":{"architecture":"arm64","os":"linux","variant":"v8"},"publishedPorts":[{"containerPort":80,"count":1,"hostAddress":"0.0.0.0","hostPort":18080,"proto":"tcp"}],"publishedSockets":[],"readOnly":false,"resources":{"cpuOverhead":1,"cpus":2,"memoryInBytes":536870912},"rosetta":false,"runtimeHandler":"container-runtime-linux","ssh":false,"stopSignal":"SIGQUIT","sysctls":{},"useInit":false,"virtualization":false},"id":"deck-test-ctr-web","status":{"networks":[{"hostname":"deck-test-ctr-web","ipv4Address":"192.168.64.2/24","ipv4Gateway":"192.168.64.1","ipv6Address":"fd3a:ea47:104a:c220:f894:9aff:fe86:7dbb/64","macAddress":"fa:94:9a:86:7d:bb","mtu":1280,"network":"default","variant":"reserved"}],"startedDate":"2026-11-05T12:24:54Z","state":"running"}},{"configuration":{"capAdd":[],"capDrop":[],"creationDate":"2026-11-05T12:25:48Z","dns":{"nameservers":[],"options":[],"searchDomains":[]},"id":"deck-test-ctr-c","image":{"descriptor":{"digest":"sha256:785835ea65db4bba6f021acc0f3be91b0fef76a53fe41f8588c6698d2aed0606","mediaType":"application/vnd.oci.image.index.v1+json","size":10333},"reference":"docker.io/library/nginx:alpine"},"initProcess":{"arguments":["nginx","-g","daemon off;"],"environment":["NJS_VERSION=1.0.2","ACME_VERSION=0.4.1","PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","DYNPKG_RELEASE=1","PKG_RELEASE=1","NGINX_VERSION=1.31.8","NJS_RELEASE=1"],"executable":"/docker-entrypoint.sh","rlimits":[],"supplementalGroups":[],"terminal":false,"user":{"id":{"gid":0,"uid":0}},"workingDirectory":"/"},"labels":{"deck.test":"1"},"mounts":[{"destination":"/sp","options":["ro"],"source":"/tmp/deck-ctr-share/with space","type":{"virtiofs":{}}}],"networks":[{"network":"default","options":{"hostname":"deck-test-ctr-c","mtu":1280}}],"platform":{"architecture":"arm64","os":"linux","variant":"v8"},"publishedPorts":[{"containerPort":80,"count":1,"hostAddress":"127.0.0.1","hostPort":18081,"proto":"tcp"},{"containerPort":53,"count":1,"hostAddress":"0.0.0.0","hostPort":18082,"proto":"udp"}],"publishedSockets":[],"readOnly":false,"resources":{"cpuOverhead":1,"cpus":4,"memoryInBytes":1073741824},"rosetta":false,"runtimeHandler":"container-runtime-linux","ssh":false,"stopSignal":"SIGQUIT","sysctls":{},"useInit":false,"virtualization":false},"id":"deck-test-ctr-c","status":{"networks":[],"startedDate":"2026-11-05T12:25:49Z","state":"stopped"}}]
"""#

    /// `container inspect deck-test-ctr-c` after `container stop` (pretty printed, as printed).
    static let stoppedInspect = #"""
[
  {
    "configuration" : {
      "capAdd" : [

      ],
      "capDrop" : [

      ],
      "creationDate" : "2026-11-05T12:25:48Z",
      "dns" : {
        "nameservers" : [

        ],
        "options" : [

        ],
        "searchDomains" : [

        ]
      },
      "id" : "deck-test-ctr-c",
      "image" : {
        "descriptor" : {
          "digest" : "sha256:785835ea65db4bba6f021acc0f3be91b0fef76a53fe41f8588c6698d2aed0606",
          "mediaType" : "application/vnd.oci.image.index.v1+json",
          "size" : 10333
        },
        "reference" : "docker.io/library/nginx:alpine"
      },
      "initProcess" : {
        "arguments" : [
          "nginx",
          "-g",
          "daemon off;"
        ],
        "environment" : [
          "NJS_VERSION=1.0.2",
          "ACME_VERSION=0.4.1",
          "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
          "DYNPKG_RELEASE=1",
          "PKG_RELEASE=1",
          "NGINX_VERSION=1.31.8",
          "NJS_RELEASE=1"
        ],
        "executable" : "/docker-entrypoint.sh",
        "rlimits" : [

        ],
        "supplementalGroups" : [

        ],
        "terminal" : false,
        "user" : {
          "id" : {
            "gid" : 0,
            "uid" : 0
          }
        },
        "workingDirectory" : "/"
      },
      "labels" : {
        "deck.test" : "1"
      },
      "mounts" : [
        {
          "destination" : "/sp",
          "options" : [
            "ro"
          ],
          "source" : "/tmp/deck-ctr-share/with space",
          "type" : {
            "virtiofs" : {

            }
          }
        }
      ],
      "networks" : [
        {
          "network" : "default",
          "options" : {
            "hostname" : "deck-test-ctr-c",
            "mtu" : 1280
          }
        }
      ],
      "platform" : {
        "architecture" : "arm64",
        "os" : "linux",
        "variant" : "v8"
      },
      "publishedPorts" : [
        {
          "containerPort" : 80,
          "count" : 1,
          "hostAddress" : "127.0.0.1",
          "hostPort" : 18081,
          "proto" : "tcp"
        },
        {
          "containerPort" : 53,
          "count" : 1,
          "hostAddress" : "0.0.0.0",
          "hostPort" : 18082,
          "proto" : "udp"
        }
      ],
      "publishedSockets" : [

      ],
      "readOnly" : false,
      "resources" : {
        "cpuOverhead" : 1,
        "cpus" : 4,
        "memoryInBytes" : 1073741824
      },
      "rosetta" : false,
      "runtimeHandler" : "container-runtime-linux",
      "ssh" : false,
      "stopSignal" : "SIGQUIT",
      "sysctls" : {

      },
      "useInit" : false,
      "virtualization" : false
    },
    "id" : "deck-test-ctr-c",
    "status" : {
      "networks" : [

      ],
      "startedDate" : "2026-11-05T12:25:49Z",
      "state" : "stopped"
    }
  }
]
"""#

    /// `container stats --no-stream --format json` with two running containers. No cpuUtilization in 1.6.1.
    static let stats = #"""
[{"blockReadBytes":1810432,"blockWriteBytes":0,"cpuUsageUsec":8312,"id":"deck-test-m-5fe835","memoryLimitBytes":1073741824,"memoryUsageBytes":3145728,"networkRxBytes":6456,"networkTxBytes":602,"numProcesses":7},{"blockReadBytes":10609664,"blockWriteBytes":12288,"cpuUsageUsec":13587,"id":"deck-test-ctr-web","memoryLimitBytes":536870912,"memoryUsageBytes":15032320,"networkRxBytes":22099,"networkTxBytes":602,"numProcesses":4}]
"""#

    /// `listFilesScript` run with `container exec deck-test-ctr-web sh -c <script> sh /` (busybox stat).
    static let filesRoot = #"""
directory|4096|1792619742|drwxr-xr-x|bin
directory|4096|1793881471|drwxr-xr-x|data
directory|2780|1793881494|drwxr-xr-x|dev
directory|4096|1792624380|drwxr-xr-x|docker-entrypoint.d
regular file|1620|1792624377|-rwxr-xr-x|docker-entrypoint.sh
directory|4096|1793881494|drwxr-xr-x|etc
directory|4096|1792619742|drwxr-xr-x|home
directory|4096|1792619742|drwxr-xr-x|lib
directory|4096|1793881482|drwx------|lost+found
directory|4096|1792619742|drwxr-xr-x|media
directory|4096|1792619742|drwxr-xr-x|mnt
directory|4096|1792619742|drwxr-xr-x|opt
directory|0|1793881494|dr-xr-xr-x|proc
directory|4096|1792619742|drwx------|root
directory|4096|1793881494|drwxr-xr-x|run
directory|4096|1792619742|drwxr-xr-x|sbin
directory|96|1793881471|drwxr-xr-x|share
directory|4096|1792619742|drwxr-xr-x|srv
directory|0|1793881494|dr-xr-xr-x|sys
directory|4096|1792619742|drwxrwxrwt|tmp
directory|4096|1792619742|drwxr-xr-x|usr
directory|4096|1792619742|drwxr-xr-x|var
"""#

    /// `listFilesScript` for /etc/nginx. `modules` is a symlink to a folder.
    static let filesNginx = #"""
directory|4096|1793881494|drwxr-xr-x|conf.d
regular file|1077|1792605285|-rw-r--r--|fastcgi.conf
regular file|1007|1792605285|-rw-r--r--|fastcgi_params
regular file|5349|1792605285|-rw-r--r--|mime.types
symbolic link|22|1792624379|lrwxrwxrwx|modules
regular file|644|1792605285|-rw-r--r--|nginx.conf
regular file|636|1792605285|-rw-r--r--|scgi_params
regular file|664|1792605285|-rw-r--r--|uwsgi_params
LDIR|modules
"""#

    /// stdout of `container run --detach ...`. Progress goes to stderr.
    static let runStdout = "deck-test-ctr-b\n"

    /// stderr of `container inspect nonexist` (exit 1).
    static let inspectMissing = "Error: container not found: nonexist\n"

    /// stderr of `container run` when the volume is attached to another running container.
    static let volumeInUse = #"Error: failed to bootstrap container (cause: "internalError: "failed to bootstrap container deck-test-ctr-c (cause: "unknown: "Error Domain=VZErrorDomain Code=2 "The storage device attachment is invalid." UserInfo={NSLocalizedFailure=Invalid virtual machine configuration., NSLocalizedFailureReason=The storage device attachment is invalid.}"")"")"#
}
