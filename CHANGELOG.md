# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

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

[1.0.0]: https://github.com/sur950/container-deck/releases/tag/v1.0.0
