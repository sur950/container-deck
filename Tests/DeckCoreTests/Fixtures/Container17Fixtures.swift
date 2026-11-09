import Foundation

/// Output recorded from Apple container 1.7.1 (signed pkg, run side by side with its own
/// --app-root on 9 Nov 2026). Paths under the test app root are rewritten to the default one.
/// The 1.6.1 counterparts are in KubernetesFixtures and ContainerCLIFixtures.
enum Container17Fixtures {
    /// container --version
    static let version = #"""
container CLI version 1.7.1 (build: release, commit: a15b460)
"""#

    /// container cluster list --format json, one running cluster made with --shared-image-store
    static let clusterListJSON = #"""
[{"configuration":{"cni":null,"creationDate":"2026-11-09T10:06:45Z","fqdn":null,"kubernetesVersion":"v1.35.5","labels":{},"name":"deck-17-test-k","nodes":[{"kind":"linux","name":"deck-17-test-k","roles":["control-plane","worker"]}],"remove":false,"sharedImageStore":true},"id":"deck-17-test-k","status":{"nodes":[{"addresses":["192.168.64.3"],"name":"deck-17-test-k","ports":["6445->6443"],"status":"running"}],"state":"running"}}]
"""#

    /// container cluster list --format json, no clusters
    static let clusterListEmptyJSON = #"""
[]
"""#

    /// container cluster list (one row per cluster)
    static let clusterListTable = #"""
NAME            NODES  K8S VERSION  STATE
deck-17-test-k  1      v1.35.5      running
"""#

    /// container cluster list, no clusters
    static let clusterListEmptyTable = #"""
NAME  NODES  K8S VERSION  STATE
"""#

    /// container cluster list --nodes (the node table, memory as "3 GB")
    static let clusterListNodesTable = #"""
CLUSTER         NODE            ROLE                  STATE    CPUS  MEMORY  ADDR          PORTS
deck-17-test-k  deck-17-test-k  control-plane,worker  running  2     3 GB    192.168.64.3  6445->6443
"""#

    /// container list --all --format json while the cluster runs: the node is not listed
    static let listAll = #"""
[{"configuration":{"capAdd":[],"capDrop":[],"creationDate":"2026-11-09T10:06:35Z","dns":{"nameservers":[],"options":[],"searchDomains":[]},"id":"deck-17-test-a","image":{"descriptor":{"digest":"sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf","mediaType":"application/vnd.oci.image.index.v1+json","size":9218},"reference":"docker.io/library/alpine:latest"},"initProcess":{"arguments":["600"],"environment":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"executable":"sleep","rlimits":[],"supplementalGroups":[],"terminal":false,"user":{"id":{"gid":0,"uid":0}},"workingDirectory":"/"},"labels":{},"mounts":[],"networks":[{"network":"default","options":{"hostname":"deck-17-test-a","mtu":1280}}],"platform":{"architecture":"arm64","os":"linux","variant":"v8"},"publishedPorts":[],"publishedSockets":[],"readOnly":false,"resources":{"cpuOverhead":1,"cpus":4,"memoryInBytes":1073741824},"rosetta":false,"runtimeHandler":"container-runtime-linux","ssh":false,"sysctls":{},"useInit":false,"virtualization":false},"id":"deck-17-test-a","status":{"networks":[{"hostname":"deck-17-test-a","ipv4Address":"192.168.64.2/24","ipv4Gateway":"192.168.64.1","ipv6Address":"fd3a:ea47:104a:c220:fca7:1cff:fed7:8b8e/64","macAddress":"fe:a7:1c:d7:8b:8e","mtu":1280,"network":"default","variant":"reserved"}],"startedDate":"2026-11-09T10:06:37Z","state":"running"}}]
"""#

    /// container inspect <node>: still works for cluster nodes
    static let inspectNode = #"""
[
  {
    "configuration" : {
      "capAdd" : [
        "ALL"
      ],
      "capDrop" : [

      ],
      "creationDate" : "2026-11-09T10:06:58Z",
      "dns" : {
        "nameservers" : [

        ],
        "options" : [

        ],
        "searchDomains" : [

        ]
      },
      "id" : "deck-17-test-k",
      "image" : {
        "descriptor" : {
          "digest" : "sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95",
          "mediaType" : "application/vnd.oci.image.index.v1+json",
          "size" : 703
        },
        "reference" : "docker.io/kindest/node@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95"
      },
      "initProcess" : {
        "arguments" : [
          "-c",
          "set -e\nlog_info()  { echo \"INFO: $1\" >&2; }\nlog_error() { echo \"ERROR: $1\" >&2; }\n\n# Disable the createContainer hook that copies /kind/product_* into every\n# container's rootfs. Testing whether container cluster needs this at all --\n# unconfirmed whether container's VMs already assign a unique product_uuid\n# per node without it.\nif [ -f /etc/containerd/cri-base.json ]; then\nif jq 'del(.hooks.createContainer)' /etc/containerd/cri-base.json > /tmp/cri-base.json.new; then\n    mv /tmp/cri-base.json.new /etc/containerd/cri-base.json\n    log_info \"removed createContainer hook from cri-base.json\"\nelse\n    log_error \"jq failed to patch cri-base.json, leaving it unmodified\"\nfi\nfi\n\n# Proxy propagation.\nmkdir -p /etc/systemd/system.conf.d/\ncat <<EOF >/etc/systemd/system.conf.d/proxy-default-environment.conf\n[Manager]\nDefaultEnvironment=\"HTTP_PROXY=${HTTP_PROXY:-}\" \"HTTPS_PROXY=${HTTPS_PROXY:-}\" \"NO_PROXY=${NO_PROXY:-}\"\nEOF\n\n# Mount propagation. Unverified whether this is needed in container's VM boot.\nmount --make-rshared /\n\n# Detect the node's current IPv4 address, preferring the default-route interface.\nDEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i==\"dev\") print $(i+1)}' | head -1)\nif [ -n \"$DEFAULT_IFACE\" ]; then\nCURRENT_IP=$(ip -4 -o addr show dev \"$DEFAULT_IFACE\" | awk '{print $4}' | head -1 | cut -d/ -f1)\nelse\nCURRENT_IP=$(ip -4 -o addr show | awk '$2 != \"lo\" && $2 !~ /^veth/ {print $4}' | head -1 | cut -d/ -f1)\nfi\n# Read the IP recorded on the previous boot, if any.\nIP_MARKER=/etc/.container-cluster-last-ip\nOLD_IP=\"\"\n[ -f \"$IP_MARKER\" ] && OLD_IP=$(cat \"$IP_MARKER\")\n\n# If the node IP changed across a restart, rewrite the old IP in the cluster\n# config files and regenerate the apiserver certificate for the new IP.\nif [ -n \"$OLD_IP\" ] && [ -n \"$CURRENT_IP\" ] && [ \"$OLD_IP\" != \"$CURRENT_IP\" ] && [ -f /etc/kubernetes/pki/apiserver.crt ]; then\nlog_info \"node IP changed ($OLD_IP -> $CURRENT_IP), reconciling cluster config\"\n# Escape dots so OLD_IP matches literally, and anchor on word boundaries so it\n# cannot match inside a longer address.\nOLD_RE=$(printf '%s' \"$OLD_IP\" | sed 's/\\./\\\\./g')\nfor f in /etc/kubernetes/kubeadm-config.yaml \\\n        /etc/kubernetes/manifests/etcd.yaml \\\n        /etc/kubernetes/manifests/kube-apiserver.yaml \\\n        /etc/kubernetes/manifests/kube-controller-manager.yaml \\\n        /etc/kubernetes/manifests/kube-scheduler.yaml \\\n        /etc/kubernetes/controller-manager.conf \\\n        /etc/kubernetes/scheduler.conf \\\n        /etc/kubernetes/kubelet.conf \\\n        /etc/kubernetes/admin.conf \\\n        /root/.kube/config \\\n        /var/lib/kubelet/kubeadm-flags.env; do\n    [ -f \"$f\" ] && sed -i \"s#\\b${OLD_RE}\\b#${CURRENT_IP}#g\" \"$f\"\ndone\n# Regenerate the apiserver certificate so its SANs include the new IP.\nrm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key\nif ! kubeadm init phase certs apiserver --config /etc/kubernetes/kubeadm-config.yaml; then\n    log_error \"apiserver cert regeneration failed after IP change\"\n    exit 1\nfi\nlog_info \"reconciliation complete\"\nfi\n\n# Record the current IP for the next boot, then hand off to the original command.\n[ -n \"$CURRENT_IP\" ] && echo \"$CURRENT_IP\" > \"$IP_MARKER\"\nexec  \"$@\"",
          "sh",
          "/sbin/init"
        ],
        "environment" : [
          "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
          "HTTP_PROXY=",
          "HTTPS_PROXY=",
          "NO_PROXY=192.168.0.0/16,10.244.0.0/16,10.96.0.0/12",
          "no_proxy=192.168.0.0/16,10.244.0.0/16,10.96.0.0/12",
          "container=docker"
        ],
        "executable" : "/bin/sh",
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
        "com.apple.container.plugin" : "cluster",
        "com.apple.container.resource.role" : "control-plane,worker"
      },
      "maskedPaths" : [

      ],
      "mounts" : [
        {
          "destination" : "/opt/cluster-shim/hoststore.sock",
          "options" : [

          ],
          "source" : "/Users/test/Library/Application Support/com.apple.container/cluster-hoststore.sock",
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
            "hostname" : "deck-17-test-k",
            "mtu" : 1280
          }
        }
      ],
      "platform" : {
        "architecture" : "arm64",
        "os" : "linux"
      },
      "publishedPorts" : [
        {
          "containerPort" : 6443,
          "count" : 1,
          "hostAddress" : "0.0.0.0",
          "hostPort" : 6445,
          "proto" : "tcp"
        }
      ],
      "publishedSockets" : [

      ],
      "readOnly" : false,
      "readonlyPaths" : [

      ],
      "resources" : {
        "cpuOverhead" : 1,
        "cpus" : 2,
        "memoryInBytes" : 3221225472
      },
      "rosetta" : true,
      "runtimeHandler" : "container-runtime-linux",
      "ssh" : false,
      "stopSignal" : "SIGRTMIN+3",
      "sysctls" : {

      },
      "useInit" : false,
      "virtualization" : false
    },
    "id" : "deck-17-test-k",
    "status" : {
      "networks" : [
        {
          "hostname" : "deck-17-test-k",
          "ipv4Address" : "192.168.64.3/24",
          "ipv4Gateway" : "192.168.64.1",
          "ipv6Address" : "fd3a:ea47:104a:c220:f827:b9ff:fe6c:d52f/64",
          "macAddress" : "fa:27:b9:6c:d5:2f",
          "mtu" : 1280,
          "network" : "default",
          "variant" : "reserved"
        }
      ],
      "startedDate" : "2026-11-09T10:06:59Z",
      "state" : "running"
    }
  }
]
"""#

    /// container stats --no-stream --format json <node>: cpuUtilization is new
    static let statsJSON = #"""
