# Using Docker commands with Apple's container

Apple's `container` CLI covers most of what you do with `docker` every day, but the command names differ: `container list` instead of `docker ps`, `container image list` instead of `docker images`, and so on. This guide shows two ways to keep your Docker habits and scripts working.

| You want to | Use |
|---|---|
| Type `docker ps` in your own terminal | [Shell aliases](#shell-aliases) |
| Run scripts, Makefiles or tools that call `docker` | [The `docker` command](#the-docker-command) |

Both run Apple's container platform. Nothing here installs Docker Desktop or a Docker engine.

## The `docker` command

Container Deck ships a small `docker` command, [`contrib/docker/docker`](../contrib/docker/docker). It translates Docker style commands and flags into `container` commands and runs them. Because it is a real executable on your `PATH`, it works everywhere a shell alias does not: in scripts, `make`, CI jobs on your Mac, and tools that run `docker` as a subprocess.

Install it into `~/.local/bin`:

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/sur950/container-deck/main/contrib/docker/docker -o ~/.local/bin/docker
chmod +x ~/.local/bin/docker
```

Make sure `~/.local/bin` comes first on your `PATH`. Add this to `~/.zshrc` if it is not there yet, then open a new terminal:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Check it:

```bash
docker version        # shows Apple's container version
docker ps -a
```

Set `DOCKER_SHIM_DEBUG=1` to print each translated command before it runs:

```bash
DOCKER_SHIM_DEBUG=1 docker run --rm -p 8080:80 nginx:alpine
# + container run --rm -p 8080:80 nginx:alpine
```

If Docker Desktop is also installed, this command takes over the name `docker` while `~/.local/bin` is first on your `PATH`. To keep both, install it under another name, for example `~/.local/bin/dockerc`, and call that instead.

### What it translates

| Docker | Runs |
|---|---|
| `docker ps [-a] [-q]` | `container list [--all] [--quiet]` |
| `docker run`, `docker create` | `container run`, `container create` (flags mostly identical, see below) |
| `docker start`, `stop`, `kill`, `exec`, `inspect`, `stats`, `export`, `commit` | same name in `container` |
| `docker restart <name>` | `container stop`, then `container start` |
| `docker rm` | `container delete` |
| `docker cp` | `container copy` |
| `docker logs [-f] [--tail N]` | `container logs [--follow] [-n N]` |
| `docker images` | `container image list` |
| `docker rmi` | `container image delete` |
| `docker pull`, `push`, `tag`, `save`, `load` | `container image pull`, `push`, `tag`, `save`, `load` |
| `docker image ls`, `docker image rm` | `container image list`, `container image delete` |
| `docker build`, `docker buildx build` | `container build` |
| `docker network ...`, `docker volume ...` | `container network ...`, `container volume ...` |
| `docker login`, `docker logout` | `container registry login`, `container registry logout` |
| `docker version` | `container system version` |
| `docker info` | `container system status` |
| `docker system df`, `docker system prune` | `container system df`, `container prune` and `container image prune` |
| `docker compose ...` | `container compose ...` when the Compose command is installed (see below) |

Commands that exist under the same name in both tools, such as `builder` or `machine`, pass straight through.

### Flags

Most `run` flags have the same spelling in both tools: `-d`, `--name`, `-p`, `-e`, `--env-file`, `-v`, `--mount`, `--rm`, `-it`, `-w`, `-u`, `--entrypoint`, `--network`, `--cpus`, `-m`, `-l`, `--platform`, `--dns`, `--tmpfs`, `--cap-add`, `--cap-drop`, `--ulimit`, `--shm-size`. They are passed through unchanged.

Docker flags that Apple's runtime has no equivalent for are dropped with a warning, so the container still starts:

`--restart`, `--pull`, `--log-driver`, `--log-opt`, `--health-*`, `--hostname`, `--add-host`, `--ipc`, `--pid`, `--gpus`, `--privileged`, `-P` / `--publish-all`.

Commands with no equivalent stop with a clear message and exit code 1: `swarm`, `service`, `stack`, `node`, `secret`, `config`, `context`, `plugin`, `trust`, `manifest`, `events`, `wait`, `pause`, `unpause`, `update`, `rename`, `attach`, `port`, `diff`, `history`, `search`, `top`.

### Compose

`docker compose up -d` runs `container compose up -d` once the Compose command is installed. Container Deck installs it from the Compose screen (one admin prompt). See [COMPOSE.md](COMPOSE.md) for what it supports.

## Shell aliases

If you only want shorter typing in your own terminal, aliases are enough. Add these to `~/.zshrc`:

```bash
alias dps='container list'
alias dpsa='container list --all'
alias di='container image list'
alias drun='container run'
alias dexec='container exec -it'
alias dlogs='container logs --follow'
alias drm='container delete'
alias drmi='container image delete'
alias dpull='container image pull'
alias dbuild='container build'
```

Aliases only work when you type them. Scripts and tools that call `docker` do not see them, which is what the `docker` command above is for.

## What does not work

Some tools do not run the `docker` command at all. They talk to the Docker engine API over a socket (`/var/run/docker.sock` or `DOCKER_HOST`). Apple's container platform has no Docker compatible API, so these tools cannot use it, with or without this command:

- Testcontainers
- VS Code Dev Containers and GitHub Codespaces local mode
- Docker SDKs (docker-py, the Go client, dockerode)
- Portainer, lazydocker, and other dashboards that read the API

Use Container Deck or the `container` CLI directly for those workflows.

## Remove it

```bash
rm ~/.local/bin/docker
```

Remove the aliases from `~/.zshrc` if you added them.
