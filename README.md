<p align="center">
  <a href="https://sur950.github.io/container-deck/">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/brand/lockup-dark.png">
      <img src="assets/brand/lockup-light.png" alt="Container Deck" width="360">
    </picture>
  </a>
</p>

<h3 align="center">The native Mac app for Apple's container platform.</h3>

<p align="center">Run, build and manage Linux containers on Apple silicon. Compose, Kubernetes, local AI, MCP servers and HTTPS domains in one SwiftUI app. Free, no account.</p>

<p align="center">
  <a href="https://github.com/sur950/container-deck/releases/latest"><img src="https://img.shields.io/github/v/release/sur950/container-deck?color=B3122E&label=release" alt="Latest release"></a>
  <a href="https://github.com/sur950/container-deck/releases"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fsur950.github.io%2Fcontainer-deck%2Fbadges%2Fdownloads.json" alt="Downloads"></a>
  <a href="https://github.com/sur950/container-deck/stargazers"><img src="https://img.shields.io/github/stars/sur950/container-deck?color=B3122E&logo=github" alt="GitHub stars"></a>
  <a href="https://github.com/sur950/container-deck/actions/workflows/ci.yml"><img src="https://github.com/sur950/container-deck/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-111215?logo=apple&logoColor=white" alt="macOS 15 or later">
</p>

<p align="center">
  <a href="https://sur950.github.io/container-deck/"><strong>Website</strong></a>
  &middot; <a href="https://github.com/sur950/container-deck/releases/latest">Download</a>
  &middot; <a href="#documentation">Docs</a>
  &middot; <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dashboard-dark.png">
    <img src="docs/screenshots/dashboard-light.png" alt="The Container Deck dashboard with running containers, activity charts and disk usage" width="920">
  </picture>
</p>

## Install

Requires macOS 15 or later on Apple silicon. If Apple's [`container`](https://github.com/apple/container) platform is not installed yet, the app sets it up on first launch.

**Terminal (recommended).** Works on any account, including managed Macs, with no admin password and no security prompt. It installs into Applications, or into Applications in your home folder when you can't write to the main one:

```bash
curl -fsSL https://github.com/sur950/container-deck/releases/latest/download/ContainerDeck.dmg -o /tmp/ContainerDeck.dmg && hdiutil attach -nobrowse -mountpoint /tmp/ContainerDeck /tmp/ContainerDeck.dmg >/dev/null && D=/Applications && { [ -w "$D" ] || { D="$HOME/Applications"; mkdir -p "$D"; }; } && rm -rf "$D/Container Deck.app" && ditto "/tmp/ContainerDeck/Container Deck.app" "$D/Container Deck.app" && hdiutil detach /tmp/ContainerDeck >/dev/null && rm -f /tmp/ContainerDeck.dmg && open "$D/Container Deck.app"
```

**Download (personal Macs).** Get the [disk image](https://github.com/sur950/container-deck/releases/latest/download/ContainerDeck.dmg) or the [installer package](https://github.com/sur950/container-deck/releases/latest/download/ContainerDeck.pkg) from the [latest release](https://github.com/sur950/container-deck/releases/latest). Releases are signed but not notarized by Apple, so the first time you open the app, click **Done**, then go to **System Settings > Privacy & Security** and click **Open Anyway**. The app does not ask again after that.

**Mac managed by your company or school?** Device management profiles often allow only App Store apps or turn off Open Anyway, so a downloaded disk image or package cannot be opened. Use the Terminal command above. Files fetched with `curl` are not marked as downloads.

Every release ships `.sha256` checksums, and the app installs its own updates after checking their Ed25519 signature.

## Features

- **Containers and images.** Lifecycle, live stats, logs, files, a terminal, Edit and Recreate, image pull, build, tag, save and push, and image search across Docker Hub, Quay and your registries.
- **Compose.** Run `compose.yaml` stacks with healthchecks, profiles, `depends_on` conditions, hooks, several `-f` files, `include` and `extends`, plus a `container compose` command for Terminal. See [Coming from Docker Compose](docs/COMPOSE.md#coming-from-docker-compose).
- **Builds, machines and Kubernetes.** Build history with live logs, Linux VMs, and local clusters on `container cluster`.
- **AI.** Run Ollama, LM Studio and MLX, explore and download their models from one library, clean up unused models, chat with them, and run agents in isolated sandboxes.
- **Agents and MCP.** Search the MCP Registry and Docker's MCP catalog, run MCP servers in containers, connect them to Claude Code, Cursor, VS Code, Codex and Gemini, and manage agent sessions and profiles.
- **Domains.** HTTPS for `https://<container>.localhost`, aliases, and sharing through Cloudflare Tunnel, ngrok or Tailscale Funnel.
- **Move in.** Import images from Docker Desktop, OrbStack, Rancher Desktop, Podman and Colima, and keep your habits with the [`docker` compatibility command](docs/DOCKER.md).
- **Everywhere.** Command palette, menu bar panel, notifications, deep links, Light and Dark, and updates for Apple container and every tool the app uses.

Container Deck talks to Apple's container service directly over XPC for the frequent calls, and uses the `container` CLI for everything else and as the automatic fallback. It has no server, account or tracking.

## Documentation

- [Coming from Docker Compose](docs/COMPOSE.md): what works, partly works or does not.
- [Docker commands](docs/DOCKER.md): the compatibility command and shell aliases.
- [Domains and sharing](docs/DOMAINS.md): local names, the HTTPS proxy and public sharing.
- [Architecture](docs/ARCHITECTURE.md): how the app is built.
- [Development](docs/DEVELOPMENT.md): building, running and testing from source.

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

Free for personal and commercial use, and you may read, change and share the code. You may not sell it, or sell a product or service that is mainly Container Deck. [Apache License 2.0 with the Commons Clause](LICENSE).

Built on [Apple container](https://github.com/apple/container) and [Yams](https://github.com/jpsim/Yams).

<p align="center">
  <br>
  <img src="assets/brand/app-icon-1024.png" alt="" width="40" height="40">
  <br>
  <sub>Made by <a href="https://suresh-konakanchi.in">Suresh Konakanchi</a>. Container Deck is an independent project, not made by, affiliated with, or endorsed by Apple.</sub>
</p>
