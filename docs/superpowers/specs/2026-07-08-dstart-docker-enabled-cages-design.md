# Design: `cage dstart` — docker-enabled cages

**Date:** 2026-07-08
**Status:** Approved

## Problem

cage runs a coding agent inside a single container per project. For multi-service
projects (full-stack apps orchestrated with docker compose), the agent needs full
lifecycle control over the project's service containers — `compose up/down/build`,
logs, exec — but it has no container runtime inside its cage. Docker-in-docker is
ugly; we want a first-class answer.

## Decision summary

Give the agent a docker socket, and let the **platform** decide which daemon that
socket controls:

- **Linux:** the host daemon's socket (trusted mode). Docker engine is the
  near-universal default on Linux; users accept host-level trust. A prominent
  warning banner explains the exposure.
- **macOS:** a **dedicated, mount-restricted colima VM** (contained mode). The
  Docker Desktop socket would expose the user's file-shared home directory, which
  is categorically worse — so on macOS, dstart requires colima and never touches
  any other runtime's socket.

Rejected alternatives:

- **DinD sidecar** (private `docker:dind` per project): best cross-platform
  isolation, but requires a privileged sidecar, duplicates image caches, and adds
  the bulk of the implementation complexity. Cut.
- **Nested rootless podman in the cage image:** chronic compose/networking
  compatibility jank, image bloat for all users. Rejected.
- **Interactive mode picker / `--trust` flag:** no menus. `dstart` gives you the
  safest thing your platform supports, deterministically.

Key insight that makes both modes work: cage already mounts the project at the
**same absolute path** as the host, and colima preserves host paths inside its VM.
Compose files with relative bind mounts (`./src:/app/src`) therefore resolve
correctly whether the daemon is the Linux host or the colima VM.

## CLI surface

- `cage dstart` — identical to `start`, but the container is created
  docker-enabled. Accepts the same pre-subcommand flags (`-p`, `-v`).
- Docker-enablement is a **creation-time property**, like `-p`:
  - `dstart` on an existing non-docker container: re-attach, with an info line
    ("container exists without docker — use `cage rm` to recreate").
  - `start` on an existing docker-enabled container: re-attach silently.
- Mode is recorded as a container label `cage.docker=host|colima` at creation.
  Every subcommand routes/reports by this label.
- `cage status` gains a `docker:` line: `none` / `host` / `colima`.

## Platform behavior

### Linux (trusted mode)

- Mount the detected runtime's socket into the cage container:
  - docker: `/var/run/docker.sock:/var/run/docker.sock`
  - podman: the podman socket (rootful `/run/podman/podman.sock` or rootless
    `$XDG_RUNTIME_DIR/podman/podman.sock`), mounted at `/var/run/docker.sock`
    in-container so the docker CLI works unchanged.
- Print a prominent banner (same visual treatment as the existing enter/exit
  banners): the agent holds the docker socket, which is root-equivalent on this
  machine. No confirmation prompt.

### macOS (contained mode)

- Requires `command -v colima`. If absent, fail with an actionable message:
  install via `brew install colima`; support for other runtimes (Docker Desktop,
  OrbStack) can be requested at github.com/pacificsky/cage issues. The message
  explains *why*: those runtimes' sockets expose the user's file-shared home
  directory.
- cage owns a dedicated colima profile named `cage` (docker context
  `colima-cage`). It does not matter what the user's default context or daily
  runtime is — dstart always uses this profile, never the default colima profile
  (which mounts `$HOME`).
- **All** docker commands for a dstart'd project run against the `colima-cage`
  context: the agent container itself, everything the agent spawns, and that
  daemon's own `cage-home` volume live inside the VM. (A socket cannot be
  bind-mounted across VMs, so the agent container must live in the same VM as
  the daemon it controls.)
- First `dstart` auto-provisions the VM with an informational banner explaining
  the one-time wait (~1 minute).

## The restricted VM profile (macOS)

