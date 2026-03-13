#!/bin/sh
# install.sh — Install, update, or uninstall cage
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/pacificsky/cage/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/pacificsky/cage/main/install.sh | sh -s -- --uninstall
#
# Environment variables:
#   CAGE_INSTALL_DIR  — install directory (default: ~/.local/bin)
#   CAGE_VERSION      — version to install (default: latest release)

set -eu

REPO="pacificsky/cage"
INSTALL_DIR="${CAGE_INSTALL_DIR:-$HOME/.local/bin}"

# Note: 'local' is not POSIX but is supported by all major sh implementations
info() { printf '  %s\n' "$@"; }
die()  { printf 'Error: %s\n' "$@" >&2; exit 1; }

# Detect download tool and fetch URL to stdout
download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$1"
    else
        die "curl or wget is required but neither was found"
    fi
}

# Resolve the version tag to install
get_version() {
    if [ -n "${CAGE_VERSION:-}" ]; then
        case "$CAGE_VERSION" in
            v*) echo "$CAGE_VERSION" ;;
            *)  echo "v$CAGE_VERSION" ;;
        esac
        return
    fi
    local api_url="https://api.github.com/repos/$REPO/releases/latest"
    local response
    response="$(download "$api_url")" || die "Failed to fetch latest release from GitHub API. You can set CAGE_VERSION manually."
    echo "$response" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}

# Get version of currently installed cage (empty string if not installed)
get_installed_version() {
    local cage_bin="$INSTALL_DIR/cage"
    if [ -f "$cage_bin" ]; then
        sed -n 's/^VERSION="\(.*\)"/\1/p' "$cage_bin" | head -1
    fi
}

# Check if install dir is on PATH and print instructions if not
check_path() {
    case ":$PATH:" in
        *":$INSTALL_DIR:"*) return ;;
    esac

    echo ""
    info "$INSTALL_DIR is not in your PATH."
    info "Add it by running:"
    echo ""
    local shell_name
    shell_name="$(basename "${SHELL:-/bin/sh}")"
    case "$shell_name" in
        zsh)
            info "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.zshrc"
            info "  source ~/.zshrc"
            ;;
        *)
            info "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.bashrc"
            info "  source ~/.bashrc"
            ;;
    esac
}

do_install() {
    echo "cage installer"
    echo ""

    local tag
    tag="$(get_version)"
    [ -n "$tag" ] || die "Could not determine latest version"
    local version="${tag#v}"

    local installed
    installed="$(get_installed_version)"

    if [ "$installed" = "$version" ]; then
        info "cage $version is already installed"
        return
    fi

    local url="https://raw.githubusercontent.com/$REPO/$tag/cage.sh"
    local tmpfile
    tmpfile="$(mktemp)"
    trap 'rm -f "$tmpfile"' EXIT

    info "Downloading cage $version..."
    download "$url" > "$tmpfile" || die "Failed to download cage $version (tag: $tag)"

    # Validate the download looks like a shell script
    local first_line
    first_line="$(head -1 "$tmpfile")"
    case "$first_line" in
        '#!'*) ;;
        *) die "Downloaded file does not appear to be a valid script" ;;
    esac

    mkdir -p "$INSTALL_DIR" || die "Could not create directory: $INSTALL_DIR"
    cp "$tmpfile" "$INSTALL_DIR/cage"
    chmod +x "$INSTALL_DIR/cage"

    if [ -n "$installed" ]; then
        info "Updated cage: $installed -> $version"
    else
        info "Installed cage $version"
    fi

    check_path
}

do_uninstall() {
    local cage_bin="$INSTALL_DIR/cage"
    if [ ! -f "$cage_bin" ]; then
        die "cage is not installed at $cage_bin"
    fi
    rm "$cage_bin"
    echo "cage has been uninstalled"
    info "Note: Docker volumes (cage-home) and config (~/.config/cage/) were not removed."
    info "To remove those manually:"
    info "  docker volume rm cage-home"
    info "  rm -rf ~/.config/cage"
}

main() {
    case "${1:-}" in
        --uninstall)
            do_uninstall
            ;;
        "")
            do_install
            ;;
        *)
            die "Unknown option: $1. Usage: install.sh [--uninstall]"
            ;;
    esac
}

main "$@"
