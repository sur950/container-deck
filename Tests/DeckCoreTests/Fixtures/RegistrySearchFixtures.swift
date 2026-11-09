import Foundation

// Saved from real public answers on 9 Nov 2026 (trimmed). No credentials anywhere.
enum RegistrySearchFixtures {
    /// GET https://quay.io/api/v1/find/repositories?query=prometheus&page=1 (first 3 results,
    /// the long README cut after its first sections).
    static let quayFind = #"""
{"results": [{"kind": "repository", "title": "repo", "namespace": {"title": "org", "kind": "organization", "avatar": {"name": "prometheus-operator", "hash": "58c1e6ac82946ee608a7f6ee13cb1ca7", "color": "#9ecae1", "kind": "org"}, "name": "prometheus-operator", "score": 1, "href": "/organization/prometheus-operator"}, "name": "prometheus-config-reloader", "description": null, "is_public": true, "score": 4, "href": "/repository/prometheus-operator/prometheus-config-reloader"}, {"kind": "repository", "title": "repo", "namespace": {"title": "org", "kind": "organization", "avatar": {"name": "prometheus", "hash": "bafb38046c5a2fa14be157412d2ceaf4", "color": "#b5cf6b", "kind": "org"}, "name": "prometheus", "score": 1, "href": "/organization/prometheus"}, "name": "prometheus", "description": "<h1 align=\"center\" style=\"border-bottom: none\">\n    <a href=\"https://prometheus.io\" target=\"_blank\"><img alt=\"Prometheus\" src=\"/documentation/images/prometheus-logo.svg\"></a><br>Prometheus\n</h1>\n\n<p align=\"center\">Visit <a href=\"https://prometheus.io\" target=\"_blank\">prometheus.io</a> for the full documentation,\nexamples and guides.</p>\n\n<div align=\"center\">\n\n[![CI](https://github.com/prometheus/prometheus/actions/workflows/ci.yml/badge.svg)](https://github.com/prometheus/prometheus/actions/workflows/ci.yml)\n[![Docker Repository on Quay](https://quay.io/repository/prometheus/prometheus/status)][quay]\n[![Docker Pulls](https://img.shields.io/docker/pulls/prom/prometheus.svg?maxAge=604800)][hub]\n[![CII Best Practices](https://bestpractices.coreinfrastructure.org/projects/486/badge)](https://bestpractices.coreinfrastructure.org/projects/486)\n[![govulncheck](https://github.com/prometheus/prometheus/actions/workflows/govulncheck.yml/badge.svg?event=schedule)](https://github.com/prometheus/prometheus/actions/workflows/govulncheck.yml)\n[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/prometheus/prometheus/badge)](https://securityscorecards.dev/viewer/?uri=github.com/prometheus/prometheus)\n[![CLOMonitor](https://img.shields.io/endpoint?url=https://clomonitor.io/api/projects/cncf/prometheus/badge)](https://clomonitor.io/projects/cncf/prometheus)\n[![Fuzzing Status](https://oss-fuzz-build-logs.storage.googleapis.com/badges/prometheus.svg)](https://bugs.chromium.org/p/oss-fuzz/issues/list?sort=-opened&can=1&q=proj:prometheus)\n\n</div>\n\nPrometheus, a [Cloud Native Computing Foundation](https://cncf.io/) project, is a systems and service monitoring system. It collects metrics\nfrom configured targets at given intervals, evaluates rule expressions,\ndisplays the results, and can trigger alerts when specified conditions are observed.\n\nThe features that distinguish Prometheus from other metrics and monitoring systems are:\n\n* A **multi-dimensional** data model (time series defined by metric name and set of key/value dimensions)\n* PromQL, a **powerful and flexible query language** to leverage this dimensionality\n* No dependency on distributed storage; **single server nodes are autonomous**\n* An HTTP **pull model** for time series collection\n* **Pushing time series** is supported via an intermediary gateway for batch jobs\n* Targets are discovered via **service discovery** or **static configuration**\n* Multiple modes of **graphing and dashboarding support**\n* Support for hierarchical and horizontal **federation**", "is_public": true, "score": 4, "href": "/repository/prometheus/prometheus"}, {"kind": "repository", "title": "repo", "namespace": {"title": "org", "kind": "organization", "avatar": {"name": "prometheus-operator", "hash": "58c1e6ac82946ee608a7f6ee13cb1ca7", "color": "#9ecae1", "kind": "org"}, "name": "prometheus-operator", "score": 1, "href": "/organization/prometheus-operator"}, "name": "prometheus-operator", "description": null, "is_public": true, "score": 4, "href": "/repository/prometheus-operator/prometheus-operator"}], "has_additional": true, "page": 1, "page_size": 10, "start_index": 0}
"""#

    /// GET https://quay.io/api/v1/repository/prometheus/node-exporter/tag/?limit=3&page=1&onlyActiveTags=true
    static let quayTags = #"""
{"tags": [{"name": "master-distroless", "reversion": false, "start_ts": 1792863085, "manifest_digest": "sha256:2aeca551ca3cb8c90f11fee9bcdf9859725c48f272d478aa79b9bbc48eda13ed", "is_manifest_list": true, "size": null, "last_modified": "Sat, 24 Oct 2026 17:31:25 -0000", "is_sparse": false, "child_manifest_count": 6, "present_child_count": 6}, {"name": "master", "reversion": false, "start_ts": 1792862962, "manifest_digest": "sha256:60717af57d790f02db92fdaad1175c86820e5e44ad4e35bfce543fd125b0da43", "is_manifest_list": true, "size": null, "last_modified": "Sat, 24 Oct 2026 17:29:22 -0000", "is_sparse": false, "child_manifest_count": 6, "present_child_count": 6}, {"name": "master-busybox", "reversion": false, "start_ts": 1792862926, "manifest_digest": "sha256:60717af57d790f02db92fdaad1175c86820e5e44ad4e35bfce543fd125b0da43", "is_manifest_list": true, "size": null, "last_modified": "Sat, 24 Oct 2026 17:28:46 -0000", "is_sparse": false, "child_manifest_count": 6, "present_child_count": 6}], "page": 1, "has_additional": true}
"""#

    /// GET https://demo.goharbor.io/api/v2.0/search?q=nginx (first 3 repositories).
    static let harborSearch = #"""
{"project": [], "repository": [{"artifact_count": 1, "project_id": 8779, "project_name": "test-2244", "project_public": true, "pull_count": 209, "repository_name": "test-2244/nginx"}, {"artifact_count": 54, "project_id": 8154, "project_name": "frzdoc", "project_public": true, "pull_count": 20138, "repository_name": "frzdoc/library/nginx"}, {"artifact_count": 3, "project_id": 8086, "project_name": "frz", "project_public": true, "pull_count": 536, "repository_name": "frz/nginx"}]}
"""#

    /// GET https://ghcr.io/v2/astral-sh/uv/tags/list?n=5 with an anonymous token.
    /// Link: </v2/astral-sh/uv/tags/list?last=0.1.39&n=5>; rel="next"
    static let ghcrTags = #"""
{"name":"astral-sh/uv","tags":["initial","latest","0.1.37","0.1.38","0.1.39"]}
"""#

    /// The 401 ghcr.io sends without a token.
    static let ghcrChallenge = #"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:astral-sh/uv:pull""#

    /// The 401 Docker Hub sends for the catalog.
    static let hubCatalogChallenge = #"Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="registry:catalog:*""#

    /// GET https://hub.docker.com/v2/search/repositories/?query=prometheus (trimmed to 2).
    static let hubSearch = #"""
{"count":2,"next":null,"previous":null,"results":[
 {"repo_name":"prom/prometheus","short_description":"","star_count":1000,"pull_count":1000000000,"repo_owner":"","is_automated":false,"is_official":false},
 {"repo_name":"bitnami/prometheus","short_description":"Bitnami container image for Prometheus","star_count":200,"pull_count":50000000,"repo_owner":"","is_automated":false,"is_official":false}
]}
"""#

    /// The shape GitHub documents for GET /user/packages?package_type=container.
    /// Made up names, no real account.
    static let githubPackages = #"""
[
 {"id":197,"name":"hello_docker","package_type":"container","owner":{"login":"monalisa","id":9919,"type":"User"},"version_count":3,"visibility":"private","url":"https://api.github.com/users/monalisa/packages/container/hello_docker","created_at":"2020-05-19T22:19:11Z","updated_at":"2020-05-19T22:19:11Z","html_url":"https://github.com/users/monalisa/packages/container/package/hello_docker"},
 {"id":198,"name":"Tools/Prometheus-Exporter","package_type":"container","owner":{"login":"MonaLisa","id":9919,"type":"User"},"version_count":1,"visibility":"public","html_url":"https://github.com/users/monalisa/packages/container/package/tools%2Fprometheus-exporter"},
 {"id":199,"name":"left-pad","package_type":"npm","owner":{"login":"monalisa"},"version_count":9,"visibility":"public"}
]
"""#

    static let githubOrgs = #"""
[{"login":"octo-org","id":1,"url":"https://api.github.com/orgs/octo-org"}]
"""#

    static let githubOrgPackages = #"""
[{"id":300,"name":"prometheus-agent","package_type":"container","owner":{"login":"octo-org","type":"Organization"},"version_count":12,"visibility":"internal","html_url":"https://github.com/orgs/octo-org/packages/container/package/prometheus-agent"}]
"""#
}
