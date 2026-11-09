# Direct API client

This folder holds a small XPC client that talks to Apple's container service the same way the `container` CLI does. Container Deck uses it for the calls it makes most often, and falls back to the CLI whenever the direct path is not safe to use.

## Why it exists

Container Deck polls the container list and samples stats while a window is open. Through the CLI, each of those calls starts a process, and `container stats --no-stream` waits about two seconds for a second sample before it prints anything. Over XPC, a list call takes a few milliseconds and a stats sample for every running container takes about 25 ms, with no process at all. That difference is what lets the app refresh once a second without using noticeable CPU.

The client is our own code with no dependencies beyond the system `XPC` framework. It only knows the wire names (service names, routes and message keys) taken from Apple's source, see the header of `APIProtocol.swift`. Everything that builds a container, pulls an image or needs a terminal stays on the CLI, because that is where Apple keeps the client side logic for those operations.

## How a call flows

```
ContainerClient (state.client)
  └─ router set? ── no ──▶ container CLI
        │ yes
        ▼
ContainerBackendRouter.route(family)
  └─ BackendSelector.decision(family)
        ├─ .cli ─────────────▶ plain ContainerClient (CLI)
        ├─ .serviceStopped ──▶ "The container services are not running."
        └─ .direct ──────────▶ DirectAPIClient ──▶ XPCConnection ──▶ container service
                                    │ fails
                                    ▼
                          fallback rules (below)
```

`ContainerClient` has an optional `router` property. When it is set, every method listed as direct in the table below starts with one line that hands the call to the router. The router owns its own `ContainerClient` with `router` cleared, so the CLI path can never loop back into the router. A client without a router is a pure CLI client, which is what the unit tests and `MockRunner` use.

The app creates one router per session in `AppState` and every `state.client` is routed through it. That way the XPC connections, the ping cache, the image blob cache and the fallback counts are shared across the whole app.

`ContainerOperations` is the protocol that both `ContainerClient` and `ContainerBackendRouter` conform to. Code that only needs these calls can take `any ContainerOperations`.

## What goes direct and what stays on the CLI

| Operation | Backend | How |
| --- | --- | --- |
| `listContainers(all:)` | Direct | `containerList` with the CLI's filters. Machines are excluded, and from 1.7 on cluster nodes too (the filter follows the daemon's version, see "Differences between releases"). Only running containers are returned unless `all` is set. |
| `listClusterNodes()` | Direct | `containerList` filtered on the plugin label `cluster`, running or not. The CLI path lists them with `container list --all` on 1.6 and with `cluster list --format json` plus `container inspect` on 1.7. |
| `clusterNode(_:_:features:)` | Direct only on 1.7 | Start, stop, kill or delete of a cluster node. On 1.7 the CLI answers "not found" for nodes, so this goes to the daemon even with the CLI only switch on or an untested version. On 1.6 and older the normal routes are used. |
| `inspectContainer(_:)`, `inspectContainers(_:)` | Direct | `containerList` filtered by id. `rawJSON` has the same shape the CLI prints. An unknown id goes to the CLI so the user sees its message. |
| `startContainer(_:)` | Direct | The same steps as a detached `container start`: no-op when already running, check that bind mount sources exist, `containerBootstrap` (passing `SSH_AUTH_SOCK`), then `containerStartProcess`. On failure the container is stopped again so it is never left half started. |
| `stopContainer(_:)` | Direct | `containerStop` with a 5 second grace period. |
| `killContainer(_:)` | Direct | `containerKill` with `KILL`. |
| `restartContainer(_:)` | Direct | Stop, then start. |
| `deleteContainer(_:force:)` | Direct | `containerDelete` with `forceDelete`. |
| `stats(_:)` | Direct | `containerList`, then `containerStats` for each running container in parallel. One sample, no wait. |
| `logs(_:options:)` | Direct | `containerLogs` returns file descriptors for the stdio and boot logs. We read the tail and poll the file every 250 ms when following. |
| `listImages()` | Direct | `imageList` on the images service, plus index, manifest and config blobs through `contentGet`. Builder and init images are hidden. |
| `inspectImage(_:)` | Direct | The reference is resolved like the CLI does it: local build name first, then exact, then normalized. An unknown reference goes to the CLI. |
| `tagImage(_:as:)` | Direct | `imageTag` with the normalized target. |
| `deleteImage(_:)` | Direct | `imageDelete`, then `imageCleanupOrphanedBlobs`, as the CLI does. |
| `listVolumes()`, `listVolumeSummaries()` | Direct | `volumeList`. `usedBy` comes from one extra container list. |
| `createVolume(name:size:labels:)`, `deleteVolume(_:)` | Direct | `volumeCreate` with the `local` driver and the size as a driver option, `volumeDelete`. |
| `listNetworks()`, `listNetworkSummaries()` | Direct | `networkList`. Attached containers come from one extra container list. |
| `createNetwork(...)`, `deleteNetwork(_:)` | Direct | `networkCreate` with the same `NetworkConfiguration` the CLI builds, `networkDelete`. Builtin or unknown networks go to the CLI. |
| `diskUsage()` | Direct | `systemDiskUsage`. |
| `runContainer(_:)` | CLI | See below. |
| `exec`, shell, file browsing and copy | CLI | They need a TTY or stdio file descriptors. |
| `pullImage`, `build`, `loadImage`, `saveImage` | CLI | Long jobs with progress output. |
| Export, commit and every prune command | CLI | Rare, and the CLI prints what it did. Image prune is the exception: the app deletes unused images one by one (`ImageUsage.swift`), because `container image prune` removes the untagged node image of a live cluster. |
| System properties, service start and stop | CLI | Properties have no XPC route. Start and stop are launchd jobs. |
| DNS domains, registry login | CLI | DNS needs admin rights and login uses the keychain. Neither lives on the container service. |
| Machines, Kubernetes clusters | CLI | Separate services and plugins. Cluster records come from `cluster list --format json` on 1.7. |

