import Foundation

/// Recorded from Docker Hub on 9 Nov 2026: `/v2/namespaces/mcp/repositories?page_size=100&ordering=pull_count`
/// (trimmed to five entries, one of them the `signatures` helper repository) and
/// `/v2/namespaces/mcp/repositories/markitdown`.
enum MCPCatalogFixtures {
    static let list = #"""
{
 "count": 245,
 "next": "https://hub.docker.com/v2/namespaces/mcp/repositories?ordering=pull_count&page=2&page_size=100",
 "previous": null,
 "results": [
  {"name": "signatures", "namespace": "mcp", "repository_type": "image", "status": 1, "status_description": "active",
   "description": "Repository containing cosign signatures for images in the mcp namespace", "is_private": false,
   "star_count": 11, "pull_count": 110762768, "last_updated": "2026-11-03T06:17:07.606196Z", "date_registered": "2025-05-01T09:30:37.214961Z"},
  {"name": "playwright", "namespace": "mcp", "repository_type": null, "status": 1, "status_description": "active",
   "description": "Playwright MCP server", "is_private": false,
   "star_count": 39, "pull_count": 2715289, "last_updated": "2026-06-26T07:39:31.811123Z", "date_registered": "2025-04-28T06:46:29.806693Z"},
  {"name": "fetch", "namespace": "mcp", "repository_type": null, "status": 1, "status_description": "active",
   "description": "Fetches a URL from the internet and extracts its contents as markdown", "is_private": false,
   "star_count": 58, "pull_count": 1978687, "last_updated": "2026-07-07T07:28:12.922484Z", "date_registered": "2024-12-19T20:20:08.490561Z"},
  {"name": "grafana", "namespace": "mcp", "repository_type": null, "status": 1, "status_description": "active",
   "description": "MCP server for Grafana", "is_private": false,
   "star_count": 22, "pull_count": 1164170, "last_updated": "2026-07-08T07:08:25.532745Z", "date_registered": "2025-04-16T09:30:23.443294Z"},
  {"name": "github", "namespace": "mcp", "repository_type": null, "status": 1, "status_description": "active",
   "description": "Tools for interacting with the GitHub API, enabling file operations, repository management, searc...", "is_private": false,
   "star_count": 20, "pull_count": 157593, "last_updated": "2025-06-16T19:22:33.231289Z", "date_registered": "2024-12-19T20:45:33.180595Z"}
 ]
}
"""#

    static let repository = #"""
{
 "user": "mcp",
 "name": "markitdown",
 "namespace": "mcp",
 "repository_type": null,
 "status": 1,
 "description": "A lightweight MCP server for calling MarkItDown.",
 "is_private": false,
 "star_count": 5,
 "pull_count": 169573,
 "last_updated": "2026-06-24T22:40:49.300866Z",
 "date_registered": "2025-08-25T06:18:42.644055Z"
}
"""#

    /// What Docker Hub sends past the first page without an account.
    static let refused = #"{"message":"pagination offset too large for anonymous requests; sign in to page further","errinfo":{}}"#
}
