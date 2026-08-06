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

test_env_file_project() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    echo "TEST_CAGE_ENV=hello" > "$pdir/.cage.env"

    start_cage_in "$pdir" start

    $DOCKER start "$name" >/dev/null 2>&1 || true
    local val
    val="$($DOCKER exec "$name" printenv TEST_CAGE_ENV 2>/dev/null)" || true
    assert_eq "hello" "$val" "project env var visible in container"

    cleanup_container "$name"
    rm -f "$pdir/.cage.env"
}

test_env_file_global() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    mkdir -p "$HOME/.config/cage"
    echo "TEST_CAGE_GLOBAL=world" > "$HOME/.config/cage/env"

    start_cage_in "$pdir" start

    $DOCKER start "$name" >/dev/null 2>&1 || true
    local val
    val="$($DOCKER exec "$name" printenv TEST_CAGE_GLOBAL 2>/dev/null)" || true
    assert_eq "world" "$val" "global env var visible in container"

    cleanup_container "$name"
    rm -f "$HOME/.config/cage/env"
}

test_env_file_override() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    mkdir -p "$HOME/.config/cage"
    echo "OVERRIDE_ME=global" > "$HOME/.config/cage/env"
    echo "OVERRIDE_ME=project" > "$pdir/.cage.env"

    start_cage_in "$pdir" start

    $DOCKER start "$name" >/dev/null 2>&1 || true
    local val
    val="$($DOCKER exec "$name" printenv OVERRIDE_ME 2>/dev/null)" || true
    assert_eq "project" "$val" "project env overrides global"

    cleanup_container "$name"
    rm -f "$HOME/.config/cage/env" "$pdir/.cage.env"
}

test_mounts_file_project() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"
    local host_dir; host_dir="$(make_project_dir)"

    echo "from host" > "$host_dir/data.txt"
    echo "${host_dir}:/mnt/extra" > "$pdir/.cage.mounts"

    start_cage_in "$pdir" start

    $DOCKER start "$name" >/dev/null 2>&1 || true
    local content
    content="$($DOCKER exec "$name" cat /mnt/extra/data.txt 2>/dev/null)" || true
    assert_eq "from host" "$content" "project mount visible in container"

    cleanup_container "$name"
    rm -f "$pdir/.cage.mounts"
}

test_mounts_file_global() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"
    local host_dir; host_dir="$(make_project_dir)"

    echo "from global" > "$host_dir/data.txt"
    mkdir -p "$HOME/.config/cage"
    echo "${host_dir}:/mnt/global" > "$HOME/.config/cage/mounts"

    start_cage_in "$pdir" start

    $DOCKER start "$name" >/dev/null 2>&1 || true
    local content
    content="$($DOCKER exec "$name" cat /mnt/global/data.txt 2>/dev/null)" || true
    assert_eq "from global" "$content" "global mount visible in container"

    cleanup_container "$name"
    rm -f "$HOME/.config/cage/mounts"
}

test_mounts_file_same_path_shorthand() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"
    local host_dir; host_dir="$(make_project_dir)"

    echo "same path" > "$host_dir/data.txt"
    echo "$host_dir" > "$pdir/.cage.mounts"

    start_cage_in "$pdir" start

    $DOCKER start "$name" >/dev/null 2>&1 || true
    local content
    content="$($DOCKER exec "$name" cat "$host_dir/data.txt" 2>/dev/null)" || true
    assert_eq "same path" "$content" "colon-less spec mounted at the same absolute path"

    cleanup_container "$name"
    rm -f "$pdir/.cage.mounts"
}

test_mounts_file_same_path_with_options() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"
    local rw_dir; rw_dir="$(make_project_dir)"
    local ro_dir; ro_dir="$(make_project_dir)"

    echo "locked" > "$ro_dir/data.txt"
    # '::' is same-path with no options; '::ro' is same-path, read-only.  The
    # writable one is the control: it proves a failed write on the other is
    # caused by ':ro' and not by ownership.
    printf '%s::\n%s::ro\n' "$rw_dir" "$ro_dir" > "$pdir/.cage.mounts"

    start_cage_in "$pdir" start
    $DOCKER start "$name" >/dev/null 2>&1 || true

    local content
    content="$($DOCKER exec "$name" cat "$ro_dir/data.txt" 2>/dev/null)" || true
    assert_eq "locked" "$content" "'::ro' mounts at the same absolute path"

    local rw_rc=0 ro_rc=0
    $DOCKER exec "$name" sh -c "echo probe > $rw_dir/probe.txt" >/dev/null 2>&1 || rw_rc=$?
    $DOCKER exec "$name" sh -c "echo probe > $ro_dir/probe.txt" >/dev/null 2>&1 || ro_rc=$?
    assert_eq "0" "$rw_rc" "'::' mount accepts writes"
    if [ "$ro_rc" -eq 0 ]; then
        fail "'::ro' mount should reject writes"
    fi

    cleanup_container "$name"
    rm -f "$pdir/.cage.mounts"
}

