# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Check for Updates shows its result when clicked while the automatic check is still running, instead of doing nothing. The menu item stays available during a check.
- A Kubernetes port forward that fails right away now always shows kubectl's own error, instead of sometimes only "kubectl stopped".
- Installing the Linux kernel in Setup works on flaky networks. The app downloads the kernel itself, resumes after a dropped connection, retries, checks the file's SHA-256 and fetches a damaged copy once more before installing it with `container system kernel set`. Setup shows MB done, speed and Cancel, and a plain message with Try Again and Details when the download is damaged (often by a VPN or proxy) or the Mac is offline. Before, a single bad byte ended in "kernel archive digest mismatch".

## [1.1.1] - 2026-11-06

### Fixed

- The main window opens at its minimum size right away, without opening large first.
- The notification prompt appears on first launch. The app now follows macOS's own record of whether it was asked.
- The sidebar button no longer keeps a focus ring after showing or hiding the sidebar.
- LM Studio installs on Macs that cannot open its disk image. "Install LM Studio core" uses LM Studio's own installer, which adds the `lms` command and the background service, and Start Server brings the service up first. A failed Homebrew install now explains this and offers the core install.
- MLX models that mlx-lm cannot load (for example model type `qwen3_5_mtp`) show a plain message in the MLX tab and in chat, instead of "generation thread died". The Model Library marks such models before you use them.
- The MLX server starts on 127.0.0.1 when the container network address is not on this Mac, instead of failing with "Can't assign requested address".
- Model names show as short names in chat and pickers, not full file paths.
- AI servers are checked by one shared probe instead of several.

## [1.1.0] - 2026-11-06

### Added

- **Agents:** each agent opens into Overview, MCP Servers (connect and disconnect with preview and Undo), Running sessions (folder, CPU, memory, Open Terminal, Stop) and Recent sessions with Resume for Claude Code and Codex. Saved agent profiles combine the tool, a model, MCP servers and a folder, and launch on this Mac or inside a sandbox, where the agent CLI is installed on first run and keys are passed by name only.
- **Settings, Agents:** program, config file and sessions folder for each agent, found automatically (including CLAUDE_CONFIG_DIR, CODEX_HOME and GEMINI_CLI_HOME) and editable.
- **MCP Catalog:** Featured and Browse. Browse searches the official MCP Registry and Docker's MCP catalog with filters and pages, and installs npm and PyPI servers inside containers, images as they are, and remote servers by URL.
- **LM Studio:** a new tab to install it, start and stop its server, and load and unload models.
- **Chat:** a new chat design for AI Models and Sandboxes with Markdown, tables, code blocks with Copy, a Thoughts section, Stop and a growing message box. Conversations are kept in container volumes, survive switching screens and relaunching, and can be turned off.
- **Model Library:** sort by every column, using real sizes, bits, parameters, downloads and dates.
- **Notifications:** a clear way to allow them in Settings and the setup guide, and every event now goes to Notification Center.
- **Import:** a folding section per engine with selected counts, search, and engine cards that show one engine.

### Changed

- The main window opens at its minimum size, centered.
- Sidebar sections fold with a clear arrow and a clickable row.
- Settings, Platform shows the connection as a short value with the details below it.
- About counts installer downloads only.
- The DNS tab in Settings is gone, the Domains screen covers it.
- The website is now a hand-built page published from `website/`, and the README is a short project page.

### Fixed

- macOS no longer asks for permission on every launch of a downloaded copy. The app removes the quarantine flag after the first approved launch and offers to move itself to Applications when started from the disk image or Downloads.
- The installer package gives the app to the logged in user, so it can update itself.
- The disk image is APFS, so it opens on macOS 27.
- Kubernetes cluster names must be lowercase. Names with capital letters made worker nodes time out.
- The MLX runtime install waits up to 5 minutes per download on slow networks.
- New Sandbox no longer lists Ollama twice.
- Import rows follow the current image list, so images deleted later can be imported again.
- The Model Library detail pane no longer shows a model that is not in the results.

