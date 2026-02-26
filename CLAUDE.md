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
| `~/.claude` | `/home/vscode/.claude` | rw | CC config for vscode user |
| `~/.claude` | `$HOME/.claude` | rw | Resolve absolute-path plugin/skill refs |
| `~/.ssh` | `/home/vscode/.ssh` | ro | Git access |
| `~/.config/cage/.claude-credentials.json` | `/home/vscode/.claude/.credentials.json` | ro | Only if file exists |

### Subcommands

- `cage.sh` — create or re-attach (default)
- `cage.sh -p 3000:3000` — create with port forwarding
- `cage.sh stop` — stop container
- `cage.sh rm` — stop and remove container
- `cage.sh status` — show state and ports
- `cage.sh list` — list all cage containers
- `cage.sh shell` — open additional bash shell

### Environment Variables

- `CAGE_IMAGE` — override container image (default: `ghcr.io/pacificsky/devcontainer-lite:latest`)
- `DOCKER_CONTEXT` — override Docker context if needed

### Key Design Decisions

- CWD = project dir (no git-root detection)
- Docker label `cage.project=$PROJECT_DIR` on each container for listing
- Conditional credentials mount (only if file exists)
- Port flags (`-p`) collected before subcommand, forwarded to `docker run`
- Re-attach: running → attach, stopped → start -ai, none → run
