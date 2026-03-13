# Install Script Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a curl-pipe-to-sh install script that installs, updates, or uninstalls cage from GitHub releases.

**Architecture:** Single POSIX sh script (`install.sh`) at repo root. Downloads `cage.sh` from raw GitHub URLs, installs to `~/.local/bin/cage`. Uses GitHub API to resolve latest release version. Mock-based tests following the existing test pattern in `tests/test_cage.sh`.

**Tech Stack:** POSIX sh, curl/wget, GitHub REST API

**Spec:** `docs/superpowers/specs/2026-03-13-install-script-design.md`

---

## Chunk 1: Install Script and Tests

### Task 1: Write tests for install.sh

**Files:**
- Create: `tests/test_install.sh`

Tests use the same framework pattern as `tests/test_cage.sh`: mock-based, no network access. We mock `curl`/`wget` to return configurable responses and use temp directories for all filesystem operations.

- [ ] **Step 1: Create test file with framework, mock setup, and all test cases**

Create `tests/test_install.sh` with:
- Same minimal test framework from `tests/test_cage.sh` (run_test, assert_eq, assert_contains, etc.)
- Mock infrastructure: fake `curl` returning configurable GitHub API JSON and cage.sh content, temp install dir, temp HOME
- `teardown_mock` that cleans up temp files AND unsets env vars (`CAGE_VERSION`, `CAGE_INSTALL_DIR`)

