import Foundation

/// Output and API answers recorded on 9 Nov 2026 for the Components checks (trimmed).
enum ComponentFixtures {
    // MARK: Installed versions (real command output on this Mac)

    static let containerVersion = "container CLI version 1.6.1 (build: release, commit: aa8d76b)\n"

    /// `ollama -v` from Homebrew. The warning goes to stderr, the runner joins both.
    static let ollamaVersion = """
    ollama version is 0.16.2
    2026/11/09 14:19:52 WARN MLX dynamic library not available error="failed to load MLX dynamic library (searched: [/opt/homebrew/Cellar/ollama/0.16.2/bin /Users/suresh/build/lib/ollama])"
    """

    /// `ollama -v` while an older server runs.
    static let ollamaClientWarning = """
    ollama version is 0.16.2
    Warning: client version is 0.17.0
    """

    static let ollamaAPIVersion = #"{"version":"0.16.2"}"#

    static let llmsterStatus = "llmster v0.0.27+1 is running (PID: 53383)\n"

    static let lmsDaemonHelp = """
    Usage: lms daemon [options] [command]

    Commands for managing the LM Studio daemon

    Commands:
       up                Manually start the llmster daemon
       down              Manually shutdown the llmster daemon
       status            Check the status of the LM Studio daemon
       update            Update the llmster daemon
    """

    static let lmsDaemonHelpOld = """
    Usage: lms daemon [options] [command]

    Commands:
       up                Manually start the llmster daemon
       down              Manually shutdown the llmster daemon
       status            Check the status of the LM Studio daemon
    """

    static let uvVersion = "uv 0.9.28 (Homebrew 2026-01-29)\n"

    static let uvToolList = """
    mlx-lm v0.32.2
    - mlx_lm
    - mlx_lm.server
    """

    static let cloudflaredVersion = "cloudflared version 2026.3.0 (built 2026-03-06T12:53:40Z)\n"

    static let kubectlJSON = """
    {
      "clientVersion": {
        "major": "1",
        "minor": "35",
        "gitVersion": "v1.35.0",
        "platform": "darwin/arm64"
      },
      "kustomizeVersion": "v5.7.1"
    }
    """

    static let kubectlText = "Client Version: v1.35.0\nKustomize Version: v5.7.1\n"

    static let helmShort = "v4.1.0+g4553a0a\n"

    static let tailscaleVersion = """
    1.104.5
      tailscale commit: 3c1a2f0e
      long version: 1.104.5-t3c1a2f0e
      go version: go1.25.6
    """

    static let ngrokVersion = "ngrok version 3.24.0\n"

    static let idGroups = "staff everyone localaccounts _appserverusr admin _appserveradm _lpadmin com.apple.sharepoint.group.1\n"
    static let idGroupsStandard = "staff everyone localaccounts _lpadmin\n"

