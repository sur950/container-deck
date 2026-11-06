# Security policy

## Supported versions

Security fixes are made in the latest release only. The app can update itself, so staying on the newest version is the simplest way to get them.

## Reporting a vulnerability

Do not open a public issue for a security problem.

Report it privately through GitHub. Open the repository's Security tab and choose Report a vulnerability. Include what you found, steps to reproduce it, the app and macOS versions, and the impact you expect.

We aim to reply within 5 working days and will keep you informed until the issue is fixed. Reporters are credited in the release notes unless they prefer otherwise.

## Scope

In scope: the Container Deck app, its installer package and disk image, the update mechanism (signature, checksum and certificate checks), the direct connection to the container service, the local HTTPS proxy and certificate authority, sandboxes and their allow list proxy, MCP and agent config writing, and how secrets are stored in the Keychain.

Out of scope: Apple's container platform itself, which should be reported to [apple/container](https://github.com/apple/container), and third party engines, tunnels and agents.

## How the app protects you

- Updates install only when the Ed25519 signature, the SHA-256 checksum, the bundle id and the signing certificate all match. If any check fails, the update is refused and the installed version stays.
- API keys and secrets live in the macOS Keychain and are never written to config files or logs.
- Agent config files are changed only after you confirm a preview, with a backup and Undo.
- The HTTPS proxy listens on `127.0.0.1` only, and its certificate authority is trusted only after you choose to trust it and approve the macOS prompt.
- Commands that need admin rights go through the standard macOS password prompt. The app never runs as root and never stores your password.