### Why create and run stay on the CLI

`container run` does a lot of work on the client before it sends the single `containerCreate` message. It resolves and pulls the image with progress, unpacks the snapshot, reads the image config for entrypoint, environment, user and working directory, picks the kernel and init image, creates anonymous volumes, checks mounts and ports, and applies DNS and Rosetta defaults. Reproducing all of that means tracking a large part of Apple's client code release by release, and a mistake would quietly create a wrong container. The CLI stays the only place that builds a `ContainerConfiguration`. The live lifecycle test creates a container with the CLI and drives the rest of its life over XPC.

## Choosing a backend

`BackendSelector` is an actor that decides each call.

1. If the `forceCLIBackend` user default (`AppConfig.forceCLIBackendKey`) is on, the call goes to the CLI without a ping. The key is read on every call, so the Settings switch applies at once.
2. Otherwise the selector pings the container service with a 2 second limit. A good answer is reused for 30 seconds. Any connection problem clears it so the next call pings again. A stopped service is pinged on every call, which costs about a millisecond and means a service start is noticed right away.
3. The daemon version from the ping must fall inside `AppConfig.apiSupportedVersions`, currently 1.4.0 up to but not including 1.8.0. The wire format for every route used here is unchanged across that range (checked against the 1.7.1 source and live on 1.7.1). Any other version uses the CLI.
4. If a family of operations has been moved to the CLI for this session (see below), the call goes to the CLI.

`router.status()` returns a `BackendStatus` with the backend in use, the service state, the daemon version, which families are on the CLI and how many calls fell back. Settings shows its one line `summary`, and `BackgroundServices` reads it after every poll to pick the polling pace.

## Differences between releases

The wire format is the same from 1.4 to 1.7, but what the CLI does around it is not. `ContainerPlatformFeatures` (`Platform/PlatformFeatures.swift`) answers per version, from the CLI version in the setup report or, for the direct path, the daemon version from the last ping. Unknown newer releases get the newest known behaviour and their errors say the release is newer than tested.

