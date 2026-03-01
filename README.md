# cage

Run coding agents safely without restrictions in isolated Docker containers on macOS.

cage wraps Docker to manage containers built from the [devcontainer-lite](https://github.com/pacificsky/devcontainer-lite) image. Your project is mounted at its original absolute path so error messages and paths match your host. Run Claude Code or Codex with `--dangerously-skip-permissions` without risk to your host system.

## Install

```bash
git clone git@github.com:pacificsky/cage.git
cd cage
ln -s "$(pwd)/cage.sh" /usr/local/bin/cage
```

Requires Docker (or [colima](https://github.com/abiosoft/colima)) running on your Mac.

## Quick Start

```bash
cd ~/src/my-project
cage start                # create container and enter it
cage start -p 3000:3000   # with port forwarding
```

Running `cage start` again from the same directory re-attaches to the existing container — no new container is created.

## Commands

| Command | Description |
|---------|-------------|
| `cage start` | Create or re-attach to container for current directory |
| `cage stop` | Stop the container |
| `cage rm` | Remove the container (volumes preserved) |
| `cage restart` | Remove and recreate container (volumes preserved) |
| `cage update` | Pull latest image and recreate container |
| `cage rmconfig` | Stop all containers and remove shared home volume |
| `cage obliterate` | Remove all cage containers and shared home volume |
| `cage status` | Show container name, state, and port mappings |
| `cage list` | List all cage containers across projects |
| `cage shell` | Open an additional shell in a running container |

## What Gets Mounted

| Host | Container | Purpose |
|------|-----------|---------|
| Project directory | Same absolute path | Code editing, matching error paths |
| `cage-home` (Docker volume) | `/home/vscode` | Shared home dir across all cages |
| SSH agent socket | `/run/host-services/ssh-auth.sock` | SSH agent forwarding |

The shared home volume is auto-initialized from the image on first use and persists across all containers. Claude credentials, git config, shell history, and tool state all live here — configure once, share everywhere.

## Image Updates

cage automatically pulls the latest image when creating a new container. When re-attaching to an existing container, it warns if a newer image is available locally:

```
cage: A newer image is available. Run 'cage.sh update' to upgrade.
```

`cage update` pulls the latest image and recreates the container.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CAGE_IMAGE` | `ghcr.io/pacificsky/devcontainer-lite:latest` | Container image |

Set `CAGE_IMAGE` to a local image name to skip remote pulls entirely.

## License

MIT