    static let infoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>com.electron.ollama</string>
      <key>CFBundleShortVersionString</key><string>0.40.15</string>
    </dict></plist>
    """

    // MARK: Newest versions (real API answers, trimmed)

    /// `GET https://api.github.com/repos/apple/container/releases?per_page=30`, first three, .pkg assets only.
    static let containerReleases = """
    [
     {"tag_name": "1.7.1", "name": "1.7.1", "html_url": "https://github.com/apple/container/releases/tag/1.7.1", "prerelease": false, "draft": false,
      "assets": [
       {"name": "container-1.7.1-installer-signed.pkg", "browser_download_url": "https://github.com/apple/container/releases/download/1.7.1/container-1.7.1-installer-signed.pkg", "size": 169630704, "digest": "sha256:b6739caf3d47ca53a78f1a7edf32521420a75c7941838c3cefa75f30b80f5a97"},
       {"name": "container-installer-unsigned.pkg", "browser_download_url": "https://github.com/apple/container/releases/download/1.7.1/container-installer-unsigned.pkg", "size": 167209523, "digest": "sha256:e0ba7fbd4b779ee80bab768e0a3cf445c3eaaa104ec7103b0a4726612b7bad0e"}]},
     {"tag_name": "1.6.1", "name": "1.6.1", "html_url": "https://github.com/apple/container/releases/tag/1.6.1", "prerelease": false, "draft": false,
      "assets": [
       {"name": "container-1.6.1-installer-signed.pkg", "browser_download_url": "https://github.com/apple/container/releases/download/1.6.1/container-1.6.1-installer-signed.pkg", "size": 155965213, "digest": "sha256:cd47846819f06478d067060efe21e516b562ac0a9af8eecad6d5fea0b556b200"},
       {"name": "container-installer-unsigned.pkg", "browser_download_url": "https://github.com/apple/container/releases/download/1.6.1/container-installer-unsigned.pkg", "size": 152680743, "digest": "sha256:3aa1ff034fd40ef8da5a22a552693aa3a2d3c50f1b428f2e33f83838eaf2e062"}]},
     {"tag_name": "1.6.0", "name": "1.6.0", "html_url": "https://github.com/apple/container/releases/tag/1.6.0", "prerelease": false, "draft": false,
      "assets": [
       {"name": "container-1.6.0-installer-signed.pkg", "browser_download_url": "https://github.com/apple/container/releases/download/1.6.0/container-1.6.0-installer-signed.pkg", "size": 155879446, "digest": "sha256:a084d66df2fb573172d7f923fa83c9229d17f6c1ab61f09c8a90c43dab66ba02"}]}
    ]
    """

    /// The same list with a 1.6.2 patch added, to test picking a safe patch while 1.7 is out.
    static var containerReleasesWithPatch: String {
        containerReleases.replacingOccurrences(of: "[\n {\"tag_name\": \"1.7.1\"", with: """
        [
         {"tag_name": "1.6.2", "name": "1.6.2", "html_url": "https://github.com/apple/container/releases/tag/1.6.2", "prerelease": false, "draft": false,
          "assets": [{"name": "container-1.6.2-installer-signed.pkg", "browser_download_url": "https://github.com/apple/container/releases/download/1.6.2/container-1.6.2-installer-signed.pkg", "size": 156000000, "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"}]},
         {"tag_name": "1.8.0-beta.1", "name": "1.8.0 beta", "html_url": "https://github.com/apple/container/releases/tag/1.8.0-beta.1", "prerelease": true, "draft": false, "assets": []},
         {"tag_name": "1.7.1"
        """)
    }

    /// `GET https://api.github.com/repos/cloudflare/cloudflared/releases/latest` (one object, trimmed).
    static let cloudflaredLatest = """
    {"tag_name": "2026.10.7", "name": "2026.10.7", "html_url": "https://github.com/cloudflare/cloudflared/releases/tag/2026.10.7", "prerelease": false, "draft": false,
     "assets": [{"name": "cloudflared-darwin-arm64.tgz", "browser_download_url": "https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-darwin-arm64.tgz", "size": 19000000, "digest": null}]}
    """

    /// `GET https://pypi.org/pypi/mlx-lm/json` (trimmed). 0.31.0 is really yanked.
    static let pypiMLX = """
    {"info": {"name": "mlx-lm", "version": "0.32.2"},
     "releases": {
      "0.31.0": [{"filename": "mlx_lm-0.31.0-py3-none-any.whl", "yanked": true}],
      "0.32.1": [{"filename": "mlx_lm-0.32.1-py3-none-any.whl", "yanked": false}],
      "0.32.2": [{"filename": "mlx_lm-0.32.2-py3-none-any.whl", "yanked": false}],
      "0.33.0rc1": [{"filename": "mlx_lm-0.33.0rc1-py3-none-any.whl", "yanked": false}],
      "0.40.0": []
     }}
    """

    /// `GET https://formulae.brew.sh/api/formula/ollama.json` (trimmed).
    static let brewOllama = """
    {"name": "ollama", "full_name": "ollama", "versions": {"stable": "0.40.15", "head": "HEAD", "bottle": true}, "revision": 0, "homepage": "https://ollama.com/"}
    """

    /// `GET https://formulae.brew.sh/api/cask/lm-studio.json` (trimmed).
    static let caskLMStudio = """
    {"token": "lm-studio", "version": "0.4.28,2", "auto_updates": true, "homepage": "https://lmstudio.ai/"}
    """

    /// The top of https://lmstudio.ai/install.sh.
    static let lmStudioScript = """
    #!/bin/sh
    # shellcheck shell=dash
    #
    # Licensed under the MIT license
    has_local() {
        local _has_local
    }
    APP_NAME="llmster"
    APP_VERSION="0.0.27-1"
    """

    /// A registry 401 on `HEAD https://registry-1.docker.io/v2/mcp/fetch/manifests/latest`.
    static let dockerHubChallenge = #"Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:mcp/fetch:pull""#
    static let mcpFetchDigest = "sha256:1a7a0996a565a0b8ca5c41b42830d4e5f334d33f851596bbd9debb2beedb22d3"

    // MARK: AI agent tools (real output on this Mac, 9 Nov 2026)

    static let claudeVersion = "2.1.318 (Claude Code)\n"
    static let geminiVersion = "0.29.2\n"
    static let aiderVersion = "aider 0.86.1\n"
    static let claudeResolved = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
    static let geminiResolved = "/opt/homebrew/Cellar/gemini-cli/0.29.2/libexec/lib/node_modules/@google/gemini-cli/dist/index.js"

    /// `GET https://registry.npmjs.org/@anthropic-ai/claude-code/latest` (trimmed).
    static let npmClaude = """
    {"name":"@anthropic-ai/claude-code","version":"2.1.319","bin":{"claude":"bin/claude.exe"},"dist":{"tarball":"https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-2.1.319.tgz"}}
    """

    /// `GET https://registry.npmjs.org/@sourcegraph/amp/latest` (trimmed): a git mark, not a pre-release.
    static let npmAmp = #"{"name":"@sourcegraph/amp","version":"0.0.1794196844-g44d37b"}"#

    /// The top of the apple/container 1.7.1 release notes.
    static let containerNotes = """
    ## Highlights

    ⌨️ denotes breaking CLI changes.

    👩‍💻 denotes breaking API changes.

    - Core
      - [`container stats` now reports `cpuUtilization` in JSON, YAML, and TOML output](https://github.com/apple/container/pull/2146)
      - [Image snapshots and container filesystems are now excluded from Time Machine backups](https://github.com/apple/container/pull/2412)
      - [Default Kata kernel is now 4.3.1 (`vmlinux-6.18.56-208-debug`)](https://github.com/apple/container/pull/2447)
    - Kubernetes
      - ⌨️ [New `--shared-image-store` option on `container cluster run` to use the `container` image store from cluster nodes; removed the `load-image` subcommand](https://github.com/apple/container/pull/2437)

    **Full Changelog**: https://github.com/apple/container/compare/1.6.1...1.7.1
    """
}
