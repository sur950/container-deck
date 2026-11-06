# Compose in Container Deck

Container Deck runs compose files on Apple's `container` platform. The same engine works in two places:

- The **Compose screen** in the app: import a file, check it, run Up and Down, follow logs.
- The **`container compose` command** in the terminal and in scripts.

Both read the file the same way, make the same containers and agree on what is running. A stack started in the terminal shows up in the app, and the other way round.

This page covers what is supported, how to use the command, and where it differs from Docker Compose. To check your own project quickly, start with [Coming from Docker Compose](#coming-from-docker-compose).

## Coming from Docker Compose

A checklist for moving a Docker Compose project over. **Supported** works as in Docker Compose, with the notes given. **Partly** says what works and what does not. **Not supported** says why: either Apple's runtime has no way to do it, or Container Deck has not built it yet.

Run `container compose config` on your file first. It prints every key that will not work, with its file and line, and changes nothing. `container compose up --dry-run` then shows each command Up would run.

Notes that start with "andon:" compare with the other `container compose` plugin, [compose.andon.dev](https://compose.andon.dev/) (andrew-waters/compose), as its site and source stood in November 2026. They are only given where the two differ.

### Files, project and variables

| Item | Container Deck | Notes |
| --- | --- | --- |
| `compose.yaml`, `compose.yml`, `docker-compose.yml`, `docker-compose.yaml` | Supported | Found in the current folder or the nearest parent folder. |
| `compose.override.yaml` | Supported | Merged on top when no `-f` is given. |
| `-f` (several files) | Supported | Merge rules of the Compose Specification, with `!reset` and `!override`. |
| `COMPOSE_FILE`, `COMPOSE_PATH_SEPARATOR` | Supported | |
| `-p`, `COMPOSE_PROJECT_NAME`, `name` | Supported | In that order, then the folder name. |
| `--project-directory` | Supported | Sets where relative paths and `.env` start. |
| `.env`, `--env-file` | Supported | `--env-file` can be given more than once. Later files win. |
| Interpolation | Supported | `$VAR`, `${VAR}`, `:-`, `-`, `:+`, `+`, `:?`, `?`, nested defaults, `$$`. An unset variable without a default becomes empty without a warning. |
| `--profile`, `COMPOSE_PROFILES`, `profiles` | Supported | A service named on the command line starts even when its profile is off. andon: not yet. |
| `include` | Supported | Short and long form. andon: not yet. |
| `extends` | Supported | Same file or another file. andon: not in its key table, so the file is refused. |
| `x-` keys, YAML anchors and `<<` merge keys | Supported | |
| `version` | Supported | Ignored, as in Docker Compose. |
| `--dry-run` | Supported | With `up`, `down`, `start`, `stop`, `restart`, `pull` and `exec`. |

### Commands

| Item | Container Deck | Notes |
| --- | --- | --- |
| `up [SERVICE...]` | Supported | Without `-d`, logs follow until Ctrl+C, then the services stop. Naming services also starts what they depend on. andon: `up` and `down` are its only commands. |
| `down` | Supported | |
| `ps` | Partly | Name, image, service, state, address, ports. Stopped containers are always listed (`-a` is accepted). `-q` and `--services` work. No `--format`, `--status` or health column. |
| `logs` | Partly | `-f` and `-n`/`--tail`. No `--since`, `--until` or `-t`. |
| `exec` | Supported | `-T`, `-d`, `-e`, `-u`, `-w`. No `--index` or `--privileged`. |
| `start`, `stop`, `restart` | Partly | They use `stop_signal`, `stop_grace_period` and the hooks. No `-t`/`--timeout` flag. |
| `pull` | Supported | Services with a `build` section are skipped. |
| `config` | Partly | Prints the merged, resolved file. `-q` and `--services` work. No `--format json`, `--volumes`, `--images` or `--profiles`. |
| `version` | Supported | |
| `build` | Not supported | Not built yet as a command. `up --build` builds every service with a `build` section. |
| `run` | Not supported | Not built yet. Use `exec` in a running service, or `container run`. |
| `create`, `rm`, `kill`, `pause`, `unpause`, `top`, `port`, `images`, `cp`, `events`, `wait`, `attach`, `scale`, `watch`, `ls` | Not supported | Not built yet. Apple's `container` has matching commands for single containers (`kill`, `delete`, `cp`, `stats`). The Compose screen in the app lists every stack. |

### Flags of `up` and `down`

| Item | Container Deck | Notes |
| --- | --- | --- |
| `up -d` | Supported | |
| `up --build` | Supported | |
| `up --force-recreate` | Supported | Without it, only services whose settings changed are recreated. |
| `up --remove-orphans` | Supported | The default here. Docker Compose only warns. Use `--keep-orphans` to keep them. |
| `up --pull missing\|always\|never` | Supported | Wins over `pull_policy`. |
| `up --no-deps` | Not supported | Not built yet. What a service depends on always starts. |
| `up --wait` | Not supported | Not built yet. Healthchecks only hold back the services that depend on them. |
| `up --no-build`, `--no-start`, `--no-recreate`, `--scale`, `-t`, `--abort-on-container-exit`, `--exit-code-from`, `-V`, `--quiet-pull`, `--attach`, `--timestamps` | Not supported | Not built yet. Refused with "Unknown option", so a script fails early. |
| `down -v` | Supported | Removes the project's named and anonymous volumes. External volumes stay. |
| `down --remove-orphans` | Supported | Accepted. Down removes every container of the project anyway. |
| `down --keep-networks` | Supported | Not in Docker Compose. |
| `down --rmi`, `down -t` | Not supported | Not built yet. |

### Top level keys

| Item | Container Deck | Notes |
| --- | --- | --- |
| `services` | Supported | |
| `networks` | Partly | `name`, `external`, `internal`, `driver: bridge`, the first `ipam` subnet. `driver_opts`, `enable_ipv6` and `labels` are not built yet. Other drivers are not possible. |
| `volumes` | Partly | `name`, `external`, `labels`, `driver: local`. `driver_opts` is not built yet. Other drivers are not possible. |
| `secrets`, `configs` | Not supported | Not built yet. andon: not possible. |

### Service keys

| Item | Container Deck | Notes |
| --- | --- | --- |
| `image` | Supported | |
| `build` | Partly | `context`, `dockerfile`, `args`, `target`. Other build options and remote contexts are not built yet. |
| `command` | Supported | |
| `entrypoint` | Supported | `entrypoint: []` drops the image entrypoint when a `command` is set. andon: not yet. |
| `environment`, `env_file` | Supported | `env_file` long form with `required`. |
| `ports` | Partly | Short and long form, ranges, host IP, udp. A port without a host port uses the same number on the Mac. Random host ports are not built yet. |
| `expose` | Supported | Nothing to do. Every port is open on the container address. andon: not in its key table, so the file is refused. |
| `volumes` | Partly | Bind mounts, named, anonymous and tmpfs mounts, read only. `volume.subpath` is not built yet. Other long form options are ignored. |
| `tmpfs` | Supported | andon: not possible. |
| `networks` | Partly | The first network only, with `aliases` and `mac_address`. A second network is not built yet. |
| `network_mode` | Partly | `bridge` and `default` only. `host`, `none`, `service:` and `container:` are not possible. Each container is its own small VM. |
| `depends_on` | Supported | `service_started`, `service_healthy`, `service_completed_successfully`, `required`. `restart: true` is not built yet. andon: start order only. |
| `healthcheck` | Partly | Probes run with `container exec` while a dependent waits. `ps` shows no health. A `test` is needed because the image's own HEALTHCHECK is not read. andon: not yet. |
| `profiles` | Supported | andon: not yet. |
| `labels`, `container_name`, `working_dir` | Supported | |
| `user` | Supported | andon: not possible. |
| `cap_add`, `cap_drop` | Supported | andon: not possible. |
| `ulimits` | Supported | andon: not possible. |
| `read_only`, `init`, `shm_size`, `mac_address` | Supported | andon: not in its key table, so the file is refused. |
| `dns`, `dns_search`, `dns_opt` | Supported | |
| `stop_signal`, `stop_grace_period` | Supported | The default wait is 5 seconds, Apple's default, not 10. andon: not in its key table, so the file is refused. |
| `pull_policy` | Partly | `always`, `never`, `missing`, `if_not_present`, `build`. `daily`, `weekly` and `every_*` act like `missing`. andon: only pulls when missing. |
| `post_start`, `pre_stop` | Supported | Run with `container exec`. `privileged: true` is refused. |
| `cpus`, `mem_limit`, `deploy.resources.limits` | Partly | CPUs round up to whole numbers. Memory works as set. Reservations are not possible. andon: `deploy.resources` only. |
| `platform` | Supported | `linux/amd64` runs with Rosetta. |
| `extra_hosts` | Partly | Written to `/etc/hosts` after start, so the image needs `/bin/sh`. `host-gateway` is not built yet. andon: not possible. |
| `deploy.labels` | Supported | |
| `restart`, `deploy.restart_policy` | Not supported | Not possible. Nothing restarts a container that exits. `restart: "no"` is fine. |
| `deploy.replicas`, `scale` | Not supported | Not built yet. One container runs. |
| `hostname`, `domainname` | Not supported | Not built yet. Apple's CLI has no hostname flag. |
| `stdin_open`, `tty`, `attach` | Not supported | Not built yet. Use `exec` or the Terminal button. |
| `secrets`, `configs` | Not supported | Not built yet. andon: not possible. |
| `links`, `external_links` | Not supported | Not built yet. Services reach each other by name anyway. |
| `develop` (watch) | Not supported | Not built yet. |
| `annotations`, `group_add`, `credential_spec`, `label_file`, `use_api_socket`, `provider`, `models` | Not supported | Not built yet. |
| `privileged`, `devices`, `gpus`, `device_cgroup_rules` | Not supported | Not possible. Each container is its own small VM with no host devices. |
| `ipc`, `pid`, `uts`, `userns_mode`, `cgroup`, `cgroup_parent`, `runtime`, `isolation` | Not supported | Not possible. Each container has its own kernel. |
| `security_opt`, `sysctls`, `oom_*`, `mem_swappiness`, `memswap_limit`, `mem_reservation` | Not supported | Not possible with Apple's CLI. Use `mem_limit`. |
| `cpu_shares`, `cpu_quota`, `cpu_period`, `cpuset`, `cpu_count`, `cpu_percent`, `cpu_rt_*` | Not supported | Not possible. Use `cpus`. |
| `blkio_config`, `storage_opt`, `pids_limit`, `logging`, `volumes_from` | Not supported | Not possible. Share a named volume instead of `volumes_from`. |

### Behavior

| Item | Container Deck | Notes |
| --- | --- | --- |
| Reach a service by its name (`db`) | Supported | Written to `/etc/hosts` in every container. Needs `/bin/sh` in the image. andon: only as `<project>-db`, and only once a DNS domain is set. |
| Re-up changes only what changed | Supported | A hash of each service's settings is stored on its container. |
| Several networks per service | Not supported | Not built yet. Only the first network is used. |
| Stacks started by Docker Compose labels | Supported | They show up. Up recreates them with Container Deck labels. |
| Keys that will not work | Supported | Listed with file and line. Errors stop Up. Keys that are not possible or not built yet are left out and Up goes on. andon: refuses the file on any key that would change behavior, and on any key it does not know. |

## How it works

Each service becomes one container, started with `container run`. Container Deck labels every container it makes with the project name, the service name, a hash of the service settings and the path of the compose file (all the files, for a project made of several). Those labels are how it finds a stack again later.

On Up it:

1. Creates the project networks and volumes that do not exist yet.
2. Pulls or builds images, following `pull_policy` and the `--pull` choice.
3. Removes orphans, which are containers of the project whose service is no longer in the file (unless you keep them).
4. Starts services in dependency order. It waits for `service_healthy` and `service_completed_successfully` conditions.
5. Runs each service's `post_start` hooks right after it starts.
6. Writes every service name into `/etc/hosts` in each container, so services find each other by name.

A service whose settings did not change and that is already running is left alone. Only changed services are recreated.

## Using it from the terminal

### Install

Pick one:

- **From the app.** Open Compose and click **Install** on the "Compose in the terminal" card, or use **Install the container compose Command** in the More menu of an open stack. macOS asks for your admin password once. The app never installs it on its own.
- **From a checkout.** Run `scripts/install_compose_plugin.sh`. It builds the plugin as you, then copies it into place with `sudo`. Use `--uninstall` to remove it.

The plugin lives where Apple's CLI looks for user plugins:

```
/usr/local/libexec/container-plugins/compose/bin/compose
/usr/local/libexec/container-plugins/compose/config.toml
```

Check it with `container compose version`. The container services must be running (`container system start`), since Apple's CLI only loads plugins then.

**After a `container` upgrade.** Apple's installer clears the plugin folder on every upgrade. The app notices that the command it installed is gone and offers to put it back. From a checkout, run the install script again.

### Commands

```
container compose [OPTIONS] COMMAND
```

| Command | What it does |
| --- | --- |
| `up [SERVICE...]` | Create and start services. Without `-d` it follows the logs until Ctrl+C, then stops the services. |
| `down` | Stop and remove the project containers and networks. |
| `ps [SERVICE...]` | List the project containers with state, address and ports. Stopped containers are listed too. |
| `logs [SERVICE...]` | Show logs, one prefix per service. |
| `start`, `stop`, `restart` `[SERVICE...]` | Start, stop or restart services. Stop uses `stop_signal` and `stop_grace_period`. |
| `pull [SERVICE...]` | Pull the images of the services. Services with a `build` section are skipped. |
| `exec SERVICE COMMAND...` | Run a command in a running service. |
| `config` | Print the project with every file merged, variables filled in, paths made absolute and the names Up uses. |
| `version` | Print the version. |

Global options:

| Option | Meaning |
| --- | --- |
| `-f, --file FILE` | Compose file. Repeatable. Later files merge on top of earlier ones. |
| `-p, --project-name NAME` | Project name. |
| `--project-directory DIR` | Folder to look for the compose file in. |
| `--env-file FILE` | Read variables from this file instead of `.env`. Repeatable, later files win. |
| `--profile NAME` | Turn on a profile. Repeatable. |
| `--dry-run` | Show what would happen. Nothing is changed. Works with `up`, `down`, `start`, `stop`, `restart`, `pull` and `exec`. |

Command options:

| Command | Options |
| --- | --- |
| `up` | `-d, --detach`, `--force-recreate`, `--build`, `--pull missing\|always\|never`, `--remove-orphans` (the default), `--keep-orphans`, `--dry-run` |
| `down` | `-v, --volumes` (anonymous volumes too), `--keep-networks`, `--dry-run` |
| `logs` | `-f, --follow`, `-n, --tail N` |
| `ps` | `-q, --quiet`, `--services` |
| `exec` | `-T, --no-TTY`, `-d, --detach`, `-e, --env KEY=VALUE`, `-u, --user USER`, `-w, --workdir DIR` |
| `config` | `-q, --quiet` (check only), `--services` |

Environment: `COMPOSE_FILE` (with `COMPOSE_PATH_SEPARATOR`), `COMPOSE_PROJECT_NAME`, `COMPOSE_PROFILES`. Set `CONTAINER_CLI` to use a `container` binary that is not on the usual path.

**Finding the file.** Without `-f` or `COMPOSE_FILE`, the command looks for `compose.yaml`, `compose.yml`, `docker-compose.yml` or `docker-compose.yaml` in the current folder, then in each parent folder up to `/`. The first folder with a file wins. An override file next to it (`compose.override.yaml`, `compose.override.yml`, `docker-compose.override.yml` or `docker-compose.override.yaml`) is merged on top. See [Several compose files](#several-compose-files).

**Project name.** `-p` wins, then `COMPOSE_PROJECT_NAME`, then the `name` key, then the folder name. Names are lower case letters, digits, dashes and underscores.

**Exit codes.** 0 when it worked, 1 when something failed (including problems that block Up), 2 for a bad command line, 130 after Ctrl+C.

Examples:

```sh
container compose up -d
container compose up --dry-run
container compose -f deploy/compose.yaml -p shop up -d --pull always web
container compose -f compose.yaml -f compose.prod.yaml config
container compose logs -f --tail 50 api
container compose exec db psql -U postgres
container compose down -v
```

Output is plain text. Steps start with `=>`, command output is indented with a service prefix, warnings and errors go to stderr.

## Using it in the app

Open a compose file or a folder that has one. When a `compose.override.yaml` sits next to it, the app merges it and shows a "with compose.override.yaml" pill next to the project name. To merge other files, pick them together in the Import panel (or drop them together). The main file comes first, override files last, and the rest in the order picked. Recent files remember the whole list.

The **Problems** tab lists everything in the file that will not work here, with the line number. In a project made of several files each problem shows `file:line`, and a click opens that file at that line. Problems marked "Needs a fix" block Up.

The More menu next to Up holds the Up options:

- **Keep Orphans.** Up removes containers whose service left the file. Turn this on to keep them.
- **Keep Networks on Down.**
- **Pull Images.** As the file says (each service's `pull_policy`), when missing, always or never.
- **Dry Run.** Shows what Up would do on this Mac in the Activity tab and changes nothing. The Commands tab has the same button next to the list of commands Up runs.

Hook output shows in the Activity tab under the service name.

## Key support

**Supported** means the key works as in Docker Compose, with the notes given. **Not possible** means Apple's runtime cannot do it. **Not built yet** means the runtime could, Container Deck does not do it yet. Keys starting with `x-` are ignored. Anything unknown is listed under Problems. Only errors (marked "Needs a fix" in the app, `error:` in the terminal) stop Up. A key that is not possible or not built yet is listed and left out, and Up goes on without it.

### Top level

| Key | Status | Notes |
| --- | --- | --- |
| `name` | Supported | |
| `version` | Supported | Ignored, as in Docker Compose. |
| `services` | Supported | |
| `networks` | Supported | `name`, `external`, `internal`, `ipam.config[0].subnet`, `driver: bridge`. Only the first subnet is used. |
| `networks.*.driver` (other than bridge) | Not possible | Apple's runtime has one network driver. |
| `networks.*.driver_opts`, `enable_ipv6`, `labels` | Not built yet | |
| `volumes` | Supported | `name`, `external`, `labels`, `driver: local`. |
| `volumes.*.driver` (other than local) | Not possible | Only local volumes exist. |
| `volumes.*.driver_opts` | Not built yet | |
| `secrets`, `configs` | Not built yet | |
| `include` | Supported | Short form and long form with `path` (one file or a list), `project_directory` and `env_file`. See [include](#include). |

### Services

| Key | Status | Notes |
| --- | --- | --- |
| `image` | Supported | |
| `build` | Supported | `context`, `dockerfile`, `args`, `target`. Other build options (`dockerfile_inline`, `cache_from`, `no_cache`, `ssh`, `secrets`, `labels`, `tags`, `platforms` and so on) and remote contexts are not built yet and are listed under Problems. Builds show on the Builds screen. |
| `command`, `entrypoint` | Supported | `entrypoint: []` drops the image entrypoint when the service sets a `command`. Without a `command` the image entrypoint stays. |
| `environment`, `env_file` | Supported | `env_file` long form with `required`. Values without `=` come from your shell. |
| `ports` | Supported | Short and long form, ranges, host IP, udp. A host port is required. Without one the container port is used. |
| `expose` | Supported | Nothing to do. Every port is reachable on the container address. |
| `volumes` | Supported | Bind mounts, named volumes, anonymous volumes (`- /data` and long form without `source`), long form `type: tmpfs` with `size` and `mode`, `read_only` and `:ro`. `volume.subpath` is not built yet. Other long form options (`bind.propagation`, `volume.nocopy`, `consistency`) are ignored. |
| `tmpfs` | Supported | `/run` or `/run:size=64m`. |
| `networks` | Supported | The first network is used. `aliases` and `mac_address` work. Other per network options are not built yet. |
| `network_mode` | Supported for `bridge` | Other modes are not possible. Each container gets its own address. |
| `depends_on` | Supported | `service_started`, `service_healthy`, `service_completed_successfully`, `required`. `restart` is not built yet. |
| `healthcheck` | Supported | `test`, `interval`, `timeout`, `retries`, `start_period`, `disable`. Run with `container exec` while dependents wait. `ps` shows no health. A healthcheck without `test` would use the image's own HEALTHCHECK, which is not read yet, so it is listed under Problems. |
| `profiles` | Supported | |
| `labels`, `deploy.labels` | Supported | |
| `container_name` | Supported | |
| `working_dir` | Supported | |
| `user` | Supported | |
| `read_only` | Supported | |
| `init` | Supported | |
| `cap_add`, `cap_drop` | Supported | |
| `dns`, `dns_search`, `dns_opt` | Supported | |
| `shm_size` | Supported | |
| `ulimits` | Supported | A single number sets soft and hard. |
| `mac_address` | Supported | Applies to the first network. |
| `stop_signal`, `stop_grace_period` | Supported | Used by `stop`, `restart`, `down` and recreate. Saved as labels, so they also work without the file. |
| `pull_policy` | Supported | `always`, `never`, `missing`, `if_not_present`, `build`. `daily`, `weekly` and `every_*` are not built yet and act like `missing`. |
| `post_start`, `pre_stop` | Supported | `command`, `environment`, `working_dir`, `user`. Run with `container exec`. `privileged: true` is refused. |
| `cpus`, `deploy.resources.limits.cpus` | Supported | Rounded up to whole CPUs. Each container is a small VM. |
| `mem_limit`, `deploy.resources.limits.memory` | Supported | |
| `platform` | Supported | `linux/amd64` runs with Rosetta. |
| `extra_hosts` | Supported | Written to `/etc/hosts` right after the container starts, so the image needs `/bin/sh`. `host-gateway` is not built yet. Apple's CLI has no `--add-host` flag. |
| `restart` | `no` only | Other policies are not possible. Containers do not restart on their own. |
| `deploy.replicas` | Not built yet | One container runs. |
| `deploy.resources.reservations`, `deploy.restart_policy` | Not possible | |
| `privileged` | Not possible | Each container runs in its own small VM. |
| `devices`, `device_cgroup_rules`, `gpus` | Not possible | Host devices cannot be passed to a container. |
| `ipc`, `pid`, `uts` | Not possible | Each container has its own kernel, so these cannot be shared. |
| `userns_mode`, `cgroup`, `cgroup_parent`, `runtime`, `isolation` | Not possible | |
| `security_opt`, `sysctls` | Not possible | Apple's CLI has no way to set them. |
| `oom_kill_disable`, `oom_score_adj`, `mem_swappiness`, `memswap_limit`, `mem_reservation` | Not possible | Use `mem_limit`. |
| `cpu_shares`, `cpu_quota`, `cpu_period`, `cpuset`, `cpu_count`, `cpu_percent`, `cpu_rt_runtime`, `cpu_rt_period` | Not possible | Use `cpus`. |
| `blkio_config`, `storage_opt`, `pids_limit` | Not possible | |
| `logging` | Not possible | Logs stay with the container tool. |
| `volumes_from` | Not possible | Share a named volume instead. |
| `hostname`, `domainname` | Not built yet | The hostname is the container name. Apple's CLI has no hostname flag. |
| `stdin_open`, `tty`, `attach` | Not built yet | Use `exec` or the Terminal button. |
| `secrets`, `configs` | Not built yet | |
| `extends` | Supported | From the same file or from another file. See [extends](#extends). |
| `scale` | Not built yet | |
| `annotations`, `group_add`, `credential_spec`, `label_file` | Not built yet | |
| `links`, `external_links` | Not built yet | Services still reach each other by name. |
| `develop` (watch) | Not built yet | |
| `use_api_socket`, `provider`, `models` | Not built yet | |

## Several compose files

A project can be made of more than one file, as in Docker Compose.

- **`-f` flags.** `container compose -f compose.yaml -f compose.prod.yaml up -d` reads both files and merges the second on top of the first. Add as many as you need. With `-f`, only the files you name are read.
- **`COMPOSE_FILE`.** A list of files separated by `:`, for example `COMPOSE_FILE=compose.yaml:compose.prod.yaml`. Set `COMPOSE_PATH_SEPARATOR` to use another separator. Relative paths start in the current folder (or `--project-directory`).
- **The override file.** Without `-f` and `COMPOSE_FILE`, the override file next to the compose file is merged on top of it.

`container compose config` prints the merged result, which is the best way to check what Up will run.

### Merge rules

Files merge in order. Each one can add to, change or remove what the files before it set. The rules follow the [Compose Specification](https://docs.docker.com/reference/compose-file/merge/):

| What | How it merges |
| --- | --- |
| Maps (a service, `healthcheck`, `deploy`, top level `networks` and `volumes`) | Key by key, all the way down. Keys only in the later file are added. |
| Single values (`image`, `user`, `mem_limit` and so on) | The later file wins. A key with no value keeps the earlier value. |
| `command`, `entrypoint`, `healthcheck.test` | Replaced by the later file, never appended. |
| `ports` | Added together. Two entries with the same host IP, host port, container port and protocol count once. |
| `expose`, `external_links`, `dns`, `dns_search`, `dns_opt`, `tmpfs`, `cap_add`, `cap_drop`, `profiles` | Added together without duplicates. |
| `volumes`, `devices` | By the path inside the container. A later entry for the same path replaces the earlier one in place. |
| `environment`, `labels`, `build.args`, `deploy.labels`, `sysctls` | By key. List form (`KEY=value`) and map form (`KEY: value`) mix freely. |
| `depends_on` | By service. A list entry counts as `condition: service_started` and `required: true`. |
| `networks` of a service | By network name. List form and map form mix freely. |
| `extra_hosts` | By host name. The later address wins. |
| `env_file` | Added together, one entry per path. |
| `build` | Merged as a map. `build: ./app` reads as `build: {context: ./app}`. |
| `ulimits` | Per limit. Soft and hard values merge when both files use the long form. |
| Other lists | Added together without exact duplicates. |

Two YAML tags from Compose 2.24 change a single value:

```yaml
# compose.override.yaml
services:
  web:
    ports: !reset []          # remove every port from the earlier files
    environment:
      DEBUG: !reset null      # remove one variable
    labels: !override         # replace the labels instead of merging them
      tier: frontend
```

- `!reset` removes the value. The value written after the tag is ignored. `!reset null` or `!reset []` reads best.
- `!override` replaces the value and skips the merge rules above.

### Relative paths

Relative paths in `-f` files and in the override file resolve against the project directory, which is the folder of the first file (or `--project-directory`). This matches Docker Compose: an override file in `deploy/` that mounts `./data` mounts the `data` folder next to the first file. The `.env` file is read from the project directory too.

Files read through `include` and `extends` are different. Their paths resolve against their own folder.

### Problems in several files

Every problem carries the file it comes from. The terminal prints `file:line`, for example `not possible: compose.override.yaml:12: services.web.privileged: ...`, with the path relative to the current folder. The app's Problems tab shows the same and opens the right file.

### include

```yaml
include:
  - ../shared/db.yaml
  - path: [monitoring/compose.yaml, monitoring/compose.local.yaml]
    project_directory: monitoring
    env_file: monitoring/.env
services:
  web:
    image: nginx
    depends_on: [db]
```

Each entry is loaded as its own project: its files merge as with `-f`, its relative paths resolve against its own folder (or `project_directory`), and its variables come from its own `.env` (or `env_file`) plus your shell. Its services, networks, volumes, secrets and configs are then added to this project. A name that is already defined here with different settings is a problem that blocks Up, and this file's definition is kept. Included files can include other files. A loop is reported as a problem.

### extends

```yaml
services:
  base:
    image: alpine
    environment: [LOG=info]
  worker:
    extends: base
    command: ["worker"]
  api:
    extends:
      file: common/services.yaml
      service: api
    ports: ["8080:80"]
```

The service starts from the one it extends, then its own settings merge on top with the merge rules above. `extends` can name a service in the same file or, with `file`, in another file. Chains work. Paths in another file resolve against that file's folder. A missing service, a missing file or a loop is a problem that blocks Up.

## Lifecycle hooks

```yaml
services:
  web:
    image: nginx:alpine
    post_start:
      - command: ["sh", "-c", "echo ready > /tmp/ready"]
        user: root
        environment:
          STAGE: boot
    pre_stop:
      - command: nginx -s quit
```

- `post_start` hooks run in order right after the container starts, on Up, `start` and `restart`. A failing hook stops Up with an error and the services after it are not started.
- `pre_stop` hooks run before the container stops, on `stop`, `restart`, `down` and when Up recreates a service. A failing `pre_stop` hook is reported and the stop goes ahead.
- Hooks do not run for services that were already running and did not change.
- Hook output shows in the app's Activity tab and in the terminal.

## Anonymous volumes

An anonymous volume such as `- /data` gets a stable name: `<project>_<service>_anon_<8 hex characters>`, where the hex part comes from the path inside the container. The same file gives the same name, so the data survives a recreate and a second Up. `down -v` removes these volumes together with the named ones. A plain `down` keeps them.

## Differences from Docker Compose

- **Service names come from `/etc/hosts`.** Apple's runtime does not resolve plain service names between containers, so Container Deck writes each service's address into `/etc/hosts` in every container on Up, `start` and `restart`. Each service answers to its name, `<project>-<service>`, its `container_name` and its aliases. This runs a small shell script in each container, so the image needs `/bin/sh`. For an image without a shell (distroless, `scratch`) you get a warning, and that container cannot reach the others by name.
- **One network per container.** Only the first network a service lists is used. On macOS 15 only the default network exists, so services fall back to it and still find each other by name.
- **Orphans are removed by default** on Up. Docker Compose only warns unless you pass `--remove-orphans`. Use `--keep-orphans` (or Keep Orphans in the app) to keep them.
- **Host ports are required.** Random host ports are not built yet. A port without a host part uses the same number on the Mac.
- **CPU limits are whole numbers.** `cpus: 0.5` becomes 1.
- **No restart policies.** Containers do not restart on their own.
- **Stops wait 5 seconds by default**, which is Apple's default, not 10. Set `stop_grace_period` to change it.
- **`--pull` wins over `pull_policy`.** Without `--pull`, each service's `pull_policy` applies, and missing images are pulled.
- **Stacks from other tools.** Containers with Docker Compose labels show up too. Up recreates them with Container Deck labels.
- **Hooks run with `container exec`.** Privileged hooks are not possible.

## For developers

The engine is in `Sources/DeckCore/Compose`:

| File | Role |
| --- | --- |
| `ComposeLoader.swift` | Reads the files of a project, merges them, applies `include` and `extends`, and keeps track of which file each line came from. |
| `ComposeMerge.swift` | The merge rules, `!reset` and `!override`. |
| `ComposeParser.swift` | The merged YAML to `ComposeProject`, with a problem for every key that will not work. |
| `ComposeInterpolation.swift` | `${VAR}` forms, `.env` and `env_file`. |
| `ComposePlanner.swift` | Project to `ComposePlan`: names, run options, anonymous volumes, the config hash. |
| `ComposeRunner.swift` | Up, down, start, stop, restart, pull, ps, logs. |
| `ComposeLifecycle.swift` | Hooks, stop signals, pull policies, orphans, dry run. |
| `ComposeCLI.swift` | The `container compose` command: arguments, file discovery, output. |
| `ComposeConfigWriter.swift` | YAML for `container compose config`. |
| `ComposePluginInstaller.swift` | Status, install and removal of the plugin from the app. |

`Sources/ContainerCompose/main.swift` is the plugin binary (SwiftPM target `container-compose`). `scripts/bundle.sh` copies it into the app at `Contents/MacOS/container-compose`.

Tests: `Tests/DeckCoreTests/ComposeGapsTests.swift`, `ComposeCLITests.swift` and `ComposeMergeTests.swift` (merge rules, several files, `include`, `extends`). The live tests run with `DECK_LIVE_COMPOSE=1` (or `DECK_INTEGRATION=1`) against the real CLI and the built plugin binary, without installing anything system wide. Build the plugin first with `swift build --product container-compose`.
