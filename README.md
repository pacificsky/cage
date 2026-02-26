# cage

Run coding agents safely without restrictions in isolated Docker containers on macOS.

cage wraps Docker to spin up containers with the [devcontainer-lite](https://github.com/pacificsky/devcontainer-lite) image, mounting your project and credentials so you can run Claude Code or Codex with `--dangerously-skip-permissions` without risk to your host system.

## Install

```bash
# Clone the repo
git clone git@github.com:pacificsky/cage.git
cd cage

# Optional: add to PATH
ln -s "$(pwd)/cage.sh" /usr/local/bin/cage
```

Requires Docker (or [colima](https://github.com/abiosoft/colima)) running on your Mac.

## Usage

```bash
# Start or re-attach to a container for the current directory
./cage.sh

# Start with port forwarding
./cage.sh -p 3000:3000 -p 8080:8080

# Show container status
./cage.sh status

# List all cage containers
./cage.sh list

# Open an additional shell in a running container
./cage.sh shell

# Stop the container
./cage.sh stop

# Remove the container (required to change port mappings)
./cage.sh rm
```

## How It Works

Each project directory gets a deterministic container name (`cage-<dirname>-<hash>`). Running `cage.sh` from the same directory always targets the same container:

- **Container running** — re-attaches
- **Container stopped** — restarts and re-attaches
- **No container** — creates a new one

Your project is mounted at its original absolute path inside the container, so error messages and paths match your host. `~/.claude` and `~/.ssh` are mounted for credentials and git access.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CAGE_IMAGE` | `ghcr.io/pacificsky/devcontainer-lite:latest` | Container image to use |
| `DOCKER_CONTEXT` | (system default) | Docker context override |

## License

MIT
