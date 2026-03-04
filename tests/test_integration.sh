#!/usr/bin/env bash
# tests/test_integration.sh — Integration tests for cage.sh against a real container runtime.
#
# Usage: bash tests/test_integration.sh
#
# Requires a running container runtime (Docker or Podman).
# Uses a lightweight image (ubuntu:24.04) to keep tests fast.
# Each test uses a unique temp project dir and cleans up after itself.

set -euo pipefail

# Guard: refuse to run on macOS — these tests run obliterate and destroy the
# shared cage-home volume, which would wipe real user data (Claude config,
# credentials, shell state) on a developer machine.
if [ "$(uname -s)" = "Darwin" ]; then
    echo "error: Integration tests must not run on macOS."
    echo "       They execute 'obliterate' which destroys the shared cage-home"
    echo "       volume, deleting all user data across every cage container."
    echo "       Run these in CI (Linux) instead."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CAGE_SH="$REPO_DIR/cage.sh"

# Use a lightweight test image — override the default devcontainer-lite.
export CAGE_IMAGE="ubuntu:24.04"

# Detect container runtime for direct commands (cage.sh detects its own).
if command -v docker &>/dev/null; then
    DOCKER=docker
elif command -v podman &>/dev/null; then
    DOCKER=podman
else
    echo "error: No container runtime found (docker or podman)."
    exit 1
fi

# ================================================================
# Minimal test framework
# ================================================================

_TESTS_RUN=0
_TESTS_PASSED=0
_TESTS_FAILED=0
_CURRENT_TEST=""
_FAILURES=()
_CLEANUP_DIRS=()

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
# Helpers
# ================================================================

# Create a unique temp project dir for a test.
make_project_dir() {
    local d
    d="$(mktemp -d)"
    _CLEANUP_DIRS+=("$d")
    echo "$d"
}

# Run cage.sh from a given project dir (non-interactive commands only).
run_cage_in() {
    local project_dir="$1"
    shift
    (cd "$project_dir" && bash "$CAGE_SH" "$@" 2>&1)
}

# Start/restart a cage container in CI.  These commands attach to an
# interactive shell, so we use timeout to let the container come up
# and then kill the attach process.  The container keeps running.
start_cage_in() {
    local project_dir="$1"
    shift
    (cd "$project_dir" && timeout 10 bash "$CAGE_SH" "$@" </dev/null 2>&1) || true
}

# Compute the expected container name (mirrors cage.sh logic).
container_name_for() {
    local dir="$1"
    local base
    base="$(basename "$dir")"
    local hash
    hash="$(printf '%s' "$dir" | shasum -a 256 | cut -c1-8)"
    echo "cage-${base}-${hash}"
}

# Force-remove a cage container and ignore errors.
cleanup_container() {
    local name="$1"
    $DOCKER rm -f "$name" >/dev/null 2>&1 || true
}

# ================================================================
# Pre-flight
# ================================================================

preflight() {
    echo "Runtime: $DOCKER"
    echo "Image:   $CAGE_IMAGE"

    # Pull the test image once upfront.
    echo "Pulling test image..."
    $DOCKER pull "$CAGE_IMAGE" >/dev/null 2>&1
    echo ""
}

# ================================================================
# Cleanup
# ================================================================

cleanup_all() {
    for d in "${_CLEANUP_DIRS[@]}"; do
        local name
        name="$(container_name_for "$d")"
        cleanup_container "$name"
        rm -rf "$d"
    done
    # Remove the shared home volume used by tests.
    $DOCKER volume rm cage-home >/dev/null 2>&1 || true
}

# ================================================================
# Tests
# ================================================================

test_create_and_status() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    # Create container (timeout kills the interactive attach after creation).
    start_cage_in "$pdir" start

    # Status should show the container.
    local out
    out="$(run_cage_in "$pdir" status)"
    assert_contains "$out" "Container: $name" "container name in status"
    # It may be stopped (ubuntu exits immediately) or running.
    assert_not_contains "$out" "State:     none" "container exists"

    cleanup_container "$name"
}

test_stop_container() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    start_cage_in "$pdir" start

    local out
    out="$(run_cage_in "$pdir" stop 2>&1)" || true
    # Should either stop it or say it's already stopped.
    local status_out
    status_out="$(run_cage_in "$pdir" status)"
    assert_contains "$status_out" "stopped" "container is stopped after stop"

    cleanup_container "$name"
}

test_rm_container() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    start_cage_in "$pdir" start
    run_cage_in "$pdir" rm || true

    local out
    out="$(run_cage_in "$pdir" status)"
    assert_contains "$out" "State:     none" "container removed"
}

test_project_dir_mounted() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    # Write a file in the project dir.
    echo "hello from host" > "$pdir/testfile.txt"

    start_cage_in "$pdir" start

    # The container may have exited, so start it briefly to exec.
    $DOCKER start "$name" >/dev/null 2>&1 || true
    local content
    content="$($DOCKER exec "$name" cat "$pdir/testfile.txt" 2>/dev/null)" || true
    assert_eq "hello from host" "$content" "host file visible in container"

    cleanup_container "$name"
}