test_mounts_file_override() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"
    local global_dir; global_dir="$(make_project_dir)"
    local project_dir; project_dir="$(make_project_dir)"

    echo "global" > "$global_dir/data.txt"
    echo "project" > "$project_dir/data.txt"
    mkdir -p "$HOME/.config/cage"
    echo "${global_dir}:/mnt/shared" > "$HOME/.config/cage/mounts"
    echo "${project_dir}:/mnt/shared" > "$pdir/.cage.mounts"

    start_cage_in "$pdir" start

    $DOCKER start "$name" >/dev/null 2>&1 || true
    local content
    content="$($DOCKER exec "$name" cat /mnt/shared/data.txt 2>/dev/null)" || true
    assert_eq "project" "$content" "project mount overrides global for same target"

    cleanup_container "$name"
    rm -f "$HOME/.config/cage/mounts" "$pdir/.cage.mounts"
}

test_mounts_file_readonly() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"
    local host_dir; host_dir="$(make_project_dir)"

    echo "locked" > "$host_dir/data.txt"
    # The same host dir mounted twice — once writable, once read-only — so
    # ownership and permissions are identical either way.  A write that
    # succeeds on /mnt/rw but fails on /mnt/ro isolates ':ro' as the cause;
    # checking only the failure could pass for unrelated reasons.  Two specs
    # in one file also covers multi-line mount files.
    printf '%s:/mnt/rw\n%s:/mnt/ro:ro\n' "$host_dir" "$host_dir" > "$pdir/.cage.mounts"

    start_cage_in "$pdir" start

    $DOCKER start "$name" >/dev/null 2>&1 || true
    local rw_rc=0 ro_rc=0
    $DOCKER exec "$name" sh -c 'echo probe > /mnt/rw/probe.txt' >/dev/null 2>&1 || rw_rc=$?
    $DOCKER exec "$name" sh -c 'echo probe > /mnt/ro/probe.txt' >/dev/null 2>&1 || ro_rc=$?

    assert_eq "0" "$rw_rc" "plain mount accepts writes"
    if [ "$ro_rc" -eq 0 ]; then
        fail ":ro mount should reject writes"
    fi

    local content
    content="$($DOCKER exec "$name" cat /mnt/ro/data.txt 2>/dev/null)" || true
    assert_eq "locked" "$content" ":ro mount is still readable"

    cleanup_container "$name"
    rm -f "$pdir/.cage.mounts"
}

test_list_shows_container() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    start_cage_in "$pdir" start

    local out
    out="$(run_cage_in "$pdir" list)"

    # Validate all four columns of the list output.
    # Column 1: NAMES — the deterministic container name.
    assert_contains "$out" "$name" "NAMES column: container name"
    # Column 2: STATUS — container should be running after start.
    assert_contains "$out" "Up" "STATUS column: container is running"
    # Column 3: IMAGE — should show the tag from CAGE_IMAGE (24.04) and a short SHA.
    assert_contains "$out" "24.04" "IMAGE column: image tag"
    # Column 4: PROJECT — the project directory path.
    assert_contains "$out" "$pdir" "PROJECT column: project directory"

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

test_ports_file_project() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"
    echo "18082:80" > "$pdir/.cage.ports"

    start_cage_in "$pdir" start
    local ports
    ports="$($DOCKER port "$name" 2>/dev/null)" || true
    assert_contains "$ports" "18082" "ports-file port published"

    # Port files are re-read on recreation (not frozen into labels): edit
    # the file, restart, and the new mapping must win.
    echo "18083:80" > "$pdir/.cage.ports"
    $DOCKER stop "$name" >/dev/null 2>&1 || true
    start_cage_in "$pdir" restart
    ports="$($DOCKER port "$name" 2>/dev/null)" || true
    assert_contains "$ports" "18083" "edited ports file applied on restart"

    cleanup_container "$name"
}

test_restart_preserves_ports_and_volumes() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"
    local vdir; vdir="$(make_project_dir)"   # host dir for the -v mount

    start_cage_in "$pdir" start -p 18080:80 -v "$vdir:/cage-extra"
    $DOCKER stop "$name" >/dev/null 2>&1 || true
    start_cage_in "$pdir" restart

    # The recreated container should carry both labels forward...
    local ports_label vols_label
    ports_label="$($DOCKER inspect -f '{{index .Config.Labels "cage.ports"}}' "$name" 2>/dev/null)" || true
    vols_label="$($DOCKER inspect -f '{{index .Config.Labels "cage.volumes"}}' "$name" 2>/dev/null)" || true
    assert_eq "18080:80" "$ports_label" "cage.ports label re-recorded"
    assert_eq "$vdir:/cage-extra" "$vols_label" "cage.volumes label re-recorded"

    # ...and actually have the port published and the mount present.
    local ports
    ports="$($DOCKER port "$name" 2>/dev/null)" || true
    assert_contains "$ports" "18080" "published port survives restart"

    $DOCKER start "$name" >/dev/null 2>&1 || true
    local mounted
    mounted="$($DOCKER exec "$name" sh -c 'test -d /cage-extra && echo yes' 2>/dev/null)" || true
    assert_eq "yes" "$mounted" "-v mount survives restart"

    cleanup_container "$name"
}

