# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**cage** — Tools to run coding agents safely without restrictions in Apple containers on macOS.

MIT licensed.

## Repository

- Remote: `git@github.com:pacificsky/cage.git`
- Main branch: `main`

## Architecture

Single bash script (`cage.sh`) that wraps Docker/Podman to manage isolated containers for running Claude Code or Codex with `--dangerously-skip-permissions`. Prefers `docker`, falls back to `podman` automatically.

### Container Naming

Deterministic: `cage-<dirname>-<8char-sha256-of-absolute-path>`. Example: `/Users/aakash/src/cage` → `cage-cage-5d780152`.

### Docker Mounts

| Host | Container | Mode | Purpose |
|------|-----------|------|---------|
| `$PROJECT_DIR` | `$PROJECT_DIR` | rw | Same absolute path — error messages match host |
| `cage-home` (shared Docker volume) | `/home/vscode` | rw | Shared home dir across all cages (Claude config, creds, shell state) |
| SSH agent socket | `/run/host-services/ssh-auth.sock` | rw | SSH agent forwarding (Docker Desktop) |

### Subcommands

- `cage.sh start` — create or re-attach (default)
- `cage.sh start -p 3000:3000` — create with port forwarding
- `cage.sh dstart` — docker-enabled start (Linux: host socket; macOS: colima `cage` VM)
- `cage.sh stop` — stop container
- `cage.sh rm` — stop and remove container
- `cage.sh rmconfig` — stop all containers and remove shared home volume
- `cage.sh obliterate` — remove all cage containers and shared home volume
- `cage.sh status` — show state and ports
- `cage.sh list` — list all cage containers
- `cage.sh shell` — open additional shell in running container
- `cage.sh restart` — remove and recreate container (volumes preserved)
- `cage.sh update` — pull latest image and recreate container

### Environment Variables

- `CAGE_IMAGE` — override container image (default: `ghcr.io/pacificsky/devcontainer-lite:latest`)
- `DOCKER_CONTEXT` — override Docker context if needed
- `CAGE_SRC_ROOT` — source root mounted into the macOS cage VM (default: `~/src`)
- `CAGE_VM_CPU` — CPUs for the macOS cage VM (default: `4`)
- `CAGE_VM_MEMORY` — memory in GiB for the macOS cage VM (default: `8`)
- `CAGE_VM_DISK` — disk in GiB for the macOS cage VM (default: `60`)
  (all of the above also read from `~/.config/cage/env` via `cage_config_get`)

### Seed Directory

`~/.config/cage/home/` contents are copied into `/home/vscode/` on new container creation. The copy runs as root (`docker cp` stages the seed root-owned, and 0600 seeds must still be readable), with the staging dir first chown'd to `/home/vscode`'s owner and `cp -rp --update=none` (no-clobber) preserving that ownership — existing files in the shared volume are never overwritten. The seed runs on every path that creates a new container: `start` (new), `restart`, and `upgrade`.

### Environment Files

cage injects environment variables from env files into containers at creation time using Docker's `--env-file` flag.

- Global: `~/.config/cage/env` — applied to all cage containers
- Per-project: `.cage.env` in the project directory — applied to that project's container only

Both files use Docker env-file format: `KEY=VALUE` lines, `#` comments, blank lines. Per-project values override global for duplicate keys. Both are optional and silently skipped if absent. Only read at container creation; changes require `cage rm && cage start`.

### Mount Files

cage adds extra bind mounts declared in mount files at container creation time, as `-v` flags on `docker create`.

- Global: `~/.config/cage/mounts` — applied to all cage containers
- Per-project: `.cage.mounts` in the project directory — applied to that project's container only

One `docker -v` spec per line. Blank lines and lines starting with `#` are ignored; leading `~/` expands to `$HOME` (start of the spec only — the container home is `/home/vscode`, so expanding a container-side `~` would be a lie). Forms handled in `read_mounts_file`:

- `path` → `path:path` (same absolute path in the container)
- `path::opts` → `path:path:opts` — empty middle field means same path *with* options. Docker rejects an empty container path, so this spelling is free to take on a meaning; it avoids having to maintain a list of known option keywords to disambiguate `path:ro`.
- anything else → passed to Docker verbatim, so named volumes work.

`cmd_enter` rejects a non-absolute container target with a message pointing at the `::` form. That check lives in `cmd_enter`, not `read_mounts_file`, because the latter runs inside a process substitution where `die` could not halt the run.

Precedence when two mounts share a container-side target: command-line `-v` > `.cage.mounts` > global file. `build_mount_args` resolves this by walking the collected specs back to front and skipping targets already claimed. Unlike `-v` flags, mount files are re-read on every container creation, so they survive `restart` and `upgrade`.

### Testing

- **Unit tests** (`tests/test_cage.sh`): Mock-based, no container runtime needed. Fast CI gate on every push.
- **Integration tests** (`tests/test_integration.sh`): Run against a real container runtime, in a CI matrix over **both** Docker and Podman — so avoid Docker-specific `inspect` templates in these tests. Uses `ubuntu:24.04` as a lightweight test image. The workflow fires on every pull request, but the test job only runs when `cage.sh`, `tests/**`, or the workflow file changed (otherwise skipped, and the gate passes as skipped); also runs on path-filtered pushes to main and manual dispatch. Refuse to run on macOS (they execute `obliterate`).

### Docker-Enabled Cages

`cage dstart` creates a container that can run docker/compose. Mode is a creation-time property recorded via the `cage.docker` label (`host` or `colima`).

- **Linux (`host`)**: mounts the host docker socket into the cage (trusted — a red warning banner is printed). Not contained.
- **macOS (`colima`)**: provisions a dedicated colima VM (profile `cage`) via `setup_colima_cage`, mounting only `CAGE_SRC_ROOT`. `DOCKER_HOST` is retargeted to `~/.colima/cage/docker.sock` (`COLIMA_CAGE_SOCK`) so all docker commands for that cage hit the VM's daemon.
- **Cross-daemon routing**: `route_to_container` locates which daemon owns a container so `stop`/`status`/`shell`/etc. reach the cage VM's daemon on macOS.
- **Mode preservation**: `preserve_docker_mode` reads the `cage.docker` label so `restart`/`upgrade` recreate the container in the same mode.
- **Multi-daemon housekeeping**: `list`/`obliterate`/`rmconfig` iterate both daemons; macOS teardown suggests `colima delete --profile cage`.
- `status` prints a `Docker: host|colima|none` line. `check_docker_cli_in_image` warns (non-fatally) if the image lacks the docker CLI.

### Key Design Decisions

- CWD = project dir (no git-root detection)
- Docker label `cage.project=$PROJECT_DIR` on each container for listing
- Port flags (`-p`) collected before subcommand, forwarded to `docker create`
- Re-attach: running → attach, stopped → start -ai, none → create + seed + start
- Runtime detection: prefers `docker`, falls back to `podman`; all commands use `$DOCKER` variable
