# Domains, local HTTPS and sharing

The Domains screen gives containers friendly names on your Mac, serves them over HTTPS on `127.0.0.1`, and can share one to the internet through a tunnel. Every part of it is off until you turn it on.

The screen lives in `Sources/ContainerDeck/Features/Domains/`. The core logic is in `Sources/DeckCore/Domains/`, and every tunable value (ports, labels, paths, validity periods) is in `DomainsConfig.swift`.

## What Apple's container platform already provides

Container Deck uses the platform's own features where they exist and adds only what is missing.

| Need | How | Admin rights |
| --- | --- | --- |
| A DNS domain for containers, such as `web.test` | `container system dns create test`, which writes `/etc/resolver/containerization.test` | Yes, through `PrivilegedRunner` |
| The default domain | `dns.domain` in `~/.config/container/config.toml`, followed by a restart of the container service | No |
| Containers reaching services on the Mac by name | `container system dns create host.container.internal --localhost 203.0.113.113`. The name resolves to that address and a pf rule forwards it to `127.0.0.1`. Per Apple's documentation this turns off iCloud Private Relay, and the rule does not survive a restart. | Yes |
| A host only network | `container network create --internal`, offered as "Host only" on the Networks screen | No |
| Aliases such as `api.test` or `*.gateway.test` | Not available in the platform. Provided by the proxy below. | See below |

The host alias address is read back from Apple's resolver file (`options localhost:<ip>`), so listing domains never needs admin rights.

## Local HTTPS proxy

The proxy is built on Network.framework and adds no dependencies.

```
browser ──TLS──▶ 127.0.0.1:8443   front listener, plain TCP
                    reads the server name from the TLS ClientHello, decrypts nothing
                 ──▶ 127.0.0.1:<random>   TLS listener for that one name, with its own certificate
                    terminates TLS and pipes bytes ──▶ container IP:port
```

Because the front listener hands each connection to a TLS listener made for that one name, every host name gets its own leaf certificate, and the proxy never needs to decrypt traffic it cannot route. `TLSClientHello.swift` parses just enough of the handshake to read the name.

Behavior worth knowing:

- The proxy listens only on `127.0.0.1`. It never binds `0.0.0.0` or the container gateway, so nothing on the local network can reach it. Containers talk to each other by DNS name, not through the proxy.
- Only HTTP/1.1 is offered through ALPN. Bytes are piped unchanged, so WebSockets and server sent events work.
- Plain `http://` on the proxy port gets a short reply asking for `https://`. Unknown names are closed. A stopped or missing container gets a 503 page, and an unreachable one gets a 502.
- While the proxy runs, it follows the shared container feed every 2 seconds, so new containers get routes without a restart.
- The proxy can start with the app. The "Start with the app" option on the Domains screen controls this.

### Routes

Every running container gets a route at `<container-name>.localhost`. Names under `.localhost` resolve to `127.0.0.1` on every Mac, so no DNS setup is needed.

The target port is chosen in this order: the `deck.port` label, the first published TCP port, the image's first exposed port, and finally port 80, which the screen marks as a guess. Set the label `deck.route=false` to leave a container out.

### Aliases

An alias is either one name or a wildcard such as `*.example.test`. Aliases under `.localhost` work immediately. Any other domain needs one admin step that writes `/etc/resolver/<domain>`, pointing at a small DNS server inside the app on `127.0.0.1:15353` that answers every query with `127.0.0.1`. Each resolver file we write starts with the marker `# Added by Container Deck`, and the app only ever removes files that carry it.

### Certificate authority

The local certificate authority is created with `/usr/bin/openssl`: RSA 2048, valid for 10 years, with `pathlen:0` so it cannot issue intermediate CAs. Leaf certificates are valid for 397 days, the longest period browsers accept, and carry `serverAuth` and a single subject alternative name.

Leaves are created on first use and stored in `~/Library/Application Support/io.github.sur950.containerdeck/Proxy/leaves`, with the folder readable only by you and keys at mode 0600. They are loaded into memory only (`kSecImportToMemoryOnly`) and never added to a keychain.

Nothing is trusted automatically. "Trust in Keychain" runs `security add-trusted-cert -r trustRoot -p ssl -k login.keychain-db`, and macOS asks you to approve it. "Remove Trust" runs `security remove-trusted-cert` and deletes the certificate by its SHA-1. The tests never add trust. They use a temporary keychain and pin the CA in curl and `URLSession`.

### Port 443

Binding `127.0.0.1:443` requires root, and the app never runs as root. By default the proxy uses port 8443, needs no admin rights, and links look like `https://web.localhost:8443`.

"Use Port 443" is an opt in. One admin prompt loads this rule into the pf anchor `com.apple/250.ContainerDeck`:

```
rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port 8443
```

The stock `/etc/pf.conf` already loads anchors under `com.apple/*`, so no system file is edited. The rule is gone after a restart, the same as Apple's `--localhost` rule, and "Turn Off" flushes the anchor. The app warns if something already listens on port 443, such as a local Caddy, because the rule would take that traffic.

## Share to the internet

