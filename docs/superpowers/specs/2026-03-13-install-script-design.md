# Curl-Style Install Script for cage

**Date:** 2026-03-13

## Overview

A standalone `install.sh` at the repo root that allows users to install, update, or uninstall cage without Homebrew.

## Usage

```bash
# Install or update
curl -fsSL https://raw.githubusercontent.com/pacificsky/cage/main/install.sh | sh

# Uninstall
curl -fsSL https://raw.githubusercontent.com/pacificsky/cage/main/install.sh | sh -s -- --uninstall

# Custom install directory
CAGE_INSTALL_DIR=/opt/bin curl -fsSL https://raw.githubusercontent.com/pacificsky/cage/main/install.sh | sh

# Specific version
CAGE_VERSION=v0.7.0 curl -fsSL https://raw.githubusercontent.com/pacificsky/cage/main/install.sh | sh
```

## Behavior

### Install/Update (default)

1. Detect download tool: use `curl` if available, fall back to `wget`, error if neither found
2. Resolve version: fetch `https://api.github.com/repos/pacificsky/cage/releases/latest` and parse the tag name, or use `CAGE_VERSION` env var (error if specified tag doesn't exist)
3. Check currently installed version: grep `VERSION=` from the existing `cage` binary in `$CAGE_INSTALL_DIR`. Strip `v` prefix from GitHub tag for comparison. If versions match, print "already up to date" and exit
4. Download `cage.sh` via raw GitHub URL: `https://raw.githubusercontent.com/pacificsky/cage/<tag>/cage.sh`
5. Create install dir (`mkdir -p`) if it doesn't exist. Error if dir can't be created
6. Install as `cage` (no `.sh` extension) with `chmod +x`
7. On update: show old version → new version. On fresh install: show installed version
8. Check if install dir is on `$PATH` — if not, print shell-specific instructions (detect bash vs zsh, suggest adding to `~/.bashrc` or `~/.zshrc`)

### Uninstall (`--uninstall`)

1. Check if `cage` exists at `$CAGE_INSTALL_DIR/cage` — if not, print "not found" and exit
2. Remove the binary
3. Print confirmation and note that Docker volumes (`cage-home`) and config (`~/.config/cage/`) are not removed

## Error Handling

- No `curl` or `wget`: error with install instructions
- GitHub API unreachable or rate-limited: error with suggestion to retry or set `CAGE_VERSION` manually
- Specified `CAGE_VERSION` tag not found: error listing the tag that was tried
- Download fails or returns non-script content: validate downloaded file starts with `#!/` before installing
- Install dir not writable: error with suggestion to use `CAGE_INSTALL_DIR`

## Design Decisions

- **Install location:** `~/.local/bin` — no sudo needed, follows XDG conventions
- **Download method:** Raw GitHub URL by tag — simplest for a single-file download, no `tar` dependency needed
- **Version resolution:** Latest GitHub release by default, `CAGE_VERSION` env var override
- **Version comparison:** Grep `VERSION=` from installed binary, strip `v` prefix from tag
- **Update mechanism:** Re-run the same install script (no `self-update` subcommand)
- **No changes to `cage.sh`** — fully standalone script
- **POSIX `sh` compatible** — the install script itself uses `/bin/sh`, though `cage` requires `bash`
- **Dependencies:** `curl` or `wget`, POSIX `sh`, `mkdir`, `chmod`

## File Location

`install.sh` at repository root. Raw URL: `https://raw.githubusercontent.com/pacificsky/cage/main/install.sh`
