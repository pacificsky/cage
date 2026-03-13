# cage

Run coding agents safely without restrictions in isolated Docker containers on macOS.

## Install

Requires Docker (or [colima](https://github.com/abiosoft/colima)) running on your Mac.

```bash
brew tap pacificsky/tap
brew install cage
```

## Quick Start

```bash
cd ~/src/my-project
cage start                # create container and enter it
cage start -p 3000:3000   # with port forwarding
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

The shared home volume persists across all containers. Claude credentials, git config, shell history, and tool state all live here — configure once, share everywhere.

## Image Updates

cage automatically pulls the latest image when creating a new container. When re-attaching to an existing container, it warns if a newer image is available:

```
cage: A newer image is available. Run 'cage upgrade' to upgrade.
```

`cage update` pulls the latest image. `cage upgrade` pulls and recreates the container.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CAGE_IMAGE` | `ghcr.io/pacificsky/devcontainer-lite:latest` | Container image |

Set `CAGE_IMAGE` to a local image name to skip remote pulls entirely.

## Environment Files

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

## Run from Source

If you want to hack on cage itself instead of installing via Homebrew:

```bash
git clone git@github.com:pacificsky/cage.git
cd cage
ln -s "$(pwd)/cage.sh" /usr/local/bin/cage
```

## License

MIT