A route can get a public link for a demo or a webhook. Three providers are offered side by side, because companies often block one or two of them: Cloudflare Tunnel, ngrok and Tailscale Funnel. The Share button on a route opens a picker that lists all three with a status (Ready, Needs setup with a one line fix, or Not installed with an install option). The last provider used is picked by default. When a share fails, the route shows the reason, the fix, and a "Try" button for another provider that is ready.

| Provider | What it needs | Command the app runs |
| --- | --- | --- |
| Cloudflare Tunnel | Nothing. No account. | `cloudflared tunnel --no-autoupdate --url http://<container-ip>:<port>` |
| ngrok | An ngrok account (the free plan works) and its authtoken | `ngrok http <container-ip>:<port> --log stdout --log-format json`, plus `--url https://<domain>` when you saved a domain |
| Tailscale Funnel | Tailscale signed in, HTTPS certificates on, Funnel allowed for this Mac, and a published port on the container | `tailscale funnel --https=<443, 8443 or 10000> http://127.0.0.1:<published port>` |

Tunnels work whether or not the proxy is running. Each one runs under a small `/bin/sh` guard that stops the tool when the app exits, even after a crash or a forced quit. "Stop" and "Stop All Sharing" end shares at once for every provider, and shared routes show a "Public" badge.

Nothing is ever installed without a click. Homebrew is offered when it is present, otherwise the download page opens.

### Cloudflare Tunnel

1. Install cloudflared with "Install", either `brew install cloudflared` or a download of Cloudflare's own release into Application Support. The download is checked against the SHA-256 that GitHub publishes and with `codesign --verify`, and it is refused when no checksum is published.
2. Pick Cloudflare Tunnel in the picker. The `trycloudflare.com` link is read from cloudflared's output.

| Message | Meaning |
| --- | --- |
| cloudflared cannot reach Cloudflare. | The request for a quick tunnel failed, usually a blocked network or no internet. Try another provider. |
| Cloudflare did not hand out a quick tunnel. | Cloudflare refused the request for now. Wait a minute or use another provider. |

### ngrok

1. Install ngrok: `brew install ngrok`, or the download page at ngrok.com.
2. Create a free account at ngrok.com and copy your authtoken from the dashboard (Getting Started, Your Authtoken).
3. In Domains, Share to the internet, ngrok, choose "Set Up" and paste the authtoken. If you reserved a domain in ngrok, add it too. Without one, every share gets a new link.

The authtoken is stored in your login Keychain as a generic password (service `io.github.sur950.containerdeck.share`, account `ngrok.authtoken`). It reaches ngrok only through the `NGROK_AUTHTOKEN` environment variable of the running agent. It is never put on a command line, never written to a file, and it is blanked out of any output the app shows. If you already ran `ngrok config add-authtoken`, the app sees the token in `~/Library/Application Support/ngrok/ngrok.yml` and uses it as is. The app only reads that file and never changes it.

The link is read from the agent's JSON log line `"msg":"started tunnel"`, so a custom domain works too. If the log has no link after six seconds, the app asks the agent's local API (`/api/tunnels` on the address from the `"starting web service"` line, normally `127.0.0.1:4040`).

| Message | ngrok code | Meaning and fix |
| --- | --- | --- |
| ngrok needs an authtoken. | ERR_NGROK_4018 | No authtoken anywhere. Use "Set Up" and paste it. |
| This is not a valid ngrok authtoken. | ERR_NGROK_105 | The value is not shaped like a token. Copy it again from the dashboard. |
| ngrok did not accept this authtoken. | ERR_NGROK_107 | The token was reset or revoked. Copy the current one. |
| Your ngrok plan allows one agent at a time. | ERR_NGROK_108 | The free plan runs one agent. Stop the other ngrok share, or ngrok running on another machine, then try again. |
| This ngrok address is already online. | ERR_NGROK_334 | Something else already serves your saved domain. Stop it or clear the domain. |
| This ngrok version is too old for your account. | ERR_NGROK_120, 121 | Run `brew upgrade ngrok`. |
| ngrok cannot reach its servers. | none | A blocked network or no internet. Try another provider. |

### Tailscale Funnel

1. Install Tailscale from tailscale.com/download/mac (or `brew install --cask tailscale-app`), open it and sign in. The app uses the CLI inside `/Applications/Tailscale.app/Contents/MacOS/Tailscale`, or a `tailscale` command in `/opt/homebrew/bin` or `/usr/local/bin` (the open source build or the one the app installs).
2. In the Tailscale admin console, turn on MagicDNS and HTTPS certificates (DNS page).
3. Allow Funnel for this Mac: the `funnel` node attribute in the tailnet policy. The first share prints a link that turns it on for you, and the app shows that link.
4. Publish a port for the container, like `-p 8080:80`. Funnel only serves ports on this Mac.

Before a share starts, the app reads `tailscale status --json` (signed in, HTTPS, version 1.52 or later) and `tailscale funnel status --json` (ports in use), then takes the first Funnel port nobody uses out of 443, 8443 and 10000, or out of the ports your policy allows. It never takes a port that another funnel or serve already uses. Funnel runs in the foreground, so Tailscale removes it by itself when the command ends, and a link never outlives the app. After a share ends the app checks the background config, and only if it finds its own funnel (same port, same target) does it run `tailscale funnel --https=<port> off`. It never runs `tailscale funnel reset` and never touches funnels you set up yourself. Public DNS for a new tailnet name can take up to 10 minutes.