```sh
#!/usr/bin/env bash
# tests/test_install.sh — Tests for install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_DIR/install.sh"

# ================================================================
# Minimal test framework (same as test_cage.sh)
# ================================================================

_TESTS_RUN=0
_TESTS_PASSED=0
_TESTS_FAILED=0
_CURRENT_TEST=""
_FAILURES=()

fail() {
    local msg="${1:-}"
    ((_TESTS_FAILED++)) || true
    _FAILURES+=("$_CURRENT_TEST: $msg")
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$expected" != "$actual" ]; then
        fail "${msg:+$msg: }expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" != *"$needle"* ]]; then
        fail "${msg:+$msg: }output does not contain '$needle'"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        fail "${msg:+$msg: }output should not contain '$needle'"
    fi
}

run_test() {
    local name="$1"
    _CURRENT_TEST="$name"
    ((_TESTS_RUN++)) || true
    printf "  %-55s " "$name"

    local _pre_fail=$_TESTS_FAILED

    set +e
    "$name" 2>/dev/null
    local rc=$?
    set -e

    if [ $rc -ne 0 ] && [ $_TESTS_FAILED -eq $_pre_fail ]; then
        fail "exited with code $rc"
    fi

    if [ $_TESTS_FAILED -eq $_pre_fail ]; then
        ((_TESTS_PASSED++)) || true
        echo "ok"
    else
        echo "FAIL"
    fi
}

print_summary() {
    echo ""
    echo "========================================="
    echo "Tests: $_TESTS_RUN | Passed: $_TESTS_PASSED | Failed: $_TESTS_FAILED"
    if [ ${#_FAILURES[@]} -gt 0 ]; then
        echo ""
        echo "Failures:"
        for f in "${_FAILURES[@]}"; do
            echo "  - $f"
        done
    fi
    echo "========================================="
    [ "$_TESTS_FAILED" -eq 0 ]
}

# ================================================================
# Mock infrastructure
# ================================================================

MOCK_DIR=""
FAKE_HOME=""
FAKE_INSTALL_DIR=""
ORIGINAL_PATH=""

setup_mock() {
    MOCK_DIR="$(mktemp -d)"
    FAKE_HOME="$MOCK_DIR/home"
    FAKE_INSTALL_DIR="$MOCK_DIR/install_bin"
    mkdir -p "$FAKE_HOME" "$FAKE_INSTALL_DIR"
    mkdir -p "$MOCK_DIR/bin"

    # Default mock curl: returns a fake GitHub API response and a fake cage.sh
    create_mock_curl "$MOCK_DIR/bin" "v0.9.0" '#!/usr/bin/env bash
VERSION="0.9.0"
echo "I am cage"'

    ORIGINAL_PATH="$PATH"
    export HOME="$FAKE_HOME"
    export PATH="$MOCK_DIR/bin:$FAKE_INSTALL_DIR:$PATH"
    export CAGE_INSTALL_DIR="$FAKE_INSTALL_DIR"
    unset CAGE_VERSION 2>/dev/null || true
}

# create_mock_curl <bin_dir> <tag> <cage_script_content>
create_mock_curl() {
    local bin_dir="$1"
    local tag="$2"
    local cage_content="$3"

    cat > "$bin_dir/curl" <<MOCK_CURL
#!/bin/sh
# Parse the last argument as the URL
for arg; do url="\$arg"; done
case "\$url" in
    *api.github.com/repos/*/releases/latest*)
        echo '{"tag_name": "$tag"}'
        ;;
    *raw.githubusercontent.com/*/cage.sh*)
        cat <<'CAGE_CONTENT'
$cage_content
CAGE_CONTENT
        ;;
    *)
        echo "mock curl: unexpected URL: \$url" >&2
        exit 1
        ;;
esac
MOCK_CURL
    chmod +x "$bin_dir/curl"
}

# create_mock_wget <bin_dir> <tag> <cage_script_content>
create_mock_wget() {
    local bin_dir="$1"
    local tag="$2"
    local cage_content="$3"

    cat > "$bin_dir/wget" <<MOCK_WGET
#!/bin/sh
# Parse the last argument as the URL
for arg; do url="\$arg"; done
case "\$url" in
    *api.github.com/repos/*/releases/latest*)
        echo '{"tag_name": "$tag"}'
        ;;
    *raw.githubusercontent.com/*/cage.sh*)
        cat <<'CAGE_CONTENT'
$cage_content
CAGE_CONTENT
        ;;
    *)
        echo "mock wget: unexpected URL: \$url" >&2
        exit 1
        ;;
esac
MOCK_WGET
    chmod +x "$bin_dir/wget"
}

teardown_mock() {
    unset CAGE_VERSION 2>/dev/null || true
    unset CAGE_INSTALL_DIR 2>/dev/null || true
    [ -n "${ORIGINAL_PATH:-}" ] && export PATH="$ORIGINAL_PATH"
    [ -n "$MOCK_DIR" ] && rm -rf "$MOCK_DIR"
}

# ================================================================
# Tests
# ================================================================

test_fresh_install() {
    setup_mock
    local output
    output="$(sh "$INSTALL_SH" 2>&1)"
    assert_contains "$output" "Installed cage 0.9.0" "should show installed version"
    assert_eq "0" "$([ -x "$FAKE_INSTALL_DIR/cage" ] && echo 0 || echo 1)" "cage should be executable"
    teardown_mock
}

test_already_up_to_date() {
    setup_mock
    # Pre-install a cage with the same version
    cat > "$FAKE_INSTALL_DIR/cage" <<'EOF'
#!/usr/bin/env bash
VERSION="0.9.0"
EOF
    chmod +x "$FAKE_INSTALL_DIR/cage"

    local output
    output="$(sh "$INSTALL_SH" 2>&1)"
    assert_contains "$output" "already installed" "should say already up to date"
    teardown_mock
}

test_update_existing() {
    setup_mock
    # Pre-install an older version
    cat > "$FAKE_INSTALL_DIR/cage" <<'EOF'
#!/usr/bin/env bash
VERSION="0.8.0"
EOF
    chmod +x "$FAKE_INSTALL_DIR/cage"

    local output
    output="$(sh "$INSTALL_SH" 2>&1)"
    assert_contains "$output" "Updated cage: 0.8.0 -> 0.9.0" "should show update message"
    teardown_mock
}

test_custom_version() {
    setup_mock
    export CAGE_VERSION="v0.7.0"
    create_mock_curl "$MOCK_DIR/bin" "v0.7.0" '#!/usr/bin/env bash
VERSION="0.7.0"
echo "I am cage"'

    local output
    output="$(sh "$INSTALL_SH" 2>&1)"
    assert_contains "$output" "Installed cage 0.7.0" "should install requested version"
    teardown_mock
}

test_custom_version_without_v_prefix() {
    setup_mock
    export CAGE_VERSION="0.7.0"
    create_mock_curl "$MOCK_DIR/bin" "v0.7.0" '#!/usr/bin/env bash
VERSION="0.7.0"
echo "I am cage"'

    local output
    output="$(sh "$INSTALL_SH" 2>&1)"
    assert_contains "$output" "Installed cage 0.7.0" "should handle version without v prefix"
    teardown_mock
}

test_uninstall() {
    setup_mock
    cat > "$FAKE_INSTALL_DIR/cage" <<'EOF'
#!/usr/bin/env bash
VERSION="0.9.0"
EOF
    chmod +x "$FAKE_INSTALL_DIR/cage"

    local output
    output="$(sh "$INSTALL_SH" --uninstall 2>&1)"
    assert_contains "$output" "has been uninstalled" "should confirm uninstall"
    assert_eq "1" "$([ -f "$FAKE_INSTALL_DIR/cage" ] && echo 0 || echo 1)" "cage should be removed"
    assert_contains "$output" "cage-home" "should mention Docker volumes"
    teardown_mock
}

test_uninstall_not_installed() {
    setup_mock
    local output
    output="$(sh "$INSTALL_SH" --uninstall 2>&1)" || true
    assert_contains "$output" "not installed" "should report not installed"
    teardown_mock
}

test_invalid_download() {
    setup_mock
    create_mock_curl "$MOCK_DIR/bin" "v0.9.0" '<html>404 Not Found</html>'

    local output rc=0
    output="$(sh "$INSTALL_SH" 2>&1)" || rc=$?
    assert_eq "1" "$rc" "should exit with error"
    assert_contains "$output" "does not appear to be a valid script" "should report invalid download"
    teardown_mock
}

test_path_warning() {
    setup_mock
    # Remove FAKE_INSTALL_DIR from PATH so the warning triggers
    export PATH="$MOCK_DIR/bin:/usr/bin:/bin"

    local output
    output="$(sh "$INSTALL_SH" 2>&1)"
    assert_contains "$output" "not in your PATH" "should warn about PATH"
    teardown_mock
}

test_creates_install_dir() {
    setup_mock
    rm -rf "$FAKE_INSTALL_DIR"
    export CAGE_INSTALL_DIR="$MOCK_DIR/new_dir/bin"

    local output
    output="$(sh "$INSTALL_SH" 2>&1)"
    assert_eq "0" "$([ -x "$MOCK_DIR/new_dir/bin/cage" ] && echo 0 || echo 1)" "should create dir and install"
    teardown_mock
}

test_unknown_option() {
    setup_mock
    local output rc=0
    output="$(sh "$INSTALL_SH" --badopt 2>&1)" || rc=$?
    assert_eq "1" "$rc" "should exit with error"
    assert_contains "$output" "Unknown option" "should report unknown option"
    teardown_mock
}

test_wget_fallback() {
    setup_mock
    # Remove curl, add wget
    rm "$MOCK_DIR/bin/curl"
    create_mock_wget "$MOCK_DIR/bin" "v0.9.0" '#!/usr/bin/env bash
VERSION="0.9.0"
echo "I am cage"'

    local output
    output="$(sh "$INSTALL_SH" 2>&1)"
    assert_contains "$output" "Installed cage 0.9.0" "should install via wget"
    teardown_mock
}

test_no_download_tool() {
    setup_mock
    # Remove curl from mock PATH, ensure no wget either
    rm "$MOCK_DIR/bin/curl"
    # Set PATH to only our mock bin dir (which now has no curl or wget)
    export PATH="$MOCK_DIR/bin:/usr/bin:/bin"
    # Ensure real curl/wget are not found by removing common paths
    # We need a PATH that has basic tools (sh, head, sed, etc.) but no curl/wget
    # Create a minimal bin dir with just the tools install.sh needs
    local clean_bin="$MOCK_DIR/clean_bin"
    mkdir -p "$clean_bin"
    for cmd in sh head sed mktemp mkdir chmod cp rm basename cat printf; do
        local real_cmd
        real_cmd="$(command -v "$cmd" 2>/dev/null)" || true
        [ -n "$real_cmd" ] && ln -sf "$real_cmd" "$clean_bin/$cmd"
    done
    export PATH="$clean_bin"

    local output rc=0
    output="$(sh "$INSTALL_SH" 2>&1)" || rc=$?
    assert_eq "1" "$rc" "should exit with error"
    assert_contains "$output" "curl or wget" "should mention both tools"
    teardown_mock
}

test_api_failure() {
    setup_mock
    # Mock curl that fails on API call
    cat > "$MOCK_DIR/bin/curl" <<'MOCK_CURL'
#!/bin/sh
for arg; do url="$arg"; done
case "$url" in
    *api.github.com*)
        echo "rate limited" >&2
        exit 1
        ;;
    *)
        exit 1
        ;;
esac
MOCK_CURL
    chmod +x "$MOCK_DIR/bin/curl"

    local output rc=0
    output="$(sh "$INSTALL_SH" 2>&1)" || rc=$?
    assert_eq "1" "$rc" "should exit with error"
    assert_contains "$output" "Failed" "should report failure"
    teardown_mock
}

# ================================================================
# Run all tests
# ================================================================

echo ""
echo "install.sh tests"
echo "-----------------------------------------"

run_test test_fresh_install
run_test test_already_up_to_date
run_test test_update_existing
run_test test_custom_version
run_test test_custom_version_without_v_prefix
run_test test_uninstall
run_test test_uninstall_not_installed
run_test test_invalid_download
run_test test_path_warning
run_test test_creates_install_dir
run_test test_unknown_option
run_test test_wget_fallback
run_test test_no_download_tool
run_test test_api_failure

print_summary
```