| Release | `container list` | Cluster nodes | `cluster list` | Loading a local image | Kernel |
| --- | --- | --- | --- | --- | --- |
| 1.4, 1.5, 1.6.0 | Hides machines, shows nodes | Plugin is `container k8s`, nodes labelled `k8s`, one node only | Node table (`k8s list`) | `k8s load-image` | 6.18.35 |
| 1.6.1 | Hides machines, shows nodes | Plain containers, start and stop work on them | Node table | `cluster load-image` | 6.18.35 |
| 1.7 | Hides machines and nodes | The CLI answers "not found", the app uses the daemon | One row per cluster, `--nodes`, `--format json` with records | Gone. `--shared-image-store` at create, or the app saves, copies and imports with `ctr` | 6.18.56, an upgraded Mac keeps the old one |

The direct path sends the same list filter as the CLI of the daemon's release (`^(?!machine$)` up to 1.6, `^(?!(?:machine\|cluster)$)` from 1.7), so both paths list the same containers.

## Fallback rules

`ContainerBackendRouter.route` applies these rules to each direct call. `APIError` in `APIError.swift` defines the error kinds.

| Situation | What the router does |
| --- | --- |
| Transport failure on a read: timeout, interrupted connection, unreadable reply, or a request the daemon could not decode | Retries through the CLI and counts the failure against the operation's family. |
| Failure on a change (start, stop, kill, delete, create) | Retries through the CLI only when the daemon certainly did not act (`APIError.requestNotApplied`): a malformed or rejected request, or an interrupted connection, which is also what an unknown route returns. A timeout is never retried, because the change may still be in progress. |
| Two failures in a row in one family while the ping still answers | Moves that family to the CLI for the rest of the session. A success resets the count, and a new daemon version clears it. |
| A real error reply from the daemon, such as "no such container" or "volume in use" | Shows it as it is through `DeckError.commandFailed`, the same way a CLI error would appear. Not counted. |
| `.needsCLI`: an image name we cannot resolve, a missing bind mount source, a builtin network | Sends the call to the CLI so the user gets its exact message. Not counted. |
| `Connection invalid` (the service is not registered) | Pings once more to confirm, then reports "The container services are not running." This is not a fallback, because the CLI cannot reach a stopped service either. |
| The direct log stream fails | Switches to the CLI stream if no line was shown yet. After the first line, the error is passed on instead of restarting the stream. |

## Known differences from the CLI

These are deliberate and covered by tests.

- The CLI hides only the exact builder and init image tags it is configured with. We hide every tag of those two repositories, so old builder images left behind after an update are hidden too.
- The CLI fails the whole image list when one image cannot be read. We skip that image.
- Dates keep fractions of a second. The CLI prints whole seconds.
- `stats` returns one sample immediately. CPU percent is computed from the previous sample in `CPUSampleCache`, as on the CLI path, so the first sample for a container has no CPU value yet.
- A followed log line that arrives in two writes stays one line. The CLI may split it.

## Files

| File | Contents |
| --- | --- |
| `XPCConnection.swift` | `XPCValue`, `XPCRequest`, `XPCReply`, the `XPCTransport` protocol with `call(_:timeout:)` (timeout, cancellation, server errors), and `XPCConnection`: one long lived connection per service that reconnects after the service restarts. |
| `APIProtocol.swift` | Service names, routes, message keys, labels and per call timeouts. Adapted from Apple's source with the Apache 2.0 header kept. |
| `APIError.swift` | Error kinds and the predicates the router uses (`isTransportFailure`, `requestNotApplied`, `isRequestRejected`). |
| `APIPayloads.swift` | Request payloads and reply decoding. Replies are reshaped into the CLI's JSON and parsed by `ContainerOutputParser`, so both paths produce identical models. Image reference normalization. |
| `DirectAPIClient.swift` | Containers, stats, logs, volumes, networks, disk usage, ping. |
| `DirectAPIImages.swift` | Image list, inspect, tag and delete, and a small content blob cache keyed by digest. |
| `APILogReader.swift` | Tail and follow for the log file descriptors the daemon hands over. |
| `BackendSelector.swift` | Backend choice, version check, per family fallback state, `BackendStatus`. |
| `ContainerBackendRouter.swift` | Per call routing and fallback, and the `ContainerClient` wiring (`routed(through:)`, `backendStatus()`). |
| `ContainerOperations.swift` | The protocol shared by the CLI client and the router. |