| Message | Meaning and fix |
| --- | --- |
| Tailscale is not running. | The Tailscale app or daemon did not answer. Open Tailscale. |
| Sign in to Tailscale first. | Tailscale is logged out. Sign in from its menu. |
| Tailscale is turned off. | Tailscale is stopped. Choose Connect in its menu. |
| This Mac waits for approval in your tailnet. | An admin must approve the device on the Machines page. |
| HTTPS certificates are off in your tailnet. | Turn on HTTPS on the DNS page of the admin console. |
| Funnel is not turned on for your tailnet. | Open the link the app shows to allow it, then share again. |
| Your tailnet policy does not allow Funnel on this Mac. | Add the `funnel` node attribute for this Mac in Access controls, or open the link the app shows. |
| Your tailnet does not allow Funnel on port N. | Allow 443, 8443 or 10000 for Funnel in Access controls. |
| Port N on your tailnet name is already shared. | Another funnel or serve took that port. Stop it, then try again. |
| Every Funnel port on this Mac is in use. | 443, 8443 and 10000 are all taken. Stop a share or one of your own funnels. |
| This Tailscale is too old for Funnel. | Update Tailscale to 1.52 or later. |

Any provider can also report "gave no public link after 60 seconds", which usually means a blocked network. The share is stopped and the route offers another provider.

### Adding a provider

Each provider is one type behind the `ShareProvider` protocol in `Sources/DeckCore/Domains/ShareProvider.swift`: id, name, where its program lives, install options, setup fields (secrets go to the Keychain, other values to preferences), a readiness check, the launch plan, link parsing, failure parsing with a plain fix, and clean up. The providers live in `CloudflareShareProvider.swift`, `NgrokShareProvider.swift` and `TailscaleShareProvider.swift`, and are listed in `ShareProviders.all`. The screens have no provider specific code, so a fourth provider is one new file and one line in that list. `ShareManager` in `ShareTunnels.swift` starts, follows and stops shares for all of them.

### What was verified for real

- Cloudflare Tunnel: a real quick tunnel served the demo container (`DECK_LIVE_TUNNEL=1`).
- ngrok: the official agent 3.39.13 was run on this Mac with no account and an empty home folder. Its exact output for a missing token (ERR_NGROK_4018), a malformed token (105) and a well formed but unknown token (107) is recorded in `Tests/DeckCoreTests/Fixtures/DomainsShareFixtures.swift`, and the full share flow was run against that agent (`DECK_LIVE_NGROK_DIR=<folder with ngrok>`). A successful ngrok link and ERR_NGROK_108 and 334 still need a real account to confirm.
- Tailscale Funnel: no Tailscale install or tailnet was available. The messages come from Tailscale's open source CLI, and the stand in follows its documented behavior. A real tailnet is still needed to confirm the success path and the enable link text.

## Not supported yet

- Keeping routes alive while the app is closed, through a login item.
- Cloudflare named tunnels, which would allow your own domain but need a Cloudflare sign in.
- Several ngrok shares from one agent. Each share runs its own agent, so the free plan allows one ngrok share at a time.

## Tests

Unit tests use pure logic, recorded output and a real `openssl` in a temporary folder: `DomainsRoutingTests.swift`, `DomainsProtocolTests.swift`, `DomainsShareTests.swift`, `DomainsShareProvidersTests.swift` and `DomainsCertificateTests.swift` in `Tests/DeckCoreTests`.

`DomainsShareProvidersTests.swift` drives the full share and stop flow for all three providers through `ShareManager` with stand in `cloudflared`, `ngrok` and `tailscale` scripts written to a temporary folder. They print the real output and use the real exit codes for success and every failure above, and they check that the authtoken travels only in the environment, that a Tailscale stop leaves other funnels alone, and that every tool dies when the app does. `DECK_LIVE_KEYCHAIN=1` adds a Keychain round trip, and `DECK_LIVE_NGROK_DIR` runs the real ngrok agent without a token.

To see every share state in the app, a debug build can be pointed at a folder of stand in tools with `DECK_SHARE_TOOLS_DIR=<folder>`. It replaces the normal tool search, keeps secrets in memory instead of the Keychain, and reads the ngrok config from that folder.

Live tests are opt in and expect a container named `deck-demo-web` serving HTTP on port 80:

```bash
container run -d --name deck-demo-web nginx:alpine
DECK_LIVE_DOMAINS=1 swift test --filter DomainsLiveTests
```

They run the real proxy against that container over HTTPS with a temporary keychain, and cover a wildcard alias, the 503 page, plain HTTP, 12 parallel requests, a clean stop, the "port in use" error, and the DNS responder through `dig`. `DECK_LIVE_TUNNEL=1` also opens a real Cloudflare quick tunnel when cloudflared is already installed. It never installs cloudflared, and it publishes a public URL for the duration of the test.