- [ ] **Step 2: Commit test file**

```bash
git add tests/test_install.sh
git commit -m "test: add test suite for install.sh"
```

### Task 2: Write install.sh

**Files:**
- Create: `install.sh`

- [ ] **Step 1: Write the complete install.sh**

Write the full script with all functions. Note: uses `local` which is not POSIX but is supported by all major sh implementations (dash, ash, bash, zsh).

```sh
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
```

- [ ] **Step 2: Make executable**

```bash
chmod +x install.sh
```

- [ ] **Step 3: Run tests**

Run: `bash tests/test_install.sh`
Expected: All 14 tests pass.

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "feat: add install.sh — curl-style installer for cage"
```

### Task 3: Update CI to run install tests

**Files:**
- Modify: `.github/workflows/test.yml`

- [ ] **Step 1: Add install.sh to the paths filter and add a test step**

In the `paths` list under `on.push.paths` (line 8-10), add:
```yaml
      - 'install.sh'
```

In the `dorny/paths-filter` filters section (lines 22-25), add `install.sh` to the `should_test` filter:
```yaml
              - 'install.sh'
```

In the `test` job `steps`, add after the existing "Run tests" step:
```yaml
      - name: Run install script tests
        run: bash tests/test_install.sh
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: run install.sh tests in CI"
```

### Task 4: Update README with curl install instructions

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read README to find insertion point**

Read the current README to understand existing structure and find where to add the curl install section (after the Homebrew instructions).

- [ ] **Step 2: Add curl install section**

Add an "Install without Homebrew" section after the existing Homebrew install block:

```markdown
### Without Homebrew

```bash
curl -fsSL https://raw.githubusercontent.com/pacificsky/cage/main/install.sh | sh
```

This installs `cage` to `~/.local/bin`. To update, run the same command again. To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/pacificsky/cage/main/install.sh | sh -s -- --uninstall
```
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add curl install instructions to README"
```
