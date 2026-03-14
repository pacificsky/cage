# cage

[![Test cage.sh](https://github.com/pacificsky/cage/actions/workflows/test.yml/badge.svg)](https://github.com/pacificsky/cage/actions/workflows/test.yml)
[![Integration tests](https://github.com/pacificsky/cage/actions/workflows/integration.yml/badge.svg)](https://github.com/pacificsky/cage/actions/workflows/integration.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Live the `--dangerously-skip-permissions` life

Cage runs coding agents in isolated Docker containers on macOS or Linux. Your project is mounted read-write at the same absolute path — error messages, file references, and tooling all just work.

Requires Docker (Engine or Desktop) or [colima](https://github.com/abiosoft/colima) or [podman](https://podman.io/docs/installation).

## Install

### Homebrew (macOS and Linux)

```bash
brew install pacificsky/tap/cage
```

### Without Homebrew

```bash
curl -fsSL https://raw.githubusercontent.com/pacificsky/cage/main/install.sh | sh
```

Installs to `~/.local/bin`. Run the same command to update. To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/pacificsky/cage/main/install.sh | sh -s -- --uninstall
```

## Quick Start

```bash
cd ~/src/my-project
cage start                # create project-specific container and enter it
claude --dangerously-skip-permissions
```

Running `cage start` again from the same directory re-attaches to the existing container.

## Commands

| Command | Description |
|---------|-------------|
| `cage start` | Create or re-attach to container for current directory |
| `cage stop` | Stop the container |
| `cage rm` | Remove the container (volumes preserved) |
| `cage restart` | Remove and recreate container (volumes preserved) |
| `cage update` | Pull latest container image |
| `cage upgrade` | Pull latest image and recreate container |
| `cage status` | Show container name, state, and port mappings |
| `cage list` | List all cage containers across projects |
| `cage shell` | Open an additional shell in a running container |
| `cage rmconfig` | Stop all containers and remove shared home volume |
| `cage obliterate` | Remove all cage containers and shared home volume |

## Examples

```bash
# Start a container with port forwarding
cage start -p 3000:3000

# Multiple ports
cage start -p 3000:3000 -p 5432:5432

# Open a second shell while an agent is running
cage shell

# Check what's running across all projects
cage list

# Update to the latest container image
cage upgrade

# Start fresh (removes container, keeps volumes)
cage restart
```

## How It Works

### Mounts

| Host | Container | Purpose |
|------|-----------|---------|
| Project directory | Same absolute path | Code editing, matching error paths |
| `cage-home` (Docker volume) | `/home/vscode` | Shared home dir across all cages |
| SSH agent socket | `/run/host-services/ssh-auth.sock` | SSH agent forwarding |

### Shared Home

The `cage-home` volume is shared across all cage containers and projects. Claude credentials, git config, shell history, and tool state all live here — configure once, share everywhere.

### Image Updates

Cage automatically pulls the latest image when creating a new container. When re-attaching to an existing container, it warns if a newer image is available:

```
cage: A newer image is available. Run 'cage upgrade' to upgrade.
```

`cage update` pulls the latest image. `cage upgrade` pulls and recreates the container.

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CAGE_IMAGE` | `ghcr.io/pacificsky/devcontainer-lite:latest` | Container image |

Set `CAGE_IMAGE` to a local image name to skip remote pulls entirely.

### Environment Files

Inject environment variables into containers using env files:

| File | Scope | Description |
|------|-------|-------------|
| `~/.config/cage/env` | Global | Applied to all cage containers |
| `.cage.env` | Per-project | Applied to the current project's container |

Both use Docker's env-file format (`KEY=VALUE`, `#` comments, blank lines). Per-project values override global values.

```bash
# ~/.config/cage/env
ANTHROPIC_API_KEY=sk-ant-...

# ~/src/my-project/.cage.env
DATABASE_URL=postgres://localhost/mydb
```

Env files are read at container creation time. After changes: `cage rm && cage start`.

### Seed Directory

`~/.config/cage/home/` contents are copied into `/home/vscode/` on new container creation (no-clobber — existing files are never overwritten). Use this to pre-populate dotfiles, shell config, or tool settings.

## Run from Source

```bash
git clone git@github.com:pacificsky/cage.git
cd cage
ln -s "$(pwd)/cage.sh" /usr/local/bin/cage
```

## License

MIT