test_restart_preserves_image() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    start_cage_in "$pdir" start
    $DOCKER stop "$name" >/dev/null 2>&1 || true
    # Restart without CAGE_IMAGE in the environment: the image recorded on
    # the container (ubuntu:24.04) must win over cage's built-in default.
    (cd "$pdir" && env -u CAGE_IMAGE timeout 10 bash "$CAGE_SH" restart </dev/null 2>&1) || true

    local img
    img="$($DOCKER ps -a --filter "name=$name" --format '{{.Image}}')" || true
    assert_contains "$img" "24.04" "recreated from recorded image, not the default"

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
# Tests: dstart (docker-enabled cages, Linux trusted mode)
# ================================================================

test_dstart_mounts_socket_and_labels() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    local out; out="$(start_cage_in "$pdir" dstart)"
    assert_contains "$out" "DOCKER-ENABLED CAGE" "warning banner shown"

    local label
    label="$($DOCKER inspect -f '{{index .Config.Labels "cage.docker"}}' "$name" 2>/dev/null)" || true
    assert_eq "host" "$label" "cage.docker label"

    $DOCKER start "$name" >/dev/null 2>&1 || true
    local sock
    sock="$($DOCKER exec "$name" sh -c 'test -S /var/run/docker.sock && echo yes' 2>/dev/null)" || true
    assert_eq "yes" "$sock" "socket present inside the cage"

    cleanup_container "$name"
}

test_dstart_agent_can_reach_daemon() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    # docker:cli ships the docker client; the mounted socket should answer.
    # Longer timeout: this pulls docker:cli on a cold CI cache.
    (cd "$pdir" && CAGE_IMAGE="docker:cli" timeout 60 bash "$CAGE_SH" dstart </dev/null 2>&1) || true

    $DOCKER start "$name" >/dev/null 2>&1 || true
    local out
    out="$($DOCKER exec "$name" docker ps 2>&1)" || true
    assert_contains "$out" "CONTAINER ID" "docker ps works against mounted socket"

    cleanup_container "$name"
}

test_status_shows_docker_mode() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    start_cage_in "$pdir" dstart
    local out; out="$(run_cage_in "$pdir" status)"
    assert_contains "$out" "Docker:    host" "status reports host mode"

    cleanup_container "$name"
}

test_status_shows_docker_none_for_plain_start() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    start_cage_in "$pdir" start
    local out; out="$(run_cage_in "$pdir" status)"
    assert_contains "$out" "Docker:    none" "plain cage reports none"

    cleanup_container "$name"
}

test_start_reattaches_to_dstart_container() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    start_cage_in "$pdir" dstart
    local id_before
    id_before="$($DOCKER inspect -f '{{.Id}}' "$name" 2>/dev/null)" || true

    start_cage_in "$pdir" start
    local id_after
    id_after="$($DOCKER inspect -f '{{.Id}}' "$name" 2>/dev/null)" || true

    assert_eq "$id_before" "$id_after" "plain start re-attached, did not recreate"

    cleanup_container "$name"
}

test_restart_preserves_docker_mode() {
    local pdir; pdir="$(make_project_dir)"
    local name; name="$(container_name_for "$pdir")"

    start_cage_in "$pdir" dstart
    $DOCKER stop "$name" >/dev/null 2>&1 || true
    start_cage_in "$pdir" restart

    local label
    label="$($DOCKER inspect -f '{{index .Config.Labels "cage.docker"}}' "$name" 2>/dev/null)" || true
    assert_eq "host" "$label" "recreated container keeps docker mode"

    cleanup_container "$name"
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
    run_test test_restart_preserves_ports_and_volumes
    run_test test_restart_preserves_image

    echo ""
    echo "--- volumes and mounts ---"
    run_test test_project_dir_mounted
    run_test test_shared_home_volume_persists

    echo ""
    echo "--- seed directory ---"
    run_test test_seed_directory
    run_test test_seed_no_clobber

    echo ""
    echo "--- env file ---"
    run_test test_env_file_project
    run_test test_env_file_global
    run_test test_env_file_override

    echo ""
    echo "--- mount file ---"
    run_test test_mounts_file_project
    run_test test_mounts_file_global
    run_test test_mounts_file_same_path_shorthand
    run_test test_mounts_file_same_path_with_options
    run_test test_mounts_file_override
    run_test test_mounts_file_readonly

    echo ""
    echo "--- port file ---"
    run_test test_ports_file_project

    echo ""
    echo "--- listing and cleanup ---"
    run_test test_list_shows_container
    run_test test_obliterate_removes_all

    echo ""
    echo "--- dstart (docker-enabled cages) ---"
    if [ "$DOCKER" = "docker" ]; then
        run_test test_dstart_mounts_socket_and_labels
        run_test test_dstart_agent_can_reach_daemon
        run_test test_status_shows_docker_mode
        run_test test_status_shows_docker_none_for_plain_start
        run_test test_start_reattaches_to_dstart_container
        run_test test_restart_preserves_docker_mode
    else
        echo "  (skipped: dstart integration tests require docker runtime)"
    fi

    print_summary
}

main "$@"
