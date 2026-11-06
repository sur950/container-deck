import Foundation

/// Recorded from the live MCP Registry (v0.1/servers?search=…&version=latest, 6 Nov 2026) and
/// Docker Hub (/v2/repositories/mcp/?name=git), trimmed to a few entries.
enum MCPRegistryFixtures {
    static let registryPage = #"""
{
 "servers": [
  {
   "server": {
    "$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
    "name": "com.githubcard/mcp",
    "description": "Create GitHub profile and repository cards for READMEs, link previews and social posts.",
    "title": "GitHubCard",
    "repository": {
     "url": "https://github.com/ghcardhq/githubcard-mcp",
     "source": "github"
    },
    "version": "0.2.1",
    "websiteUrl": "https://githubcard.com",
    "packages": [
     {
      "registryType": "npm",
      "identifier": "@ghcardhq/ghcard",
      "version": "0.2.1",
      "runtimeHint": "npx",
      "transport": {
       "type": "stdio"
      },
      "packageArguments": [
       {
        "type": "positional",
        "value": "mcp"
       }
      ],
      "environmentVariables": [
       {
        "description": "API key from https://githubcard.com/dashboard. Needed to cre",
        "isSecret": true,
        "placeholder": "ghc_live_…",
        "name": "GHCARD_API_KEY"
       }
      ]
     }
    ],
    "remotes": [
     {
      "type": "streamable-http",
      "url": "https://githubcard.com/mcp",
      "headers": [
       {
        "description": "\"Bearer \" followed by an API key from https://githubcard.com/dashboard. Needed to create cards; templates, palettes and components work without it.",
        "isSecret": true,
        "placeholder": "Bearer ghc_live_…",
        "name": "Authorization"
       }
      ]
     }
    ]
   },
   "_meta": {
    "io.modelcontextprotocol.registry/official": {
     "status": "active",
     "statusChangedAt": "2026-11-01T12:36:40.709019Z",
     "publishedAt": "2026-11-01T12:36:40.709019Z",
     "updatedAt": "2026-11-01T12:36:40.709019Z",
     "isLatest": true
    }
   }
  },
  {
   "server": {
    "$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
    "name": "com.mcparmory/github",
    "description": "Manage repositories, users, releases, and automate GitHub workflows",
    "repository": {
     "url": "https://github.com/mcparmory/registry",
     "source": "github"
    },
    "version": "1.0.6",
    "packages": [
     {
      "registryType": "pypi",
      "identifier": "mcparmory-github",
      "version": "1.0.6",
      "runtimeHint": "uvx",
      "transport": {
       "type": "stdio"
      }
     },
     {
      "registryType": "oci",
      "identifier": "ghcr.io/mcparmory/github:1.0.6",
      "runtimeHint": "docker",
      "transport": {
       "type": "stdio"
      }
     }
    ]
   },
   "_meta": {
    "io.modelcontextprotocol.registry/official": {
     "status": "active",
     "statusChangedAt": "2026-05-11T21:37:47.993849Z",
     "publishedAt": "2026-05-11T21:37:47.993849Z",
     "updatedAt": "2026-05-11T21:37:47.993849Z",
     "isLatest": true
    }
   }
  },
  {
   "server": {
    "$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
    "name": "com.usegithubthing/ugt",
    "description": "Get open-source GitHub projects running on your computer, with your AI app",
    "title": "UGT: Use the GitHub Thing",
    "repository": {
     "url": "https://github.com/auscaster/ugt",
     "source": "github"
    },
    "version": "0.3.0",
    "websiteUrl": "https://usegithubthing.com",
    "packages": [
     {
      "registryType": "mcpb",
      "identifier": "https://github.com/auscaster/ugt/releases/download/v0.3.0/ugt-mcp-darwin-arm64.mcpb",
      "version": "0.3.0",
      "fileSha256": "cc958134e143204daf51bb5afd5284d075fcd37e6c2efbfadddd9c0a4fb0eab9",
      "transport": {
       "type": "stdio"
      }
     }
    ]
   },
   "_meta": {
    "io.modelcontextprotocol.registry/official": {
     "status": "active",
     "statusChangedAt": "2026-11-05T09:23:58.979436Z",
     "publishedAt": "2026-11-05T09:23:58.979436Z",
     "updatedAt": "2026-11-05T09:23:58.979436Z",
     "isLatest": true
    }
   }
  },
  {
   "server": {
    "$schema": "https://static.modelcontextprotocol.io/schemas/2025-09-29/server.schema.json",
    "name": "ai.waystation/postgres",
    "description": "Connect to your PostgreSQL database to query data and schemas.",
    "repository": {
     "url": "https://github.com/waystation-ai/mcp",
     "source": "github"
    },
    "version": "0.3.1",
    "remotes": [
     {
      "type": "streamable-http",
      "url": "https://waystation.ai/postgres/mcp"
     },
     {
      "type": "sse",
      "url": "https://waystation.ai/postgres/mcp/sse"
     }
    ]
   },
   "_meta": {
    "io.modelcontextprotocol.registry/official": {
     "status": "active",
     "statusChangedAt": "2025-09-09T14:46:09.489652Z",
     "publishedAt": "2025-09-09T14:46:09.489652Z",
     "updatedAt": "2025-09-09T14:46:09.489652Z",
     "isLatest": true
    }
   }
  },
  {
   "server": {
    "$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
    "name": "io.github.Eszetael/postgres-mcp-hardened",
    "description": "Read-only PostgreSQL over MCP. Writes refused at the parsed SQL, plus a READ ONLY transaction.",
    "title": "PostgreSQL (hardened, read-only)",
    "repository": {
     "url": "https://github.com/Eszetael/postgres-mcp-hardened",
     "source": "github"
    },
    "version": "0.1.10",
    "websiteUrl": "https://github.com/Eszetael/postgres-mcp-hardened",
    "packages": [
     {
      "registryType": "npm",
      "identifier": "postgres-mcp-hardened",
      "version": "0.1.10",
      "runtimeHint": "npx",
      "transport": {
       "type": "stdio"
      },
      "runtimeArguments": [
       {
        "isRequired": true,
        "type": "positional",
        "value": "--stdio"
       }
      ],
      "environmentVariables": [
       {
        "description": "Connection string for the role the server connects as. Use a",
        "isRequired": true,
        "isSecret": true,
        "name": "DATABASE_URL"
       },
       {
        "description": "Server-side statement timeout, e.g. `5s`. A question that wo",
        "name": "MCP_STATEMENT_TIMEOUT"
       }
      ]
     },
     {
      "registryType": "oci",
      "identifier": "ghcr.io/eszetael/postgres-mcp-hardened:0.1.10",
      "transport": {
       "type": "streamable-http",
       "url": "http://localhost:8080/mcp"
      },
      "environmentVariables": [
       {
        "description": "Connection string for a role that cannot write.",
        "isRequired": true,
        "isSecret": true,
        "name": "DATABASE_URL"
       },
       {
        "description": "Address to bind, default 127.0.0.1:8080.",
        "name": "MCP_ADDR"
       }
      ]
     }
    ]
   },
   "_meta": {
    "io.modelcontextprotocol.registry/official": {
     "status": "active",
     "statusChangedAt": "2026-09-04T23:18:25.068686Z",
     "publishedAt": "2026-09-04T23:18:25.068686Z",
     "updatedAt": "2026-09-04T23:18:25.068686Z",
     "isLatest": true
    }
   }
  }
 ],
 "metadata": {
  "nextCursor": "io.github.edelciomolina/postgres-mcp:1.7.0",
  "count": 5
 }
}
"""#

    static let dockerPage = #"""
{
 "count": 4,
 "next": "https://hub.docker.com/v2/repositories/mcp/?name=git&ordering=pull_count&page=2&page_size=2",
 "previous": null,
 "results": [
  {
   "name": "git",
   "namespace": "mcp",
   "description": "Git repository interaction and automation.",
   "is_private": false,
   "star_count": 30,
   "pull_count": 190840,
   "last_updated": "2025-06-16T19:22:35.133934Z"
  },
  {
   "name": "github",
   "namespace": "mcp",
   "description": "Tools for interacting with the GitHub API, enabling file operations, repository management, searc...",
   "is_private": false,
   "star_count": 20,
   "pull_count": 156946,
   "last_updated": "2025-06-16T19:22:33.231289Z"
  }
 ]
}
"""#
}