- Created as:
  `colima start cage --mount "$CAGE_SRC_ROOT:w" --ssh-agent --cpu $CAGE_VM_CPU --memory $CAGE_VM_MEMORY`
- Config knobs (read from the environment / `~/.config/cage/env`, consistent
  with existing cage knobs):
  - `CAGE_SRC_ROOT` — single source root mounted into the VM. Default: `~/src`.
  - `CAGE_VM_CPU` — default 4.
  - `CAGE_VM_MEMORY` — default 8 (GB). Colima's stock 2 CPU / 2 GB is too small
    for an agent plus a compose stack.
- If the profile exists but is stopped, `dstart` boots it (`colima start cage`).
- Guard: `dstart` for a project outside `$CAGE_SRC_ROOT` fails with a hint to
  set `CAGE_SRC_ROOT`. Changing `CAGE_SRC_ROOT` after the VM exists requires
  `colima delete cage` (VM mounts are fixed at start); the guard's error message
  includes this when the profile already exists.
- `--ssh-agent` forwards the host SSH agent into the VM; the VM-side agent
  socket is mounted into the cage container (this replaces the Docker
  Desktop-specific socket path used by the current macOS branch when in colima
  mode).

## Container creation changes

- Add the socket mount and the `cage.docker` label.
- Add `--group-add <gid of the socket>` so the non-root `vscode` user can use
  the socket. The gid is discovered at creation time (e.g. a one-shot
  `docker run --rm -v <sock>:/s <img> stat -c %g /s`, or `stat` on the host
  socket path on Linux).
- **Image prerequisite:** the default image (`devcontainer-lite`) must ship the
  docker CLI + compose plugin. If `docker` is absent in the container, dstart
  proceeds but prints a warning naming the required image change.
- Documented consequence (macOS): the colima VM's daemon has its **own**
  `cage-home` volume — first dstart requires a one-time re-login to Claude. The
  seed directory (`~/.config/cage/home/`) applies as usual.

## Lifecycle & networking

- `cage list` queries the `colima-cage` context in addition to the default one
  when the profile exists.
- `rm` / `stop` / `shell` / `restart` / `status` route to the right daemon by
  the `cage.docker` label (macOS: try default context, then `colima-cage`).
- `cage rm` does **not** `compose down` the agent's services — the agent's
  containers outlive the cage container. Documented. On macOS,
  `colima delete cage` is the nuke-everything option.
- `cage obliterate` covers cage containers and home volumes in **both** daemons,
  and prints a hint that `colima delete cage` removes the VM wholesale.
- Reaching services from inside the cage: the agent self-joins a compose network
  with `docker network connect <network> $(hostname)`. Documented pattern; no
  helper tooling in v1.
- Browser access from the Mac: colima forwards published ports to Mac
  localhost, so `-p` flags on the cage container are rarely needed in colima
  mode.

## Error handling

- macOS without colima → fail with install + GH-issues message (see above).
- Project outside `$CAGE_SRC_ROOT` (macOS) → fail with hint; mention
  `colima delete cage` if the profile already exists.
- Colima profile fails to start → surface colima's error verbatim, plus a hint
  to try `colima delete cage` for a corrupt profile.
- Runtime is podman on macOS → same failure as "no colima" (contained mode is
  colima-only).
- `docker` CLI missing inside the container → warning, not fatal.

## Testing

- **Unit** (`tests/test_cage.sh`, mock-based): platform mode selection, colima
  detection and profile-creation arguments, `cage.docker` label handling,
  src-root guard, banner emission, re-attach info paths (`dstart` on non-docker
  container and vice versa).
- **Integration** (`tests/test_integration.sh`, Linux CI): real trusted-mode
  path — `dstart`, then run `docker ps` from inside the cage container against
  the mounted socket.
- The colima path is unit-mocked only (no macOS VM available in CI).

## Documentation

README gains a "Docker inside your cage" section: what `dstart` does per
platform, the security model in plain language (what the agent can and cannot
reach in each mode), the compose workflow, the network self-join pattern, and
the `CAGE_SRC_ROOT` / VM sizing knobs.
