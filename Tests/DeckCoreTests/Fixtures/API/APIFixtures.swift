// Replies recorded from Apple's container 1.6.1 daemon over XPC (macOS 27.2, Apple silicon)
// with DirectAPICaptureTests (DECK_CAPTURE_API=1). Home paths are scrubbed to /Users/me.
// Data values are the JSON payloads exactly as the daemon sent them.

enum APIFixtures {
    /// `ping` reply (string values).
    static let ping: [String: String] = [
        "apiServerAppName": "container-apiserver",
        "apiServerBuild": "release",
        "apiServerCommit": "aa8d76b44a834eee3ebf6a0bc577e376f65f6361",
        "apiServerVersion": "1.6.1",
        "appRoot": "file:///Users/me/Library/Application%20Support/com.apple.container/",
        "installRoot": "file:///usr/local/",
    ]

    /// `containerList` with no filters, key `containers`: buildkit, deck-demo-stopped, deck-demo-worker, deck-demo-web.
    static let containerList = #"""
    [{"startedDate":815574445.158512,"configuration":{"networks":[{"network":"default","options":{"hostname":"buildkit"}}],"mounts":[{"options":[],"source":"","destination":"\/run","type":{"tmpfs":{}}},{"options":[],"source":"\/Users\/me\/Library\/Application Support\/com.apple.container\/builder","destination":"\/var\/lib\/container-builder-shim\/exports","type":{"virtiofs":{}}}],"dns":{"nameservers":[],"searchDomains":[],"options":[]},"capAdd":["ALL"],"labels":{"com.apple.container.plugin":"builder","com.apple.container.resource.role":"builder"},"publishedPorts":[],"id":"buildkit","initProcess":{"terminal":false,"environment":["PATH=\/usr\/local\/sbin:\/usr\/local\/bin:\/usr\/sbin:\/usr\/bin:\/sbin:\/bin","BUILDKIT_SETUP_CGROUPV2_ROOT=1"],"workingDirectory":"\/","rlimits":[],"executable":"\/usr\/local\/bin\/container-builder-shim","arguments":["--debug","--vsock"],"supplementalGroups":[],"user":{"id":{"uid":0,"gid":0}}},"useInit":false,"readOnly":false,"sysctls":{},"resources":{"memoryInBytes":2147483648,"cpuOverhead":1,"cpus":2},"creationDate":815574444.179256,"runtimeHandler":"container-runtime-linux","image":{"descriptor":{"mediaType":"application\/vnd.oci.image.index.v1+json","digest":"sha256:ca27b4f564f2653207ef8f57ec7ba1653d11e7bbc51833503c243016ee65c2f8","size":856},"reference":"ghcr.io\/apple\/container-builder-shim\/builder:0.13.2"},"platform":{"variant":"v8","architecture":"arm64","os":"linux"},"ssh":false,"rosetta":true,"publishedSockets":[],"virtualization":false,"capDrop":[]},"networks":[{"variant":"reserved","macAddress":"fe:a6:6e:1c:72:98","ipv4Gateway":"192.168.64.1","ipv6Address":"fd3a:ea47:104a:c220:fca6:6eff:fe1c:7298\/64","ipv4Address":"192.168.64.15\/24","network":"default","hostname":"buildkit"}],"status":"running"},{"startedDate":815581284.693128,"configuration":{"networks":[{"network":"default","options":{"mtu":1280,"hostname":"deck-demo-stopped"}}],"mounts":[],"dns":{"nameservers":[],"searchDomains":[],"options":[]},"capAdd":[],"labels":{},"publishedPorts":[],"id":"deck-demo-stopped","initProcess":{"terminal":false,"environment":["PATH=\/usr\/local\/sbin:\/usr\/local\/bin:\/usr\/sbin:\/usr\/bin:\/sbin:\/bin"],"workingDirectory":"\/","rlimits":[],"executable":"echo","arguments":["hi"],"supplementalGroups":[],"user":{"id":{"uid":0,"gid":0}}},"useInit":false,"readOnly":false,"sysctls":{},"resources":{"memoryInBytes":1073741824,"cpuOverhead":1,"cpus":4},"creationDate":815575181.450849,"runtimeHandler":"container-runtime-linux","image":{"descriptor":{"mediaType":"application\/vnd.oci.image.index.v1+json","digest":"sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a","size":9218},"reference":"docker.io\/library\/alpine:latest"},"platform":{"variant":"v8","architecture":"arm64","os":"linux"},"ssh":false,"rosetta":false,"publishedSockets":[],"virtualization":false,"capDrop":[]},"networks":[],"status":"stopped"},{"startedDate":815575181.398874,"configuration":{"networks":[{"network":"deck-demo-net","options":{"mtu":1280,"hostname":"deck-demo-worker"}}],"mounts":[],"dns":{"nameservers":[],"searchDomains":[],"options":[]},"capAdd":[],"labels":{},"publishedPorts":[],"id":"deck-demo-worker","initProcess":{"terminal":false,"environment":["PATH=\/usr\/local\/sbin:\/usr\/local\/bin:\/usr\/sbin:\/usr\/bin:\/sbin:\/bin"],"workingDirectory":"\/","rlimits":[],"executable":"sh","arguments":["-c","i=0; while true; do echo \"tick $i\"; i=$((i+1)); sleep 2; done"],"supplementalGroups":[],"user":{"id":{"uid":0,"gid":0}}},"useInit":false,"readOnly":false,"sysctls":{},"resources":{"memoryInBytes":1073741824,"cpuOverhead":1,"cpus":4},"creationDate":815575180.79809,"runtimeHandler":"container-runtime-linux","image":{"descriptor":{"mediaType":"application\/vnd.oci.image.index.v1+json","digest":"sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a","size":9218},"reference":"docker.io\/library\/alpine:latest"},"platform":{"variant":"v8","architecture":"arm64","os":"linux"},"ssh":false,"rosetta":false,"publishedSockets":[],"virtualization":false,"capDrop":[]},"networks":[{"mtu":1280,"macAddress":"fa:d3:ce:8e:c5:08","variant":"reserved","ipv4Gateway":"192.168.65.1","ipv6Address":"fd3c:507c:de5a:f964:f8d3:ceff:fe8e:c508\/64","ipv4Address":"192.168.65.3\/24","network":"deck-demo-net","hostname":"deck-demo-worker"}],"status":"running"},{"startedDate":815575180.748777,"configuration":{"networks":[{"network":"deck-demo-net","options":{"mtu":1280,"hostname":"deck-demo-web"}}],"mounts":[{"options":[],"source":"\/Users\/me\/Library\/Application Support\/com.apple.container\/volumes\/deck-demo-data\/volume.img","destination":"\/usr\/share\/nginx\/html\/data","type":{"volume":{"sync":{"fsync":{}},"name":"deck-demo-data","format":"ext4","cache":{"on":{}}}}}],"dns":{"nameservers":[],"searchDomains":[],"options":[]},"capAdd":[],"labels":{"app":"demo"},"publishedPorts":[{"hostAddress":"0.0.0.0","count":1,"containerPort":80,"proto":"tcp","hostPort":18090}],"id":"deck-demo-web","initProcess":{"terminal":false,"environment":["NGINX_VERSION=1.31.8","DYNPKG_RELEASE=1","NJS_VERSION=1.0.2","ACME_VERSION=0.4.1","NJS_RELEASE=1","PKG_RELEASE=1","MODE=demo","PATH=\/usr\/local\/sbin:\/usr\/local\/bin:\/usr\/sbin:\/usr\/bin:\/sbin:\/bin"],"workingDirectory":"\/","rlimits":[],"executable":"\/docker-entrypoint.sh","arguments":["nginx","-g","daemon off;"],"supplementalGroups":[],"user":{"id":{"uid":0,"gid":0}}},"useInit":false,"readOnly":false,"sysctls":{},"resources":{"memoryInBytes":1073741824,"cpuOverhead":1,"cpus":4},"stopSignal":"SIGQUIT","creationDate":815575180.147131,"runtimeHandler":"container-runtime-linux","image":{"descriptor":{"mediaType":"application\/vnd.oci.image.index.v1+json","digest":"sha256:785835ea65db4bba6f021acc0f3be91b0fef76a53fe41f8588c6698d2aed0606","size":10333},"reference":"docker.io\/library\/nginx:alpine"},"platform":{"variant":"v8","architecture":"arm64","os":"linux"},"ssh":false,"rosetta":false,"publishedSockets":[],"virtualization":false,"capDrop":[]},"networks":[{"mtu":1280,"macAddress":"fa:33:c7:ac:e1:ce","variant":"reserved","ipv4Gateway":"192.168.65.1","ipv6Address":"fd3c:507c:de5a:f964:f833:c7ff:feac:e1ce\/64","ipv4Address":"192.168.65.2\/24","network":"deck-demo-net","hostname":"deck-demo-web"}],"status":"running"}]
    """#

    /// `containerStats` for deck-demo-web, key `statistics`.
    static let containerStats = #"""
    {"numProcesses":6,"blockWriteBytes":147456,"memoryLimitBytes":1073741824,"blockReadBytes":10617856,"memoryUsageBytes":16539648,"networkRxBytes":1193838,"id":"deck-demo-web","networkTxBytes":602,"cpuUsageUsec":38371}
    """#

    /// `volumeList`, key `volumes`.
    static let volumeList = #"""
    [{"name":"deck-demo-data","format":"ext4","creationDate":815575180.109989,"driver":"local","source":"\/Users\/me\/Library\/Application Support\/com.apple.container\/volumes\/deck-demo-data\/volume.img","labels":{},"sizeInBytes":549755813888,"options":{}}]
    """#

    /// `networkList`, key `networkResources`.
    static let networkList = #"""
    [{"id":"deck-demo-net","configuration":{"creationDate":815575180.019172,"plugin":"container-network-vmnet","name":"deck-demo-net","mode":"nat","labels":{},"options":{}},"status":{"ipv4Subnet":"192.168.65.0\/24","ipv6Subnet":"fd3c:507c:de5a:f964::\/64","ipv4Gateway":"192.168.65.1"}},{"id":"default","configuration":{"creationDate":815568133.430783,"plugin":"container-network-vmnet","name":"default","mode":"nat","labels":{"com.apple.container.resource.role":"builtin"},"options":{}},"status":{"ipv4Subnet":"192.168.64.0\/24","ipv6Subnet":"fd3a:ea47:104a:c220::\/64","ipv4Gateway":"192.168.64.1"}}]
    """#

    /// `systemDiskUsage`, key `diskUsageStats`.
    static let systemDiskUsage = #"""
    {"volumes":{"active":1,"total":1,"reclaimable":0,"sizeInBytes":39882752},"images":{"active":3,"total":6,"reclaimable":1358770176,"sizeInBytes":3054493696},"containers":{"active":3,"total":4,"reclaimable":249237504,"sizeInBytes":1323450368}}
    """#

    /// `imageList` from the images service, key `imageDescriptions`.
    static let imageList = #"""
    [{"descriptor":{"digest":"sha256:526b1bf414a186ce6047e600830fb2981509f041cf4d4ce91653d97bd30d4700","size":306,"mediaType":"application\/vnd.oci.image.index.v1+json"},"reference":"ghcr.io\/apple\/containerization\/vminit:0.53.0"},{"descriptor":{"mediaType":"application\/vnd.oci.image.index.v1+json","digest":"sha256:785835ea65db4bba6f021acc0f3be91b0fef76a53fe41f8588c6698d2aed0606","size":10333},"reference":"docker.io\/library\/nginx:alpine"},{"descriptor":{"mediaType":"application\/vnd.oci.image.index.v1+json","digest":"sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f","size":9218},"reference":"docker.io\/library\/alpine:3.22"},{"descriptor":{"size":856,"mediaType":"application\/vnd.oci.image.index.v1+json","digest":"sha256:ca27b4f564f2653207ef8f57ec7ba1653d11e7bbc51833503c243016ee65c2f8"},"reference":"ghcr.io\/apple\/container-builder-shim\/builder:0.13.2"},{"descriptor":{"size":10213,"mediaType":"application\/vnd.oci.image.index.v1+json","digest":"sha256:21090af93f8324db2f0f0f4f38a7c60369d47d917e000c3423d89d2ae2883537"},"reference":"docker.io\/library\/redis:alpine"},{"descriptor":{"size":9218,"digest":"sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a","mediaType":"application\/vnd.oci.image.index.v1+json"},"reference":"docker.io\/library\/alpine:latest"}]
    """#

    /// Error reply of `containerStats` for an unknown id, key `com.apple.container.xpc.error`.
    static let notFoundError = #"""
    {"message":"container with ID deck-test-api-missing not found","code":"notFound"}
    """#

    /// Content store blobs of docker.io/library/alpine:latest (index, manifests, configs) by digest.
    static let alpineBlobs: [String: String] = [
        "sha256:0755b53b8929e38b33891e00a25b3bf63d5d264015072c8b4a80276d2f711ac4": ##"""
{"architecture":"unknown","os":"unknown","config":{},"rootfs":{"type":"layers","diff_ids":["sha256:9b33a27682ba75f64f7a206db7861ca01db323fa8e4b4afc016c1b2720f989dc","sha256:8be028b51e04eac5f6985c6705b55ed92e29c2b7b8f8a6753e45c641ad91f0bd"]}}
"""##,
        "sha256:0fa2aca5c15b9553f7f325fcdcc1264e0dca4e7d3f09d11b09d89bf88c7b6b85": ##"""
{"architecture":"s390x","config":{"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"Cmd":["/bin/sh"],"WorkingDir":"/"},"created":"2026-10-21T22:34:15.856071671Z","history":[{"created":"2026-10-21T22:34:15.856071671Z","created_by":"ADD alpine-minirootfs-3.24.3-s390x.tar.gz / # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2026-10-21T22:34:15.856071671Z","created_by":"CMD [\"/bin/sh\"]","comment":"buildkit.dockerfile.v0","empty_layer":true}],"os":"linux","rootfs":{"type":"layers","diff_ids":["sha256:fedfd7b10c14e19ac6592c50e73375cb89ecf3c51adb86b75b86f966e4b368ce"]}}
"""##,
        "sha256:12fab14f7a43d3fabe0a4047c9b8b2de354608c1421ab7df6e265508f67a7c74": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:19c6000a31c8b458d1f2ad9ca49c0fdee1cc241db64569b219be834b5d025f56",
    "size": 241
  },
  "layers": [
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:1f5e073a0848a161860b160c6f2f939fcf232fd457c837cd8ade8ff5ad6e2028",
      "size": 79022,
      "annotations": {
        "in-toto.io/predicate-type": "https://spdx.dev/Document"
      }
    },
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:bfa1b0ebfd5c9c86fe3cfd9cc6afbe5e528da11f96a1b9d81f3f8631cbbf5e96",
      "size": 5635,
      "annotations": {
        "in-toto.io/predicate-type": "https://slsa.dev/provenance/v0.2"
      }
    }
  ]
}
"""##,
        "sha256:19c6000a31c8b458d1f2ad9ca49c0fdee1cc241db64569b219be834b5d025f56": ##"""
{"architecture":"unknown","os":"unknown","config":{},"rootfs":{"type":"layers","diff_ids":["sha256:1f5e073a0848a161860b160c6f2f939fcf232fd457c837cd8ade8ff5ad6e2028","sha256:bfa1b0ebfd5c9c86fe3cfd9cc6afbe5e528da11f96a1b9d81f3f8631cbbf5e96"]}}
"""##,
        "sha256:1aee90cdbda4ad57477d7481c68b64ad16e03f2ed23e200f719a22bfc55407be": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:0755b53b8929e38b33891e00a25b3bf63d5d264015072c8b4a80276d2f711ac4",
    "size": 241
  },
  "layers": [
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:9b33a27682ba75f64f7a206db7861ca01db323fa8e4b4afc016c1b2720f989dc",
      "size": 79056,
      "annotations": {
        "in-toto.io/predicate-type": "https://spdx.dev/Document"
      }
    },
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:8be028b51e04eac5f6985c6705b55ed92e29c2b7b8f8a6753e45c641ad91f0bd",
      "size": 5675,
      "annotations": {
        "in-toto.io/predicate-type": "https://slsa.dev/provenance/v0.2"
      }
    }
  ]
}
"""##,
        "sha256:2b8ed0bd9e82c247a3817b867718404f020ab8f701bda09642ddfaa7b4f1578d": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:e355d80e026960b969d0e287d7900c15fa7195d29641e8ac173cc15db169be2a",
    "size": 623
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:61279dc9f8c5bf0223a3425a62f1aa1724ff7bf43c3d15f18ff665dc59c1f0c3",
      "size": 3558291
    }
  ],
  "annotations": {
    "com.docker.official-images.bashbrew.arch": "arm32v6",
    "org.opencontainers.image.base.name": "scratch",
    "org.opencontainers.image.created": "2026-10-21T22:58:55Z",
    "org.opencontainers.image.revision": "5aec467fb81238bae9441eea2edb000655d7044f",
    "org.opencontainers.image.source": "https://github.com/alpinelinux/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:armhf",
    "org.opencontainers.image.url": "https://hub.docker.com/_/alpine",
    "org.opencontainers.image.version": "3.24.3"
  }
}
"""##,
        "sha256:3072df410779703fae18fd6ac75dc2f892c51d6413326fcdd98470c036593e2b": ##"""
{"architecture":"unknown","os":"unknown","config":{},"rootfs":{"type":"layers","diff_ids":["sha256:ec3f0dc865f267cb7c1c255f05a640cbc5622e82d685b8434945952da1d24523","sha256:ce331c590d4e19fac02d6a835f79fac82b084b3d9db36fc7a85376f278834429"]}}
"""##,
        "sha256:37480ae6d5242e16a2f59464deed2018531936746a1a3928df39b4ce5dab6b4c": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:ebd888f836a2528406b0e39258543812b79eb1230e22d23d2d52ae4045dd2447",
    "size": 241
  },
  "layers": [
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:29747bda1d3c065ea62db09b8abbd76af03faea5b73430caf3a0868b1c4e54e3",
      "size": 79052,
      "annotations": {
        "in-toto.io/predicate-type": "https://spdx.dev/Document"
      }
    },
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:33ac1b7ce393a09914f1bfc3479275e30a9172b69e5940094820414dc0605f2a",
      "size": 5675,
      "annotations": {
        "in-toto.io/predicate-type": "https://slsa.dev/provenance/v0.2"
      }
    }
  ]
}
"""##,
        "sha256:4451fbe20381b2a23da80f7a6f68f30f3ff0ff2f4a4a074505a52bd46423fb39": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:930c843ca8580c0e5e5c4e447463fd5f491ef402828b62ebfd0f1f1252f46875",
    "size": 614
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:d1f03d57b9e445bf2f081d3fa147f8cb25fb9947e846cfe04bf02b18e5d16d0b",
      "size": 3580647
    }
  ],
  "annotations": {
    "com.docker.official-images.bashbrew.arch": "riscv64",
    "org.opencontainers.image.base.name": "scratch",
    "org.opencontainers.image.created": "2026-10-23T04:52:11Z",
    "org.opencontainers.image.revision": "5aec467fb81238bae9441eea2edb000655d7044f",
    "org.opencontainers.image.source": "https://github.com/alpinelinux/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:riscv64",
    "org.opencontainers.image.url": "https://hub.docker.com/_/alpine",
    "org.opencontainers.image.version": "3.24.3"
  }
}
"""##,
        "sha256:563589a905f92e0add079850ab496c980d78cc70b4b30114d4d9bab1c0aa22d8": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:3072df410779703fae18fd6ac75dc2f892c51d6413326fcdd98470c036593e2b",
    "size": 241
  },
  "layers": [
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:ec3f0dc865f267cb7c1c255f05a640cbc5622e82d685b8434945952da1d24523",
      "size": 79059,
      "annotations": {
        "in-toto.io/predicate-type": "https://spdx.dev/Document"
      }
    },
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:ce331c590d4e19fac02d6a835f79fac82b084b3d9db36fc7a85376f278834429",
      "size": 5680,
      "annotations": {
        "in-toto.io/predicate-type": "https://slsa.dev/provenance/v0.2"
      }
    }
  ]
}
"""##,
        "sha256:61be5360464c8c9e44dae6345ab12dcadab9ddf8ac103ab4e3bc67546f1e0096": ##"""
{"architecture":"unknown","os":"unknown","config":{},"rootfs":{"type":"layers","diff_ids":["sha256:f89dc04d14086cefb9b07b9f81f656de51a0c107670c4e5368310b6c2ae1be65"]}}
"""##,
        "sha256:6708ca119efec5c3fdcad5dc95d8a28a529aad8debc95872b7e12b3941882f55": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:cf337b8a15d3ca00d7ba78864a77be6addaac4f7ca3e788c74cc5a0c5a333c0c",
    "size": 606
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:f89afe85a29e874c0bc6d49b09150af4f08fbc4e6db82e7870677ef76977c07d",
      "size": 3678996
    }
  ],
  "annotations": {
    "com.docker.official-images.bashbrew.arch": "i386",
    "org.opencontainers.image.base.name": "scratch",
    "org.opencontainers.image.created": "2026-10-21T22:50:40Z",
    "org.opencontainers.image.revision": "5aec467fb81238bae9441eea2edb000655d7044f",
    "org.opencontainers.image.source": "https://github.com/alpinelinux/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:x86",
    "org.opencontainers.image.url": "https://hub.docker.com/_/alpine",
    "org.opencontainers.image.version": "3.24.3"
  }
}
"""##,
        "sha256:6db0aa37b0f1ba86c31102b0972cb082a1d22ed1390440de84f1076d78d4d399": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:9385716c97757df234fce09484ff392f2e040bca4d9b32c69fc0a18edbd48a93",
    "size": 623
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:1e8d134240abdd47977b92433f069c273d151b9fba9396fd8ba3107b7222f7a1",
      "size": 3266660
    }
  ],
  "annotations": {
    "com.docker.official-images.bashbrew.arch": "arm32v7",
    "org.opencontainers.image.base.name": "scratch",
    "org.opencontainers.image.created": "2026-10-21T22:52:04Z",
    "org.opencontainers.image.revision": "5aec467fb81238bae9441eea2edb000655d7044f",
    "org.opencontainers.image.source": "https://github.com/alpinelinux/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:armv7",
    "org.opencontainers.image.url": "https://hub.docker.com/_/alpine",
    "org.opencontainers.image.version": "3.24.3"
  }
}
"""##,
        "sha256:8603c585662f0dcd519f4838a40ea3ef98542466848021ffd3c7b7979896362a": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:d061e1b71a38d1deabc10789216a805e7830c4819af45d7452cf5dc4053f7e60",
    "size": 614
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:728471849cc01302688ff7a09ad468af8cc8bc8a93620b78513c28269284715c",
      "size": 3820822
    }
  ],
  "annotations": {
    "com.docker.official-images.bashbrew.arch": "ppc64le",
    "org.opencontainers.image.base.name": "scratch",
    "org.opencontainers.image.created": "2026-10-22T02:44:42Z",
    "org.opencontainers.image.revision": "5aec467fb81238bae9441eea2edb000655d7044f",
    "org.opencontainers.image.source": "https://github.com/alpinelinux/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:ppc64le",
    "org.opencontainers.image.url": "https://hub.docker.com/_/alpine",
    "org.opencontainers.image.version": "3.24.3"
  }
}
"""##,
        "sha256:930c843ca8580c0e5e5c4e447463fd5f491ef402828b62ebfd0f1f1252f46875": ##"""
{"architecture":"riscv64","config":{"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"Cmd":["/bin/sh"],"WorkingDir":"/"},"created":"2026-10-23T04:53:36.167351959Z","history":[{"created":"2026-10-23T04:53:36.167351959Z","created_by":"ADD alpine-minirootfs-3.24.3-riscv64.tar.gz / # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2026-10-23T04:53:36.167351959Z","created_by":"CMD [\"/bin/sh\"]","comment":"buildkit.dockerfile.v0","empty_layer":true}],"os":"linux","rootfs":{"type":"layers","diff_ids":["sha256:e3bbab4ea754040ac3203a90316249e34faddebd872d4d57299a4788652c7219"]}}
"""##,
        "sha256:9385716c97757df234fce09484ff392f2e040bca4d9b32c69fc0a18edbd48a93": ##"""
{"architecture":"arm","config":{"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"Cmd":["/bin/sh"],"WorkingDir":"/"},"created":"2026-10-21T22:52:08.011229658Z","history":[{"created":"2026-10-21T22:52:08.011229658Z","created_by":"ADD alpine-minirootfs-3.24.3-armv7.tar.gz / # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2026-10-21T22:52:08.011229658Z","created_by":"CMD [\"/bin/sh\"]","comment":"buildkit.dockerfile.v0","empty_layer":true}],"os":"linux","rootfs":{"type":"layers","diff_ids":["sha256:57bdcfbae46b39379e9e99bb9cb40b58b212e4526ae7e7368e0b480df7265cd2"]},"variant":"v7"}
"""##,
        "sha256:94db52ee2ab0391093b6748b79508ce6f91a046348f67afae380f372633f5c55": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:c7de23c0f1dee63288bd3609d13277b570ac1bf1239a63f309d45b919d5fd4e5",
    "size": 241
  },
  "layers": [
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:4f276f238bfa828dbab5278d88d58fc8fe7e9e25d51480a58edd86345b9b3d18",
      "size": 79079,
      "annotations": {
        "in-toto.io/predicate-type": "https://spdx.dev/Document"
      }
    },
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:2a02c517eb64135dab6f5144122f5445c0bc2c70a8f366a307e5ffe1131b6543",
      "size": 5705,
      "annotations": {
        "in-toto.io/predicate-type": "https://slsa.dev/provenance/v0.2"
      }
    }
  ]
}
"""##,
        "sha256:964745728d174226819257152a79b34561fe7321472eb9c8e32f461cbc7969c2": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:bcd0699075b7694fe6061b0cf0bc8134b3f900f8d7456021c06b7cbbef460f8b",
    "size": 241
  },
  "layers": [
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:3ec36f3670df56d1b1d4323910cf6747576cb31e5e5d32c64715339876d86f20",
      "size": 79673,
      "annotations": {
        "in-toto.io/predicate-type": "https://spdx.dev/Document"
      }
    },
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:3da1513d2124248e6e2a526d532ff365833915ce1abe0813bfc5344190827406",
      "size": 5639,
      "annotations": {
        "in-toto.io/predicate-type": "https://slsa.dev/provenance/v0.2"
      }
    }
  ]
}
"""##,
        "sha256:9cd0af5f6f5293ca382cb0af87303afd6f41019fa4d30efd799a3a8024f6c7b4": ##"""
{"architecture":"unknown","os":"unknown","config":{},"rootfs":{"type":"layers","diff_ids":["sha256:8c3b30e35c78f1cf8d214a1a580a722f15068fcd3300eda99e2e8abfe2760223","sha256:33edc3e95bba61af0bb64f626e90c847bc758b027949c8b128327de67b6c5679"]}}
"""##,
        "sha256:a28d9fc2e441f25a4340eaa840511d5ad1e07522bd56b498af238382f40ade35": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:61be5360464c8c9e44dae6345ab12dcadab9ddf8ac103ab4e3bc67546f1e0096",
    "size": 167
  },
  "layers": [
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:f89dc04d14086cefb9b07b9f81f656de51a0c107670c4e5368310b6c2ae1be65",
      "size": 5465,
      "annotations": {
        "in-toto.io/predicate-type": "https://slsa.dev/provenance/v0.2"
      }
    }
  ]
}
"""##,
        "sha256:b92841763c5c2140a20eeb2a44e94ebb0e80fd51d9d6b5895ea72fa999525d68": ##"""
{"architecture":"amd64","config":{"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"Cmd":["/bin/sh"],"WorkingDir":"/"},"created":"2026-10-21T22:37:22.870489069Z","history":[{"created":"2026-10-21T22:37:22.870489069Z","created_by":"ADD alpine-minirootfs-3.24.3-x86_64.tar.gz / # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2026-10-21T22:37:22.870489069Z","created_by":"CMD [\"/bin/sh\"]","comment":"buildkit.dockerfile.v0","empty_layer":true}],"os":"linux","rootfs":{"type":"layers","diff_ids":["sha256:75c137aedfb2760f88629236cb7b797630aed0c3d91d626d1d1bb694878fc2ba"]}}
"""##,
        "sha256:ba50faba2da27dc9cc11c6f496125fea631b0778bcb29aaf59f904bb36ea0a8a": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:9cd0af5f6f5293ca382cb0af87303afd6f41019fa4d30efd799a3a8024f6c7b4",
    "size": 241
  },
  "layers": [
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:8c3b30e35c78f1cf8d214a1a580a722f15068fcd3300eda99e2e8abfe2760223",
      "size": 79648,
      "annotations": {
        "in-toto.io/predicate-type": "https://spdx.dev/Document"
      }
    },
    {
      "mediaType": "application/vnd.in-toto+json",
      "digest": "sha256:33edc3e95bba61af0bb64f626e90c847bc758b027949c8b128327de67b6c5679",
      "size": 5599,
      "annotations": {
        "in-toto.io/predicate-type": "https://slsa.dev/provenance/v0.2"
      }
    }
  ]
}
"""##,
        "sha256:bcd0699075b7694fe6061b0cf0bc8134b3f900f8d7456021c06b7cbbef460f8b": ##"""
{"architecture":"unknown","os":"unknown","config":{},"rootfs":{"type":"layers","diff_ids":["sha256:3ec36f3670df56d1b1d4323910cf6747576cb31e5e5d32c64715339876d86f20","sha256:3da1513d2124248e6e2a526d532ff365833915ce1abe0813bfc5344190827406"]}}
"""##,
        "sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a": ##"""
{"manifests":[{"annotations":{"com.docker.official-images.bashbrew.arch":"amd64","org.opencontainers.image.base.name":"scratch","org.opencontainers.image.created":"2026-10-21T22:37:09Z","org.opencontainers.image.revision":"5aec467fb81238bae9441eea2edb000655d7044f","org.opencontainers.image.source":"https:\/\/github.com\/alpinelinux\/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:x86_64","org.opencontainers.image.url":"https:\/\/hub.docker.com\/_\/alpine","org.opencontainers.image.version":"3.24.3"},"digest":"sha256:c26612752c78b18faacd63c7d50f4592c2e7b0f25e0e20e82bd74e465c57ab0d","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"amd64","os":"linux"},"size":1022},{"annotations":{"com.docker.official-images.bashbrew.arch":"amd64","vnd.docker.reference.digest":"sha256:c26612752c78b18faacd63c7d50f4592c2e7b0f25e0e20e82bd74e465c57ab0d","vnd.docker.reference.type":"attestation-manifest"},"digest":"sha256:964745728d174226819257152a79b34561fe7321472eb9c8e32f461cbc7969c2","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"unknown","os":"unknown"},"size":838},{"annotations":{"com.docker.official-images.bashbrew.arch":"arm32v6","org.opencontainers.image.base.name":"scratch","org.opencontainers.image.created":"2026-10-21T22:58:55Z","org.opencontainers.image.revision":"5aec467fb81238bae9441eea2edb000655d7044f","org.opencontainers.image.source":"https:\/\/github.com\/alpinelinux\/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:armhf","org.opencontainers.image.url":"https:\/\/hub.docker.com\/_\/alpine","org.opencontainers.image.version":"3.24.3"},"digest":"sha256:2b8ed0bd9e82c247a3817b867718404f020ab8f701bda09642ddfaa7b4f1578d","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"arm","os":"linux","variant":"v6"},"size":1023},{"annotations":{"com.docker.official-images.bashbrew.arch":"arm32v6","vnd.docker.reference.digest":"sha256:2b8ed0bd9e82c247a3817b867718404f020ab8f701bda09642ddfaa7b4f1578d","vnd.docker.reference.type":"attestation-manifest"},"digest":"sha256:a28d9fc2e441f25a4340eaa840511d5ad1e07522bd56b498af238382f40ade35","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"unknown","os":"unknown"},"size":566},{"annotations":{"com.docker.official-images.bashbrew.arch":"arm32v7","org.opencontainers.image.base.name":"scratch","org.opencontainers.image.created":"2026-10-21T22:52:04Z","org.opencontainers.image.revision":"5aec467fb81238bae9441eea2edb000655d7044f","org.opencontainers.image.source":"https:\/\/github.com\/alpinelinux\/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:armv7","org.opencontainers.image.url":"https:\/\/hub.docker.com\/_\/alpine","org.opencontainers.image.version":"3.24.3"},"digest":"sha256:6db0aa37b0f1ba86c31102b0972cb082a1d22ed1390440de84f1076d78d4d399","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"arm","os":"linux","variant":"v7"},"size":1023},{"annotations":{"com.docker.official-images.bashbrew.arch":"arm32v7","vnd.docker.reference.digest":"sha256:6db0aa37b0f1ba86c31102b0972cb082a1d22ed1390440de84f1076d78d4d399","vnd.docker.reference.type":"attestation-manifest"},"digest":"sha256:563589a905f92e0add079850ab496c980d78cc70b4b30114d4d9bab1c0aa22d8","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"unknown","os":"unknown"},"size":838},{"annotations":{"com.docker.official-images.bashbrew.arch":"arm64v8","org.opencontainers.image.base.name":"scratch","org.opencontainers.image.created":"2026-10-21T22:51:34Z","org.opencontainers.image.revision":"5aec467fb81238bae9441eea2edb000655d7044f","org.opencontainers.image.source":"https:\/\/github.com\/alpinelinux\/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:aarch64","org.opencontainers.image.url":"https:\/\/hub.docker.com\/_\/alpine","org.opencontainers.image.version":"3.24.3"},"digest":"sha256:e311ae748be7f56ae5cba304bc488f0786df68ee507513f654a5cc8597cffb42","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"arm64","os":"linux","variant":"v8"},"size":1025},{"annotations":{"com.docker.official-images.bashbrew.arch":"arm64v8","vnd.docker.reference.digest":"sha256:e311ae748be7f56ae5cba304bc488f0786df68ee507513f654a5cc8597cffb42","vnd.docker.reference.type":"attestation-manifest"},"digest":"sha256:94db52ee2ab0391093b6748b79508ce6f91a046348f67afae380f372633f5c55","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"unknown","os":"unknown"},"size":838},{"annotations":{"com.docker.official-images.bashbrew.arch":"i386","org.opencontainers.image.base.name":"scratch","org.opencontainers.image.created":"2026-10-21T22:50:40Z","org.opencontainers.image.revision":"5aec467fb81238bae9441eea2edb000655d7044f","org.opencontainers.image.source":"https:\/\/github.com\/alpinelinux\/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:x86","org.opencontainers.image.url":"https:\/\/hub.docker.com\/_\/alpine","org.opencontainers.image.version":"3.24.3"},"digest":"sha256:6708ca119efec5c3fdcad5dc95d8a28a529aad8debc95872b7e12b3941882f55","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"386","os":"linux"},"size":1018},{"annotations":{"com.docker.official-images.bashbrew.arch":"i386","vnd.docker.reference.digest":"sha256:6708ca119efec5c3fdcad5dc95d8a28a529aad8debc95872b7e12b3941882f55","vnd.docker.reference.type":"attestation-manifest"},"digest":"sha256:ba50faba2da27dc9cc11c6f496125fea631b0778bcb29aaf59f904bb36ea0a8a","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"unknown","os":"unknown"},"size":838},{"annotations":{"com.docker.official-images.bashbrew.arch":"ppc64le","org.opencontainers.image.base.name":"scratch","org.opencontainers.image.created":"2026-10-22T02:44:42Z","org.opencontainers.image.revision":"5aec467fb81238bae9441eea2edb000655d7044f","org.opencontainers.image.source":"https:\/\/github.com\/alpinelinux\/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:ppc64le","org.opencontainers.image.url":"https:\/\/hub.docker.com\/_\/alpine","org.opencontainers.image.version":"3.24.3"},"digest":"sha256:8603c585662f0dcd519f4838a40ea3ef98542466848021ffd3c7b7979896362a","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"ppc64le","os":"linux"},"size":1025},{"annotations":{"com.docker.official-images.bashbrew.arch":"ppc64le","vnd.docker.reference.digest":"sha256:8603c585662f0dcd519f4838a40ea3ef98542466848021ffd3c7b7979896362a","vnd.docker.reference.type":"attestation-manifest"},"digest":"sha256:1aee90cdbda4ad57477d7481c68b64ad16e03f2ed23e200f719a22bfc55407be","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"unknown","os":"unknown"},"size":838},{"annotations":{"com.docker.official-images.bashbrew.arch":"riscv64","org.opencontainers.image.base.name":"scratch","org.opencontainers.image.created":"2026-10-23T04:52:11Z","org.opencontainers.image.revision":"5aec467fb81238bae9441eea2edb000655d7044f","org.opencontainers.image.source":"https:\/\/github.com\/alpinelinux\/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:riscv64","org.opencontainers.image.url":"https:\/\/hub.docker.com\/_\/alpine","org.opencontainers.image.version":"3.24.3"},"digest":"sha256:4451fbe20381b2a23da80f7a6f68f30f3ff0ff2f4a4a074505a52bd46423fb39","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"riscv64","os":"linux"},"size":1025},{"annotations":{"com.docker.official-images.bashbrew.arch":"riscv64","vnd.docker.reference.digest":"sha256:4451fbe20381b2a23da80f7a6f68f30f3ff0ff2f4a4a074505a52bd46423fb39","vnd.docker.reference.type":"attestation-manifest"},"digest":"sha256:37480ae6d5242e16a2f59464deed2018531936746a1a3928df39b4ce5dab6b4c","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"unknown","os":"unknown"},"size":838},{"annotations":{"com.docker.official-images.bashbrew.arch":"s390x","org.opencontainers.image.base.name":"scratch","org.opencontainers.image.created":"2026-10-21T22:34:02Z","org.opencontainers.image.revision":"5aec467fb81238bae9441eea2edb000655d7044f","org.opencontainers.image.source":"https:\/\/github.com\/alpinelinux\/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:s390x","org.opencontainers.image.url":"https:\/\/hub.docker.com\/_\/alpine","org.opencontainers.image.version":"3.24.3"},"digest":"sha256:e56e90d77a05614cba94ec4c791282e108f3eac66d697781a79f9c0ccf2f6804","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"s390x","os":"linux"},"size":1021},{"annotations":{"com.docker.official-images.bashbrew.arch":"s390x","vnd.docker.reference.digest":"sha256:e56e90d77a05614cba94ec4c791282e108f3eac66d697781a79f9c0ccf2f6804","vnd.docker.reference.type":"attestation-manifest"},"digest":"sha256:12fab14f7a43d3fabe0a4047c9b8b2de354608c1421ab7df6e265508f67a7c74","mediaType":"application\/vnd.oci.image.manifest.v1+json","platform":{"architecture":"unknown","os":"unknown"},"size":838}],"mediaType":"application\/vnd.oci.image.index.v1+json","schemaVersion":2}
"""##,
        "sha256:c26612752c78b18faacd63c7d50f4592c2e7b0f25e0e20e82bd74e465c57ab0d": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:b92841763c5c2140a20eeb2a44e94ebb0e80fd51d9d6b5895ea72fa999525d68",
    "size": 611
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:7b229517ed222597277036d94892173207d01a731ab3a88eeb1de2e963a2c788",
      "size": 3853109
    }
  ],
  "annotations": {
    "com.docker.official-images.bashbrew.arch": "amd64",
    "org.opencontainers.image.base.name": "scratch",
    "org.opencontainers.image.created": "2026-10-21T22:37:09Z",
    "org.opencontainers.image.revision": "5aec467fb81238bae9441eea2edb000655d7044f",
    "org.opencontainers.image.source": "https://github.com/alpinelinux/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:x86_64",
    "org.opencontainers.image.url": "https://hub.docker.com/_/alpine",
    "org.opencontainers.image.version": "3.24.3"
  }
}
"""##,
        "sha256:c7de23c0f1dee63288bd3609d13277b570ac1bf1239a63f309d45b919d5fd4e5": ##"""
{"architecture":"unknown","os":"unknown","config":{},"rootfs":{"type":"layers","diff_ids":["sha256:4f276f238bfa828dbab5278d88d58fc8fe7e9e25d51480a58edd86345b9b3d18","sha256:2a02c517eb64135dab6f5144122f5445c0bc2c70a8f366a307e5ffe1131b6543"]}}
"""##,
        "sha256:cf337b8a15d3ca00d7ba78864a77be6addaac4f7ca3e788c74cc5a0c5a333c0c": ##"""
{"architecture":"386","config":{"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"Cmd":["/bin/sh"],"WorkingDir":"/"},"created":"2026-10-21T22:50:43.800083616Z","history":[{"created":"2026-10-21T22:50:43.800083616Z","created_by":"ADD alpine-minirootfs-3.24.3-x86.tar.gz / # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2026-10-21T22:50:43.800083616Z","created_by":"CMD [\"/bin/sh\"]","comment":"buildkit.dockerfile.v0","empty_layer":true}],"os":"linux","rootfs":{"type":"layers","diff_ids":["sha256:7aae353e083a2c8243de8e9ae381729457f6e169cb4c82daa4f0fbdd204853b9"]}}
"""##,
        "sha256:d061e1b71a38d1deabc10789216a805e7830c4819af45d7452cf5dc4053f7e60": ##"""
{"architecture":"ppc64le","config":{"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"Cmd":["/bin/sh"],"WorkingDir":"/"},"created":"2026-10-22T02:45:14.421844469Z","history":[{"created":"2026-10-22T02:45:14.421844469Z","created_by":"ADD alpine-minirootfs-3.24.3-ppc64le.tar.gz / # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2026-10-22T02:45:14.421844469Z","created_by":"CMD [\"/bin/sh\"]","comment":"buildkit.dockerfile.v0","empty_layer":true}],"os":"linux","rootfs":{"type":"layers","diff_ids":["sha256:d809d295d31e005a10fcea04a6b5a11564643b105f9c76e568650d39c782d8b4"]}}
"""##,
        "sha256:e311ae748be7f56ae5cba304bc488f0786df68ee507513f654a5cc8597cffb42": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:f7bbaec1bd0330a8dba26f03e05f421bb3c8b807bb41873df3c3b0c3d1083d8f",
    "size": 627
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:d3531b7a4f217bdc3426c57bcff84c170f086f456a39689d4a615c6d026c4be0",
      "size": 4190488
    }
  ],
  "annotations": {
    "com.docker.official-images.bashbrew.arch": "arm64v8",
    "org.opencontainers.image.base.name": "scratch",
    "org.opencontainers.image.created": "2026-10-21T22:51:34Z",
    "org.opencontainers.image.revision": "5aec467fb81238bae9441eea2edb000655d7044f",
    "org.opencontainers.image.source": "https://github.com/alpinelinux/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:aarch64",
    "org.opencontainers.image.url": "https://hub.docker.com/_/alpine",
    "org.opencontainers.image.version": "3.24.3"
  }
}
"""##,
        "sha256:e355d80e026960b969d0e287d7900c15fa7195d29641e8ac173cc15db169be2a": ##"""
{"architecture":"arm","config":{"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"Cmd":["/bin/sh"],"WorkingDir":"/"},"created":"2026-10-21T22:58:59.125593593Z","history":[{"created":"2026-10-21T22:58:59.125593593Z","created_by":"ADD alpine-minirootfs-3.24.3-armhf.tar.gz / # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2026-10-21T22:58:59.125593593Z","created_by":"CMD [\"/bin/sh\"]","comment":"buildkit.dockerfile.v0","empty_layer":true}],"os":"linux","rootfs":{"type":"layers","diff_ids":["sha256:7177fdf62e02a8e0c72e90ed43bd9dc5e1303c7a41fb0caac39f57a623be2a15"]},"variant":"v6"}
"""##,
        "sha256:e56e90d77a05614cba94ec4c791282e108f3eac66d697781a79f9c0ccf2f6804": ##"""
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:0fa2aca5c15b9553f7f325fcdcc1264e0dca4e7d3f09d11b09d89bf88c7b6b85",
    "size": 610
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:2272b0c2085ed29d31c21595617f773cb42db2e52c3b366debca9d4689770412",
      "size": 3719710
    }
  ],
  "annotations": {
    "com.docker.official-images.bashbrew.arch": "s390x",
    "org.opencontainers.image.base.name": "scratch",
    "org.opencontainers.image.created": "2026-10-21T22:34:02Z",
    "org.opencontainers.image.revision": "5aec467fb81238bae9441eea2edb000655d7044f",
    "org.opencontainers.image.source": "https://github.com/alpinelinux/docker-alpine.git#5aec467fb81238bae9441eea2edb000655d7044f:s390x",
    "org.opencontainers.image.url": "https://hub.docker.com/_/alpine",
    "org.opencontainers.image.version": "3.24.3"
  }
}
"""##,
        "sha256:ebd888f836a2528406b0e39258543812b79eb1230e22d23d2d52ae4045dd2447": ##"""
{"architecture":"unknown","os":"unknown","config":{},"rootfs":{"type":"layers","diff_ids":["sha256:29747bda1d3c065ea62db09b8abbd76af03faea5b73430caf3a0868b1c4e54e3","sha256:33ac1b7ce393a09914f1bfc3479275e30a9172b69e5940094820414dc0605f2a"]}}
"""##,
        "sha256:f7bbaec1bd0330a8dba26f03e05f421bb3c8b807bb41873df3c3b0c3d1083d8f": ##"""
{"architecture":"arm64","config":{"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"Cmd":["/bin/sh"],"WorkingDir":"/"},"created":"2026-10-21T22:51:39.084385804Z","history":[{"created":"2026-10-21T22:51:39.084385804Z","created_by":"ADD alpine-minirootfs-3.24.3-aarch64.tar.gz / # buildkit","comment":"buildkit.dockerfile.v0"},{"created":"2026-10-21T22:51:39.084385804Z","created_by":"CMD [\"/bin/sh\"]","comment":"buildkit.dockerfile.v0","empty_layer":true}],"os":"linux","rootfs":{"type":"layers","diff_ids":["sha256:a278e6f39431cd0ed74238a3d377893ad0d905d68b676bf9a65529080669756b"]},"variant":"v8"}
"""##,
    ]
}
