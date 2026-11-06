# Contributing to Container Deck

Thank you for your interest in Container Deck. This guide explains how to set up the project, the conventions the code follows, and how to get a change merged.

## Ground rules

- Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
- Security issues are reported privately, never in a public issue. See [SECURITY.md](SECURITY.md).
- Larger changes start with an issue, so we can agree on the approach before you write the code.

## Setup

You need an Apple silicon Mac with macOS 15 or later and Xcode 16 or later. Apple's [`container`](https://github.com/apple/container) CLI is needed only to run the app against real containers and for the live tests.

### 1. Fork and clone

Work happens in your own fork, and changes come back through a pull request.

1. Open [sur950/container-deck](https://github.com/sur950/container-deck) and click **Fork**.
2. Clone your fork and add the original repository as `upstream`:

```bash
git clone https://github.com/<your-username>/container-deck.git
cd container-deck
git remote add upstream https://github.com/sur950/container-deck.git
git remote -v        # origin is your fork, upstream is the original
```

With the GitHub CLI the same takes one line: `gh repo fork sur950/container-deck --clone`.

### 2. Build and run

```bash
swift build
swift test
swift run ContainerDeck
```

`swift run` starts the app without a bundle. Notifications, the login item and deep links need the real app bundle. Build and open it with `scripts/bundle.sh && open "build/Container Deck.app"`. [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) has more on the development loop.

### 3. Stay in sync

Before you start something new, bring your fork's `main` up to date with upstream:

```bash
git switch main
git fetch upstream
git merge --ff-only upstream/main
git push origin main
```

## Project layout

| Path | What lives there |
|---|---|
| `Sources/DeckCore` | No UI. CLI calls, the direct XPC client, JSON parsing, compose, engine import, updates. Unit tested. |
| `Sources/ContainerDeck` | The SwiftUI app. `App/`, `DesignSystem/`, and one folder per screen in `Features/`. |
| `Sources/DeckCore/Config/AppConfig.swift` | Product names, links, colors, logo files and defaults. Change them here only. |
| `Tests/DeckCoreTests` | XCTest with recorded real CLI output and a `MockRunner`. |
| `Tests/ContainerDeckTests` | Tests for app level logic and the design system. |
| `docs/` | Architecture, development, Compose, Docker, domains and brand guides. |

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before a larger change. Changes to the direct XPC client should also follow [Sources/DeckCore/API/README.md](Sources/DeckCore/API/README.md).

## Code rules

- Swift 5 language mode, macOS 15 deployment target. The only third party dependency is Yams. Open an issue before adding another one.
- Views never run processes. Every platform call goes through `ContainerClient` in DeckCore.
- Use the design system: `DeckIcon` instead of raw SF Symbols, and the components in `DesignSystem/` (`Card`, `MetricTile`, `Pill`, `EmptyState`, `SheetScaffold` and the rest). Brand crimson is the only accent.
- Every screen must look right in Light and Dark mode, at the minimum window size (1260 x 720) and wider.
- Never crash on unexpected CLI output. Errors go to `state.showError(error)`.
- UI copy is short and plain. No long dashes and no semicolons in the interface.
- Apple's [`container` source](https://github.com/apple/container) is the reference for CLI flags and JSON shapes. Check `Sources/ContainerCommands` there before relying on a flag.

## Tests

Every pull request must keep `swift test` green, and new behavior needs tests. Use recorded real output as fixtures (see `Tests/DeckCoreTests/Fixtures`), and assert both the parsed result and the exact arguments sent to the CLI.

Tests that touch the real system are opt in through environment variables, so `swift test` stays safe and fast:

| Variable | What it runs |
|---|---|
| `DECK_REAL_CLI=1` | Real `container` CLI and direct API checks (creates and removes `deck-test-*` resources). Add `DECK_BENCH=1` for a latency table. |
| `DECK_LIVE_CLI=1`, `DECK_INTEGRATION=1` | System checks and the Compose runner against the real CLI |
| `DECK_LIVE_BUILDS=1` | Real image builds |
| `DECK_LIVE_SANDBOX=1` | Sandboxes, allow list proxy and kill switch |
| `DECK_LIVE_DOMAINS=1` | HTTPS proxy with a throw away certificate authority |
| `DECK_LIVE_TUNNEL=1` | A public Cloudflare quick tunnel (publishes a URL, run with care) |
| `DECK_LIVE_KUBERNETES=1` | Creates and deletes a small cluster |
| `DECK_LIVE_MCP=1` | MCP servers in containers |
| `DECK_LIVE_AI=1` | Model download and local model servers |
| `DECK_LIVE_ENGINES=1` | Import from OrbStack and Rancher Desktop (starts and stops them) |
| `DECK_LIVE_POLISH=1` | Machines and export |
| `DECK_UPDATER_E2E=1` | Update download and verify from a local disk image |
| `DECK_SIGNER_SCRIPT=1` | Checks that `scripts/update_signer.swift` and the app agree on the signature format |
| `DECK_CAPTURE_API=1` | Records replies from the container service for new fixtures |

Live tests clean up after themselves and leave your agent config files and other engines as they found them.

## Pull requests

1. Create a branch from an up to date `main` in your fork:
   ```bash
   git switch -c fix/short-description
   ```
2. Keep the change focused. One topic per pull request.
3. Run `swift build` and `swift test`. For UI changes, check Light and Dark mode and attach screenshots of both.
4. Commit with a clear message that says what changed and why, then push the branch to your fork:
   ```bash
   git push -u origin fix/short-description
   ```
5. Open a pull request from your branch to `sur950/container-deck:main` (GitHub offers a button after the push, or run `gh pr create --repo sur950/container-deck`). Fill in the template.
6. If `main` moves on while your pull request is open, rebase on it and push again:
   ```bash
   git fetch upstream
   git rebase upstream/main
   git push --force-with-lease
   ```

CI builds the app and runs the full test suite on every pull request.

## License

By contributing you agree that your contribution is licensed under the project [LICENSE](LICENSE) (Apache 2.0 with the Commons Clause condition).
