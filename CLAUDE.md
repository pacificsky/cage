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

### Seed Directory

`~/.config/cage/home/` contents are copied into `/home/vscode/` on new container creation using `cp -n` (no-clobber). Existing files in the shared volume are never overwritten. The seed runs on every path that creates a new container: `start` (new), `restart`, and `upgrade`.

### Environment Files

cage injects environment variables from env files into containers at creation time using Docker's `--env-file` flag.

- Global: `~/.config/cage/env` — applied to all cage containers
- Per-project: `.cage.env` in the project directory — applied to that project's container only

Both files use Docker env-file format: `KEY=VALUE` lines, `#` comments, blank lines. Per-project values override global for duplicate keys. Both are optional and silently skipped if absent. Only read at container creation; changes require `cage rm && cage start`.

### Testing

- **Unit tests** (`tests/test_cage.sh`): Mock-based, no container runtime needed. Fast CI gate on every push.
- **Integration tests** (`tests/test_integration.sh`): Run against a real container runtime (Docker or Podman). Uses `ubuntu:24.04` as a lightweight test image. Triggered on push to main + manual dispatch.

### Key Design Decisions

- CWD = project dir (no git-root detection)
- Docker label `cage.project=$PROJECT_DIR` on each container for listing
- Port flags (`-p`) collected before subcommand, forwarded to `docker create`
- Re-attach: running → attach, stopped → start -ai, none → create + seed + start
- Runtime detection: prefers `docker`, falls back to `podman`; all commands use `$DOCKER` variable