[{"blockReadBytes":787857408,"blockWriteBytes":486350848,"cpuUsageUsec":15242893,"cpuUtilization":0.12067311253855775,"id":"deck-17-test-k","memoryLimitBytes":3221225472,"memoryUsageBytes":1689006080,"networkRxBytes":0,"networkTxBytes":0,"numProcesses":200}]
"""#

    /// container system property list --format json
    static let propertyListJSON = #"""
{"build":{"cpus":2,"image":"ghcr.io/apple/container-builder-shim/builder:0.13.3","memory":"2048mb","rosetta":true},"container":{"cpus":4,"memory":"1gb"},"dns":{},"kernel":{"binaryPath":"opt/kata/share/kata-containers/vmlinux-6.18.56-208-debug","digest":"sha256:2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6","url":"https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-arm64.tar.zst"},"machine":{"cpus":5,"homeMount":"rw","memory":"16gb","virtualization":false},"network":{},"registry":{"domain":"docker.io"},"vminit":{"image":"ghcr.io/apple/containerization/vminit:0.54.0"}}
"""#

    /// container stop <node> (exit 1)
    static let stopNodeError = #"""
Error: notFound: "container with ID deck-17-test-k not found"
"""#

    /// container start <node> (exit 1)
    static let startNodeError = #"""
Error: container with ID deck-17-test-k not found
"""#

    /// container delete <node> (exit 1)
    static let deleteNodeError = #"""
Error: notFound: "container with ID deck-17-test-k not found"
"""#

    /// container cluster load-image --name x alpine (exit 64, the subcommand is gone)
    static let loadImageError = #"""
Error: Unknown option '--name'
Usage: cluster <subcommand>
  See 'cluster --help' for more information.
"""#

    /// container cluster delete --name <unknown> (exit 1)
    static let clusterDeleteMissingError = #"""
Error: cluster deck-17-test-nope not found
"""#

    /// container run --cpus 64 (last line, exit 1)
    static let cpusTooManyError = #"""
Error: cpus must be between 1 and 10, the number of CPU cores on this host (got 64)
"""#
}