## Adding a route

Only move an operation to the direct API when it is called often enough for the speed to matter, and when the CLI does little or no client side work for it. Then:

1. Find the command in Apple's `Sources/ContainerCommands` and follow it to the XPC client it uses. Write down the route name, the request keys and the reply keys. Add any new names to `APIProtocol.swift`.
2. Check that the route and its payloads are the same in every version inside `AppConfig.apiSupportedVersions`. If they are not, narrow the range or leave the operation on the CLI.
3. Add a method to `DirectAPIClient` that repeats whatever the CLI does around the call: filters, existence checks, follow up calls. Decode the reply into the CLI's JSON shape and reuse `ContainerOutputParser`, so results match the CLI path exactly. Throw `.needsCLI` for cases where the CLI's message is the better answer.
4. Add the method to `ContainerOperations` if it is new there, implement it in `ContainerBackendRouter` with `route(_:changes:direct:cli:)`, and pick the family it belongs to. Pass `changes: true` for anything that modifies state.
5. Add the one line `if let router { return try await router.method(...) }` at the top of the matching `ContainerClient` method.
6. Add tests (next section) and update the table in this file.

## Widening the supported version range

When Apple ships a new `container` release, run the live tests below against it. If parity and the lifecycle round trip pass, raise the upper bound of `AppConfig.apiSupportedVersions` and record fresh fixtures with `DECK_CAPTURE_API=1`. Until then, users on the new version get the CLI fallback automatically, so nothing breaks in the meantime.

## Testing

Unit tests run with `swift test` and need neither the container service nor the CLI.

- `Container17Tests.swift` covers the release differences with output recorded from 1.7.1 (`Fixtures/Container17Fixtures.swift`) next to 1.6.1: cluster list shapes, the list filter per daemon version, node start and stop over the daemon, load image, create arguments, the kernel check after an upgrade and the 1.8 fallbacks.
- `DirectAPITests.swift` decodes real replies recorded from container 1.6.1 (`Tests/DeckCoreTests/Fixtures/API/APIFixtures.swift`, with home paths scrubbed). It covers unknown states, dates since 2001, the request built for every change, image resolution, log reading, and timeouts and cancellation through `FakeTransport`.
- `BackendSelectorTests.swift` covers the version range, the forced CLI switch, a stopped service, ping reuse, the two strike rule and every router fallback rule.
- `ClientRoutingTests.swift` checks that `ContainerClient` hands direct calls to the router, keeps CLI only calls on the CLI, and never loops.

Live tests touch the real service and are opt in:

```bash
DECK_REAL_CLI=1 swift test --filter DirectAPILiveTests
```

They compare the direct API with the CLI for list, inspect, stats, images, volumes, networks and disk usage, run a full lifecycle on throwaway `deck-test-api-*` resources, and check error handling through the router.

For a new release, `Container17LiveTests` runs a feature pass (containers, images and builds, volumes, networks, Compose, machines, sandboxes, Kubernetes) through one backend at a time with `deck-17-test-*` names and writes a pass or fail table to `/tmp/deck-17/matrix/`:

```bash
DECK_LIVE_17=1 DECK_LIVE_BACKEND=direct swift test --filter Container17LiveTests
DECK_LIVE_17=1 DECK_LIVE_BACKEND=cli swift test --filter Container17LiveTests
```

To try a release side by side without installing it, unpack its signed pkg with `pkgutil --expand-full`, stop the installed services, and start the unpacked one with its own data folder: `container system start --app-root <dir> --install-root <payload>`. Then set `DECK_CONTAINER_CLI=<payload>/bin/container` (debug builds only), `CONTAINER_APP_ROOT=<dir>` and `KUBECONFIG=<file>` for the tests or the app. Two more switches help when working on this code:

| Variables | Effect |
| --- | --- |
| `DECK_REAL_CLI=1 DECK_BENCH=1` | Measures each operation over both paths and writes a table to `/tmp/deck-api-bench.md`. |
| `DECK_CAPTURE_API=1` | Records raw replies to `/tmp/deck-api-capture` for new fixtures. |
