import Foundation

// Recorded on this Mac with container 1.6.1 (builder shim 0.13.2, BuildKit 0.26.2), 5 Nov 2026.
enum BuildsFixtures {
    /// `container build --progress plain -t deck-v2-bld-ok:arm --build-arg GREETING=hey ok`
    static let buildOK = #"""
#1 [resolver] fetching image...docker.io/library/alpine:3.20
#1 DONE 0.0s

#2 [internal] load build definition from Dockerfile
#2 transferring dockerfile: 154B 0.0s done
#2 DONE 0.0s

#3 [internal] load .dockerignore
#3 transferring context: 2B done
#3 DONE 0.0s

#4 oci-layout://docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
#4 resolve docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc 0.1s done
#4 sha256:3f26bc2dec0b515f1c2818f6e13a8f1da1f88179a008445d4e587233386bff78 4.09MB / 4.09MB 0.0s done
#4 extracting sha256:3f26bc2dec0b515f1c2818f6e13a8f1da1f88179a008445d4e587233386bff78 0.0s done
#4 DONE 0.2s

#5 [linux/arm64 1/2] RUN echo "hey from $(uname -m)" > /greeting.txt
#5 DONE 0.1s

#6 exporting to oci image format
#6 exporting layers 0.0s done
#6 exporting manifest sha256:d0c9763cd9a1b09c66faedd1c3cb88d3aec2e08bcede7138d73b274d50dd2b97 done
#6 exporting config sha256:1095ed8c758b53f912e863f736eb0296d3921340fd741161ae57603ac7574bcf done
#6 exporting manifest list sha256:96f50bfaaf73b1a0cfe553f64af65a986e47cb9ea69d8ad91ad249751a854d22 done
#6 sending tarball 0.0s done
#6 DONE 0.0s
docker.io/library/deck-v2-bld-ok:arm
"""#

    /// A RUN step that exits 3.
    static let buildFailed = #"""
#1 [resolver] fetching image...docker.io/library/alpine:3.20
#1 DONE 0.0s

#2 [internal] load build definition from Dockerfile
#2 transferring dockerfile: 87B 0.0s done
#2 DONE 0.0s

#3 [internal] load .dockerignore
#3 transferring context: 2B done
#3 DONE 0.0s

#4 oci-layout://docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
#4 resolve docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc done
#4 CACHED

#5 [linux/arm64 1/2] RUN echo "about to fail" && exit 3
#5 0.037 about to fail
#5 ERROR: process "/bin/sh -c echo \"about to fail\" && exit 3" did not complete successfully: exit code: 3
------
 > [linux/arm64 1/2] RUN echo "about to fail" && exit 3:
0.037 about to fail
------
Error: unknown: "failed to solve: process "/bin/sh -c echo \"about to fail\" && exit 3" did not complete successfully: exit code: 3"
"""#

    /// `container builder status --format json`
    static let builderStatus = #"""
[{"configuration":{"capAdd":["ALL"],"capDrop":[],"creationDate":"2026-11-05T12:27:24Z","dns":{"nameservers":[],"options":[],"searchDomains":[]},"id":"buildkit","image":{"descriptor":{"digest":"sha256:ca27b4f564f2653207ef8f57ec7ba1653d11e7bbc51833503c243016ee65c2f8","mediaType":"application/vnd.oci.image.index.v1+json","size":856},"reference":"ghcr.io/apple/container-builder-shim/builder:0.13.2"},"initProcess":{"arguments":["--debug","--vsock"],"environment":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","BUILDKIT_SETUP_CGROUPV2_ROOT=1"],"executable":"/usr/local/bin/container-builder-shim","rlimits":[],"supplementalGroups":[],"terminal":false,"user":{"id":{"gid":0,"uid":0}},"workingDirectory":"/"},"labels":{"com.apple.container.plugin":"builder","com.apple.container.resource.role":"builder"},"mounts":[{"destination":"/run","options":[],"source":"","type":{"tmpfs":{}}},{"destination":"/var/lib/container-builder-shim/exports","options":[],"source":"/Users/suresh/Library/Application Support/com.apple.container/builder","type":{"virtiofs":{}}}],"networks":[{"network":"default","options":{"hostname":"buildkit"}}],"platform":{"architecture":"arm64","os":"linux","variant":"v8"},"publishedPorts":[],"publishedSockets":[],"readOnly":false,"resources":{"cpuOverhead":1,"cpus":2,"memoryInBytes":2147483648},"rosetta":true,"runtimeHandler":"container-runtime-linux","ssh":false,"sysctls":{},"useInit":false,"virtualization":false},"id":"buildkit","status":{"networks":[{"hostname":"buildkit","ipv4Address":"192.168.64.15/24","ipv4Gateway":"192.168.64.1","ipv6Address":"fd3a:ea47:104a:c220:fca6:6eff:fe1c:7298/64","macAddress":"fe:a6:6e:1c:72:98","network":"default","variant":"reserved"}],"startedDate":"2026-11-05T12:27:25Z","state":"running"}}]
"""#

    /// `container exec buildkit buildctl du --format '{{json .}}'`
    static let cacheUsage = #"""
[{"id":"thdpk5tyf2gvl6ibbvlhdphnj","mutable":true,"inUse":false,"size":4096,"createdAt":"2026-11-05T12:27:29.889632044Z","lastUsedAt":"2026-11-05T16:54:45.495027681Z","usageCount":7,"parents":null,"description":"local source for context","recordType":"source.local","shared":false},{"id":"fbwqh1msxe2a26xp509g9j06e","mutable":true,"inUse":false,"size":8192,"createdAt":"2026-11-05T12:27:29.858435502Z","lastUsedAt":"2026-11-05T16:54:45.494517181Z","usageCount":7,"parents":null,"description":"local source for dockerfile","recordType":"source.local","shared":false},{"id":"xunl3w4y7csiaivff41lrjj2b","mutable":false,"inUse":false,"size":12400,"createdAt":"2026-11-05T12:28:24.406031471Z","lastUsedAt":"2026-11-05T12:28:24.467376804Z","usageCount":1,"parents":["qouwujl38aijh03j8sbkfsjy7"],"description":"mount / from exec /bin/sh -c echo \"$GREETING\" > /greeting.txt","recordType":"regular","shared":false},{"id":"wkp4638b6tcngfi9n76c0xemf","mutable":false,"inUse":false,"size":12402,"createdAt":"2026-11-05T12:27:30.188615336Z","lastUsedAt":"2026-11-05T12:27:30.291877794Z","usageCount":1,"parents":["qouwujl38aijh03j8sbkfsjy7"],"description":"mount / from exec /bin/sh -c echo \"$GREETING\" > /greeting.txt","recordType":"regular","shared":false},{"id":"l9wlhu13bcwd20rvuhpt5f4iy","mutable":false,"inUse":false,"size":12413,"createdAt":"2026-11-05T16:54:27.834331964Z","lastUsedAt":"2026-11-05T16:54:27.899210589Z","usageCount":1,"parents":["mznqglg46afbqau0knw7ypkcc"],"description":"mount / from exec /bin/sh -c echo \"$GREETING from $(uname -m)\" > /greeting.txt","recordType":"regular","shared":false},{"id":"5fsuw5hmsb5tdmujlico52nuk","mutable":false,"inUse":false,"size":24771,"createdAt":"2026-11-05T16:54:34.169401259Z","lastUsedAt":"2026-11-05T16:54:34.213870842Z","usageCount":1,"parents":["beyi4g868veqyo79hhb654q9w"],"description":"mount / from exec /bin/sh -c echo \"$GREETING from $(uname -m)\" > /greeting.txt","recordType":"regular","shared":false},{"id":"beyi4g868veqyo79hhb654q9w","mutable":false,"inUse":false,"size":12100849,"createdAt":"2026-11-05T16:54:34.022524259Z","lastUsedAt":"2026-11-05T16:54:34.215016884Z","usageCount":1,"parents":null,"description":"pulled from docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc","recordType":"regular","shared":false},{"id":"qouwujl38aijh03j8sbkfsjy7","mutable":false,"inUse":false,"size":13500696,"createdAt":"2026-11-05T12:27:29.979850877Z","lastUsedAt":"2026-11-05T12:28:24.466426596Z","usageCount":3,"parents":null,"description":"pulled from docker.io/library/alpine:latest@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a","recordType":"regular","shared":false},{"id":"mznqglg46afbqau0knw7ypkcc","mutable":false,"inUse":false,"size":13578655,"createdAt":"2026-11-05T16:54:27.685990881Z","lastUsedAt":"2026-11-05T16:54:45.495282597Z","usageCount":3,"parents":null,"description":"pulled from docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc","recordType":"regular","shared":false}]
"""#
}