test_shared_home_volume_persists() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    start_cage_in "$pdir" start

    # Write a file to /home/vscode inside the container.
    $DOCKER start "$name" >/dev/null 2>&1 || true
    $DOCKER exec "$name" sh -c 'echo "persist-test" > /home/vscode/persist.txt' 2>/dev/null

    # Remove and recreate the container.
    run_cage_in "$pdir" rm || true
    start_cage_in "$pdir" start

    # File should still be there (shared volume survives rm).
    $DOCKER start "$name" >/dev/null 2>&1 || true
    local content
    content="$($DOCKER exec "$name" cat /home/vscode/persist.txt 2>/dev/null)" || true
    assert_eq "persist-test" "$content" "file persists across container recreate"

    cleanup_container "$name"
}

test_seed_directory() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    # Set up a seed directory.
    mkdir -p "$HOME/.config/cage/home/.claude"
    echo '{"seed": true}' > "$HOME/.config/cage/home/.claude/settings.json"

    start_cage_in "$pdir" start

    # Check that the seed file landed.
    $DOCKER start "$name" >/dev/null 2>&1 || true
    local content
    content="$($DOCKER exec "$name" cat /home/vscode/.claude/settings.json 2>/dev/null)" || true
    assert_contains "$content" '"seed": true' "seed file copied into container"

    cleanup_container "$name"
    rm -rf "$HOME/.config/cage/home"
}

test_seed_no_clobber() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    # Create container and write a file to /home/vscode that will conflict with seed.
    start_cage_in "$pdir" start
    $DOCKER start "$name" >/dev/null 2>&1 || true
    $DOCKER exec "$name" sh -c 'mkdir -p /home/vscode/.claude && echo "user-custom" > /home/vscode/.claude/settings.json' 2>/dev/null

    # Set up a seed directory with a conflicting file.
    mkdir -p "$HOME/.config/cage/home/.claude"
    echo '{"seed": true}' > "$HOME/.config/cage/home/.claude/settings.json"

    # Recreate the container — seed should NOT overwrite the user's file.
    run_cage_in "$pdir" rm || true
    start_cage_in "$pdir" start

    $DOCKER start "$name" >/dev/null 2>&1 || true
    local content
    content="$($DOCKER exec "$name" cat /home/vscode/.claude/settings.json 2>/dev/null)" || true
    assert_eq "user-custom" "$content" "user file preserved over seed (no-clobber)"

    cleanup_container "$name"
    rm -rf "$HOME/.config/cage/home"
}

test_list_shows_container() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    start_cage_in "$pdir" start

    local out
    out="$(run_cage_in "$pdir" list)"
    assert_contains "$out" "$name" "container appears in list"

    cleanup_container "$name"
}

test_restart_recreates() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    start_cage_in "$pdir" start

    # Get container ID before restart.
    local id_before
    id_before="$($DOCKER inspect -f '{{.Id}}' "$name" 2>/dev/null)" || true

    # Stop first so rm -f during restart is instant (avoids podman's 10s SIGTERM wait).
    $DOCKER stop "$name" >/dev/null 2>&1 || true

    start_cage_in "$pdir" restart

    # Container should exist with a different ID.
    local id_after
    id_after="$($DOCKER inspect -f '{{.Id}}' "$name" 2>/dev/null)" || true

    if [ "$id_before" = "$id_after" ]; then
        fail "container ID should change after restart"
    fi

    cleanup_container "$name"
}

test_obliterate_removes_all() {
    local pdir1; pdir1="$(make_project_dir)"
    local pdir2; pdir2="$(make_project_dir)"
    local name1; name1="$(container_name_for "$pdir1")"
    local name2; name2="$(container_name_for "$pdir2")"

    start_cage_in "$pdir1" start
    start_cage_in "$pdir2" start

    # Obliterate from any project dir.
    run_cage_in "$pdir1" obliterate || true

    local status1; status1="$(run_cage_in "$pdir1" status)"
    local status2; status2="$(run_cage_in "$pdir2" status)"
    assert_contains "$status1" "State:     none" "first container removed"
    assert_contains "$status2" "State:     none" "second container removed"
}

# ================================================================
# Run all tests
# ================================================================

main() {
    echo "cage.sh integration test suite"
    echo "========================================="

    preflight
    trap cleanup_all EXIT

    echo "--- lifecycle ---"
    run_test test_create_and_status
    run_test test_stop_container
    run_test test_rm_container
    run_test test_restart_recreates

    echo ""
    echo "--- volumes and mounts ---"
    run_test test_project_dir_mounted
    run_test test_shared_home_volume_persists

    echo ""
    echo "--- seed directory ---"
    run_test test_seed_directory
    run_test test_seed_no_clobber

    echo ""
    echo "--- listing and cleanup ---"
    run_test test_list_shows_container
    run_test test_obliterate_removes_all

    print_summary
}

main "$@"
