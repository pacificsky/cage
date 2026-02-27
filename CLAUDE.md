# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**cage** — Tools to run coding agents safely without restrictions in Apple containers on macOS.

MIT licensed.

## Repository

- Remote: `git@github.com:pacificsky/cage.git`
- Main branch: `main`

## Architecture

Single bash script (`cage.sh`) that wraps Docker to manage isolated containers for running Claude Code or Codex with `--dangerously-skip-permissions`.

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

### Key Design Decisions

- CWD = project dir (no git-root detection)
- Docker label `cage.project=$PROJECT_DIR` on each container for listing
- Port flags (`-p`) collected before subcommand, forwarded to `docker run`
- Re-attach: running → attach, stopped → start -ai, none → run
