# Development

This guide covers building, running and testing Container Deck from source. For how the code is organized, read [ARCHITECTURE.md](ARCHITECTURE.md). For contribution rules, read [CONTRIBUTING.md](https://github.com/sur950/container-deck/blob/main/CONTRIBUTING.md).

## Requirements

- A Mac with Apple silicon, running macOS 15 or later.
- Xcode 16 or later, for Swift tools 6.0. Use the newest Xcode you have.
- Apple's [`container`](https://github.com/apple/container) CLI, only if you want to use the app against real containers or run the live tests. Unit tests do not need it.

## Build and run

```bash
swift build
swift run ContainerDeck
```

You can also open `Package.swift` in Xcode and press Run.

`swift run` starts the app without an app bundle. That is the fastest loop for UI work, but notifications, the login item and `containerdeck://` deep links need a real bundle. Build one with:

```bash
scripts/bundle.sh
open "build/Container Deck.app"
```

Without `SIGN_IDENTITY` set, the bundle is signed ad hoc, which is fine for local testing.

## Test

```bash
swift test
```

The unit tests replay recorded `container` CLI output and recorded replies from the container service, so they run on any Mac with the toolchain and never touch your containers. Tests that use the real system are opt in through environment variables, for example:

```bash
DECK_REAL_CLI=1 swift test --filter DirectAPILiveTests
```

Live tests create resources with a `deck-test-` prefix and remove them when they finish. [CONTRIBUTING.md](https://github.com/sur950/container-deck/blob/main/CONTRIBUTING.md#tests) lists every variable.

## Project layout

```
Sources/
  DeckCore/          Library with no UI: CLI and direct API calls, parsing, feature logic
    API/             Direct XPC client and CLI fallback (see its README.md)
    Config/          AppConfig.swift: names, links, colors and defaults
    Platform/        Process runners, CLI locator, admin runner
    Resources/       ContainerClient, models, output parsers
    ...              One folder per feature area
  ContainerDeck/     The SwiftUI app
    App/             Entry point, AppState, preferences, background services
    DesignSystem/    Icons, tokens and shared components
    Brand/           Logo and lockup
    Features/        One folder per screen
Tests/
  DeckCoreTests/     Unit and opt in live tests for DeckCore, with fixtures
  ContainerDeckTests/  Tests for app level logic and the design system
scripts/             Bundle, disk image, signing and release scripts
packaging/           Entitlements and the asset catalog
assets/brand/        Logo, lockups and app icon
docs/                Architecture, Compose, Docker, domains and other guides
```

## Working on the UI

Check every change in both Light and Dark mode. Switch with Settings, General, Appearance. The window's minimum size is 1260 by 720, so check that size and a wider one.

For repeatable screenshots, start the app with `DECK_AUTOMATION=1`. It then accepts commands as distributed notifications, such as selecting a screen, changing the appearance, resizing the window and writing its own windows to a PNG. The command list is in `Sources/ContainerDeck/App/DebugAutomation.swift`. Add `DECK_AUTOMATION_ID=<id>` to run more than one copy at a time.

## Debugging platform calls

Settings, Platform shows whether the app is talking to the container service directly or through the CLI, and why. The switch there, "Use the container command only", sends every call through the CLI, which is a quick way to tell whether a problem is in the direct API or elsewhere.

Most screens show the equivalent `container` command for an action. Running that command in Terminal is often the fastest way to see the platform's own error.

Help, Diagnostics (Option Command D) collects versions, service state and recent errors in one place.