## [1.0.0] - 2026-11-06

First public release. Requires macOS 15 or later on Apple silicon. Tested with Apple's `container` 1.6.1.

### Added

- **Containers:** list, start, stop, kill, restart, delete and prune, with live CPU, memory, network and disk stats. Detail view with Overview, Logs, Stats, Mounts, Inspect, Files and a terminal. Run sheet with Docker Hub search and a command preview. Edit and Recreate keeps the old container until the new one runs. Bulk actions, group by Compose project or label, export to tar, commit to an image, start with the app.
- **Direct connection** to Apple's container service over XPC for lists, stats, lifecycle, logs, images, volumes and networks, with the `container` CLI as automatic fallback. Settings, Platform shows which path is in use and has a "command line only" switch.
- **Images:** pull with progress, build, tag, save, load, push, delete and prune, layers and the containers that use each image. Registry sign in from Settings.
- **Compose:** open a `compose.yaml` and run the stack, with healthchecks, profiles, `depends_on` conditions, `post_start` and `pre_stop` hooks, per service logs and re-up of only what changed. Several `-f` files with Docker merge rules, override files, `COMPOSE_FILE`, `!reset` and `!override`, `include` and `extends`. A Problems tab points to the file and line. The `container compose` command (installed from the Compose screen) runs the same engine in Terminal. See "Coming from Docker Compose" in docs/COMPOSE.md.
- **Builds:** history across restarts, live BuildKit logs, several builds at once, stop and rebuild, builder start and stop, build cache size and clean up.
- **Machines:** create, start, stop and edit Linux VMs, with live stats, kernel and account options.
- **Kubernetes:** local clusters on the experimental `container cluster` plugin, with nodes, kubeconfig, workloads, live pod logs, restarts and port forwards. Cluster networking is repaired automatically after a stop and start.
- **Volumes and networks:** create, browse, inspect and clean up, including host only networks.
- **Domains:** HTTPS for `https://<container>.localhost` through a built in proxy with its own certificate authority, aliases, reach this Mac by name, and sharing a route to the internet through Cloudflare Tunnel, ngrok or Tailscale Funnel.
- **AI Models:** finds Ollama, LM Studio and MLX servers, installs the MLX runtime, downloads models from Hugging Face with resume, and has a chat tester.
- **Sandboxes:** isolated containers for AI agents with a workspace folder, CPU and memory limits, an allow list of sites, model access through a relay and a kill switch.
- **Agents and MCP:** shows every MCP server already set up on the Mac, runs MCP servers as containers, and connects them to Claude Code, Claude Desktop, Cursor, VS Code, Codex and Gemini with a preview, a backup and Undo. API keys live in the Keychain.
- **Import** from Docker Desktop, OrbStack, Rancher Desktop, Podman and Colima, even while those apps are stopped.
- **Dashboard** with stats history from 5 minutes to 24 hours, network and disk charts, disk use and Free Up Space. A multi pane Logs window.
- **Everywhere:** command palette with verbs, menu bar panel with usage rings, deep links (`containerdeck://`), notifications, open at login, setup guide, Diagnostics, Light and Dark appearance.
- **Updates:** the app checks GitHub Releases and installs updates itself after checking the SHA-256 checksum, the Ed25519 signature, the bundle id and the signing certificate.
- **Install** with the installer package (one `curl` command) or the disk image from GitHub Releases.
- **Docker habits:** a `docker` compatibility command and shell aliases, described in docs/DOCKER.md.

[1.1.1]: https://github.com/sur950/container-deck/releases/tag/v1.1.1
[1.1.0]: https://github.com/sur950/container-deck/releases/tag/v1.1.0
[1.0.0]: https://github.com/sur950/container-deck/releases/tag/v1.0.0
