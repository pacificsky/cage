#!/usr/bin/env bash
# tests/test_cage.sh — Automated test suite for cage.sh
#
# Usage: bash tests/test_cage.sh
#
# All tests use a mock docker command — no real Docker daemon is needed.
# The mock records every docker invocation and returns configurable responses,
# so we can verify that cage.sh issues the right docker commands in every
# scenario without side-effects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CAGE_SH="$REPO_DIR/cage.sh"

# ================================================================
# Minimal test framework
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

    # Run directly (not in a subshell) so assertion counters are visible.
    # Temporarily disable errexit so a single failure doesn't abort the suite.
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
# Mock docker infrastructure
# ================================================================

MOCK_DIR=""
MOCK_CALLS_FILE=""
MOCK_RESPONSES_DIR=""
FAKE_HOME=""
REAL_HOME="$HOME"

setup_mock() {
    MOCK_DIR="$(mktemp -d)"
    MOCK_CALLS_FILE="$MOCK_DIR/calls"
    MOCK_RESPONSES_DIR="$MOCK_DIR/responses"
    mkdir -p "$MOCK_RESPONSES_DIR"
    touch "$MOCK_CALLS_FILE"
    touch "$MOCK_DIR/env_calls"

    # Sandbox: cage.sh reads $HOME/.ssh, $HOME/.gitconfig, etc. to build
    # docker -v flags.  Point HOME at a throwaway directory so the tests
    # can never read or write anything under the real home directory.
    FAKE_HOME="$MOCK_DIR/fakehome"
    mkdir -p "$FAKE_HOME/.ssh" "$FAKE_HOME/.config/cage"
    touch "$FAKE_HOME/.gitconfig"
    export HOME="$FAKE_HOME"

    # --- mock docker executable ---
    cat > "$MOCK_DIR/docker" <<'MOCK_SCRIPT'
#!/usr/bin/env bash
MOCK_DIR="$(cd "$(dirname "$0")" && pwd)"
CALLS_FILE="$MOCK_DIR/calls"
RESPONSES_DIR="$MOCK_DIR/responses"

# Record the full invocation.
echo "$*" >> "$CALLS_FILE"
echo "${DOCKER_HOST:-<unset>} $*" >> "$MOCK_DIR/env_calls"

# Determine the subcommand (first positional arg).
subcmd="${1:-}"

# How many times has this subcommand been invoked (including this one)?
count=$(grep -c "^${subcmd} " "$CALLS_FILE" 2>/dev/null) || true
count=${count:-0}

# Look for a response file — most-specific first.
#   responses/<subcmd>_<N>   (Nth invocation of this subcmd)
#   responses/<subcmd>       (catch-all for this subcmd)
#   responses/default        (global fallback)
specific="$RESPONSES_DIR/${subcmd}_${count}"
general="$RESPONSES_DIR/${subcmd}"
default="$RESPONSES_DIR/default"

if [ -f "$specific" ]; then
    resp="$specific"
elif [ -f "$general" ]; then
    resp="$general"
elif [ -f "$default" ]; then
    resp="$default"
else
    # No configured response — succeed silently.
    exit 0
fi

# Response file format:
#   Line 1:  exit code
#   Lines 2+: stdout
exit_code="$(head -1 "$resp")"
tail -n +2 "$resp"
exit "$exit_code"
MOCK_SCRIPT
    chmod +x "$MOCK_DIR/docker"

    export PATH="$MOCK_DIR:$PATH"
}

teardown_mock() {
    export HOME="$REAL_HOME"
    if [ -n "$MOCK_DIR" ] && [ -d "$MOCK_DIR" ]; then
        rm -rf "$MOCK_DIR"
    fi
}

# Set the default response for a docker subcommand.
#   mock_docker_response <subcmd> <exit_code> [stdout_text]
mock_docker_response() {
    local subcmd="$1" exit_code="$2" output="${3:-}"
    if [ -n "$output" ]; then
        printf '%s\n%s\n' "$exit_code" "$output" > "$MOCK_RESPONSES_DIR/$subcmd"
    else
        printf '%s\n' "$exit_code" > "$MOCK_RESPONSES_DIR/$subcmd"
    fi
}

# Set the response for the Nth invocation of a docker subcommand.
#   mock_docker_response_n <subcmd> <N> <exit_code> [stdout_text]
mock_docker_response_n() {
    local subcmd="$1" n="$2" exit_code="$3" output="${4:-}"
    if [ -n "$output" ]; then
        printf '%s\n%s\n' "$exit_code" "$output" > "$MOCK_RESPONSES_DIR/${subcmd}_${n}"
    else
        printf '%s\n' "$exit_code" > "$MOCK_RESPONSES_DIR/${subcmd}_${n}"
    fi
}

# Return all recorded docker invocations (one per line).
mock_calls() { cat "$MOCK_CALLS_FILE"; }

# Return recorded invocations prefixed with the DOCKER_HOST each saw.
mock_env_calls() { cat "$MOCK_DIR/env_calls" 2>/dev/null; }

# Count how many times a subcommand was invoked.
mock_call_count() {
    local subcmd="$1"
    local n
    n=$(grep -c "^${subcmd} " "$MOCK_CALLS_FILE" 2>/dev/null) || true
    echo "${n:-0}"
}

# Clear recorded calls and responses between tests.
mock_reset() {
    : > "$MOCK_CALLS_FILE"
    : > "$MOCK_DIR/env_calls"
    rm -f "$MOCK_RESPONSES_DIR"/*
}

# --- mock colima (records calls; responses keyed by subcommand) ---
setup_colima_mock() {
    mkdir -p "$MOCK_DIR/colima_responses"
    : > "$MOCK_DIR/colima_calls"
    cat > "$MOCK_DIR/colima" <<'COLIMA_MOCK'
#!/usr/bin/env bash
MOCK_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$MOCK_DIR/colima_calls"
subcmd="${1:-}"
resp="$MOCK_DIR/colima_responses/$subcmd"
if [ -f "$resp" ]; then
    exit_code="$(head -1 "$resp")"
    tail -n +2 "$resp"
    exit "$exit_code"
fi
exit 0
COLIMA_MOCK
    chmod +x "$MOCK_DIR/colima"
}

mock_colima_response() {
    local subcmd="$1" exit_code="$2" output="${3:-}"
    mkdir -p "$MOCK_DIR/colima_responses"
    if [ -n "$output" ]; then
        printf '%s\n%s\n' "$exit_code" "$output" > "$MOCK_DIR/colima_responses/$subcmd"
    else
        printf '%s\n' "$exit_code" > "$MOCK_DIR/colima_responses/$subcmd"
    fi
}

colima_calls() { cat "$MOCK_DIR/colima_calls" 2>/dev/null; }

teardown_colima_mock() {
    rm -f "$MOCK_DIR/colima"
    rm -rf "$MOCK_DIR/colima_responses"
    rm -f "$MOCK_DIR/colima_calls"
}

# ================================================================
# Helpers
# ================================================================

# Run cage.sh capturing combined stdout+stderr.
run_cage() {
    local output exit_code=0
    output="$(bash "$CAGE_SH" "$@" 2>&1)" || exit_code=$?
    printf '%s' "$output"
    return "$exit_code"
}

# Compute the expected container name for the current directory.
expected_container_name() {
    local dir="${1:-$(pwd)}"
    local base
    base="$(basename "$dir")"
    local hash
    hash="$(printf '%s' "$dir" | shasum -a 256 | cut -c1-8)"
    echo "cage-${base}-${hash}"
}

# ================================================================
# Tests: container_name  (pure — no Docker)
# ================================================================

test_container_name_known_path() {
    local output
    output="$(bash -c '
        container_name() {
            local abs_path="$1"
            local dirname=$(basename "$abs_path")
            local hash=$(printf "%s" "$abs_path" | shasum -a 256 | cut -c1-8)
            echo "cage-${dirname}-${hash}"
        }
        container_name "/Users/aakash/src/cage"
    ')"
    # Expected value from CLAUDE.md example.
    assert_eq "cage-cage-5d780152" "$output" "known path matches documented name"
}

test_container_name_deterministic() {
    local a b
    a="$(bash -c '
        name() { local h=$(printf "%s" "$1" | shasum -a 256 | cut -c1-8); echo "cage-$(basename "$1")-${h}"; }
        name "/tmp/proj"
    ')"
    b="$(bash -c '
        name() { local h=$(printf "%s" "$1" | shasum -a 256 | cut -c1-8); echo "cage-$(basename "$1")-${h}"; }
        name "/tmp/proj"
    ')"
    assert_eq "$a" "$b" "same path always yields same name"
}

test_container_name_different_paths_differ() {
    local a b
    a="$(bash -c '
        name() { local h=$(printf "%s" "$1" | shasum -a 256 | cut -c1-8); echo "cage-$(basename "$1")-${h}"; }
        name "/tmp/project-a"
    ')"
    b="$(bash -c '
        name() { local h=$(printf "%s" "$1" | shasum -a 256 | cut -c1-8); echo "cage-$(basename "$1")-${h}"; }
        name "/tmp/project-b"
    ')"
    if [ "$a" = "$b" ]; then fail "different paths produced identical name"; fi
}

test_container_name_uses_basename() {
    local output
    output="$(bash -c '
        name() { local h=$(printf "%s" "$1" | shasum -a 256 | cut -c1-8); echo "cage-$(basename "$1")-${h}"; }
        name "/very/deep/nested/myapp"
    ')"
    assert_contains "$output" "cage-myapp-" "name prefix is cage-<basename>-"
}

# ================================================================
# Tests: CLI — help and version
# ================================================================

test_no_args_shows_help() {
    local out
    out="$(run_cage)" || true
    assert_contains "$out" "Usage:" "no args prints usage"
}

test_help_command() {
    local out; out="$(run_cage help)";    assert_contains "$out" "Usage:"
}
test_help_h_flag() {
    local out; out="$(run_cage -h)";      assert_contains "$out" "Usage:"
}
test_help_long_flag() {
    local out; out="$(run_cage --help)";  assert_contains "$out" "Usage:"
}
test_version_V() {
    local out; out="$(run_cage -V)";      assert_contains "$out" "cage 0.11.0"
}
test_version_long() {
    local out; out="$(run_cage --version)"; assert_contains "$out" "cage 0.11.0"
}
test_version_command() {
    local out; out="$(run_cage version)"; assert_contains "$out" "cage 0.11.0"
}
test_help_mentions_dstart() {
    local out; out="$(run_cage help)"
    assert_contains "$out" "dstart" "help documents dstart"
    assert_contains "$out" "CAGE_SRC_ROOT" "help documents CAGE_SRC_ROOT"
}

test_unknown_command_fails() {
    local out rc=0
    out="$(run_cage bogus 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "Unknown command: bogus" "error message"
}

# ================================================================
# Tests: ensure_docker
# ================================================================

test_docker_not_running_error() {
    mock_reset
    mock_docker_response "info" 1 ""
    local out rc=0
    out="$(run_cage stop 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "Docker is not running" "error message"
}

test_podman_fallback() {
    # When docker is absent but podman exists, cage.sh should use podman.
    mock_reset
    # Create a separate bin dir containing only podman (no docker).
    local podman_dir="$MOCK_DIR/podman-only"
    mkdir -p "$podman_dir"
    cp "$MOCK_DIR/docker" "$podman_dir/podman"
    chmod +x "$podman_dir/podman"
    # Symlink essential tools so cage.sh can run (basename, shasum, etc).
    # dirname is required by the mock itself: without it MOCK_DIR resolution
    # degrades to $PWD (bash cd "" is a no-op) and the mock's calls/env_calls
    # files leak into the repository root.
    for cmd in bash printf basename shasum cut grep head tail cat sed xargs dirname; do
        local cmd_path
        cmd_path="$(command -v "$cmd" 2>/dev/null)" || true
        [ -n "$cmd_path" ] && ln -sf "$cmd_path" "$podman_dir/$cmd"
    done
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    # Use only podman_dir — docker is absent, so cage.sh falls back to podman.
    local out; out="$(PATH="$podman_dir" run_cage status 2>&1)"
    assert_contains "$out" "State:" "podman fallback works"
    rm -rf "$podman_dir"
}

# ================================================================
# Tests: container_state  (via cmd_status)
# ================================================================

test_status_shows_running() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "port" 0 "3000/tcp -> 0.0.0.0:3000"
    local out; out="$(run_cage status)"
    assert_contains "$out" "State:     running" "state"
    assert_contains "$out" "3000" "port mapping"
}

test_status_shows_stopped() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "false"
    mock_docker_response "port" 0 ""
    local out; out="$(run_cage status)"
    assert_contains "$out" "State:     stopped" "state"
}

test_status_shows_none() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local out; out="$(run_cage status)"
    assert_contains "$out" "State:     none" "state"
}

test_status_shows_container_name() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local expected_name
    expected_name="$(expected_container_name)"
    local out; out="$(run_cage status)"
    assert_contains "$out" "Container: $expected_name" "container name in output"
}

test_status_no_ports_when_none() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local out; out="$(run_cage status)"
    assert_not_contains "$out" "Ports:" "no port section when state=none"
}

test_status_shows_docker_host() {
    mock_reset
    mock_uname Linux
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 0 "true"   # state
    mock_docker_response_n "inspect" 2 0 "host"   # cage.docker label
    mock_docker_response "port" 0 ""
    local out; out="$(run_cage status)"
    assert_contains "$out" "Docker:    host" "docker mode shown"
    unmock_uname
}

test_status_shows_docker_none() {
    mock_reset
    mock_uname Linux
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 0 "true"
    mock_docker_response_n "inspect" 2 0 ""
    mock_docker_response "port" 0 ""
    local out; out="$(run_cage status)"
    assert_contains "$out" "Docker:    none" "docker: none for plain cage"
    unmock_uname
}

test_status_shows_recorded_config_when_stopped() {
    mock_reset
    mock_uname Linux
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 0 "false"              # state: stopped
    mock_docker_response_n "inspect" 2 0 ""                   # cage.docker label
    mock_docker_response "port" 0 ""                          # nothing bound
    mock_docker_response_n "inspect" 3 0 "3000:3000 8080:80"  # cage.ports label
    mock_docker_response_n "inspect" 4 0 "/models:/models"    # cage.volumes label
    local out; out="$(run_cage status)"
    assert_contains "$out" "3000:3000 8080:80 (configured" "recorded ports shown for stopped cage"
    assert_contains "$out" "Mounts:" "mounts section shown"
    assert_contains "$out" "/models:/models" "recorded mount listed"
    unmock_uname
}

test_status_no_docker_line_when_no_container() {
    mock_reset
    mock_uname Linux
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local out; out="$(run_cage status)"
    assert_not_contains "$out" "Docker:" "no docker line when state=none"
    unmock_uname
}

# ================================================================
# Tests: cmd_stop
# ================================================================

test_stop_running_container() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "stop" 0 ""
    local out; out="$(run_cage stop 2>&1)"
    assert_contains "$out" "Stopping" "info message"
    assert_eq "1" "$(mock_call_count stop)" "docker stop called"
}

test_stop_already_stopped() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "false"
    local out; out="$(run_cage stop 2>&1)"
    assert_contains "$out" "already stopped" "info message"
}

test_stop_no_container() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local out rc=0
    out="$(run_cage stop 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "No container" "error message"
}

# ================================================================
# Tests: cmd_rm
# ================================================================

test_rm_running_uses_force() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "rm" 0 ""
    local out; out="$(run_cage rm 2>&1)"
    assert_contains "$out" "Stopping and removing" "info message"
    assert_contains "$(mock_calls)" "rm -f" "docker rm -f for running container"
}

test_rm_stopped_no_force() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "false"
    mock_docker_response "rm" 0 ""
    local out; out="$(run_cage rm 2>&1)"
    assert_contains "$out" "Removing" "info message"
}

test_rm_no_container() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local out rc=0
    out="$(run_cage rm 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "No container" "error message"
}

# ================================================================
# Tests: cmd_enter  (start subcommand)
# ================================================================

test_start_new_container_pulls_and_creates() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    local out; out="$(run_cage start 2>&1)"
    assert_contains "$out" "Pulling latest image" "pulls image"
    assert_contains "$out" "Creating" "creating message"
    assert_eq "1" "$(mock_call_count create)" "docker create called"
    assert_eq "1" "$(mock_call_count pull)" "docker pull called"
}

test_start_reattach_running() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "image" 1 ""     # image_newer_available → false
    mock_docker_response "attach" 0 ""
    local out; out="$(run_cage start 2>&1)"
    assert_contains "$out" "Re-attaching" "reattach message"
    assert_eq "1" "$(mock_call_count attach)" "docker attach called"
}

test_start_restart_stopped() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "false"
    mock_docker_response "image" 1 ""
    mock_docker_response "start" 0 ""
    local out; out="$(run_cage start 2>&1)"
    assert_contains "$out" "Restarting" "restart message"
    assert_eq "1" "$(mock_call_count start)" "docker start called"
}

test_start_ignores_port_flags_when_running() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "image" 1 ""
    mock_docker_response "attach" 0 ""
    local out; out="$(run_cage start -p 3000:3000 2>&1)"
    assert_contains "$out" "ignoring -p/-v flags" "port-ignored warning"
}

test_start_ignores_port_flags_when_stopped() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "false"
    mock_docker_response "image" 1 ""
    mock_docker_response "start" 0 ""
    local out; out="$(run_cage start -p 3000:3000 2>&1)"
    assert_contains "$out" "ignoring -p/-v flags" "port-ignored warning"
}

test_start_passes_port_to_docker_create() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage start -p 3000:3000 >/dev/null 2>&1 || true
    assert_contains "$(mock_calls)" "-p 3000:3000" "port flag in docker create"
}

test_start_multiple_ports() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage start -p 3000:3000 -p 8080:8080 >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 3000:3000" "first port"
    assert_contains "$calls" "-p 8080:8080" "second port"
}

test_start_volume_flag() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage start -v /data:/data >/dev/null 2>&1 || true
    assert_contains "$(mock_calls)" "-v /data:/data" "volume flag in docker create"
}

test_start_mixed_port_and_volume() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage start -p 3000:3000 -v /data:/data -p 8080:8080 >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 3000:3000" "port flag"
    assert_contains "$calls" "-v /data:/data" "volume flag"
    assert_contains "$calls" "-p 8080:8080" "second port"
}

test_start_p_missing_arg() {
    mock_reset
    mock_docker_response "info" 0 ""
    local out rc=0
    out="$(run_cage start -p 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "-p requires an argument" "error message"
}

test_start_v_missing_arg() {
    mock_reset
    mock_docker_response "info" 0 ""
    local out rc=0
    out="$(run_cage start -v 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "-v requires an argument" "error message"
}

test_start_unknown_flag() {
    mock_reset
    mock_docker_response "info" 0 ""
    local out rc=0
    out="$(run_cage start --bogus 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "Unknown flag for start" "error message"
}

test_start_no_pull_for_local_image() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    local out
    out="$(CAGE_IMAGE="my-local-image" run_cage start 2>&1)"
    assert_not_contains "$out" "Pulling" "no pull for local image"
    assert_eq "0" "$(mock_call_count pull)" "docker pull not called"
}

test_start_docker_create_mounts() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage start >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    local pdir; pdir="$(pwd)"
    assert_contains "$calls" "-v ${pdir}:${pdir}" "project dir mounted"
    assert_contains "$calls" "--workdir ${pdir}" "workdir is project dir"
    assert_contains "$calls" "cage.project=${pdir}" "cage.project label"
    assert_contains "$calls" "cage-home:/home/vscode" "shared home volume"
    assert_not_contains "$calls" "/home/vscode/.ssh" "no ssh dir mount"
    assert_not_contains "$calls" "/home/vscode/.gitconfig" "no gitconfig bind-mount"
}

test_start_container_hostname() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage start >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    local expected_name; expected_name="$(expected_container_name)"
    assert_contains "$calls" "--hostname ${expected_name}" "hostname matches container name"
    assert_contains "$calls" "--name ${expected_name}" "name matches expected"
}

test_start_cage_image_override() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    CAGE_IMAGE="custom/img:v2" run_cage start >/dev/null 2>&1 || true
    assert_contains "$(mock_calls)" "custom/img:v2" "custom image in docker create"
}

# ================================================================
# Tests: cmd_shell
# ================================================================

test_shell_running() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "exec" 0 ""
    local out; out="$(run_cage shell 2>&1)"
    assert_contains "$out" "Opening shell" "info message"
    assert_eq "1" "$(mock_call_count exec)" "docker exec called"
}

test_shell_not_running() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "false"
    local out rc=0
    out="$(run_cage shell 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "not running" "error message"
}

test_shell_no_container() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local out rc=0
    out="$(run_cage shell 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "not running" "error message"
}

# ================================================================
# Tests: cmd_list
# ================================================================

test_list_filters_by_label() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 "$(printf 'cage-app-12345678\tUp 2 hours\t/home/user/app\tghcr.io/pacificsky/devcontainer-lite:latest')"
    mock_docker_response "inspect" 0 "/cage-app-12345678|sha256:abcdef1234567890"
    mock_docker_response "image" 0 "sha256:abcdef1234567890|2025-03-01T12:00:00Z"
    local out; out="$(run_cage list)"
    assert_contains "$out" "cage-app" "lists cage containers"
    assert_contains "$(mock_calls)" "label=cage.project" "filters by cage.project label"
    assert_contains "$out" "2025-03-01" "shows image creation date"
}

test_list_shows_image_column_header() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 ""
    local out; out="$(run_cage list)"
    assert_contains "$out" "IMAGE" "header includes IMAGE column"
    assert_contains "$out" "PROJECT" "header includes PROJECT column"
}

test_list_shows_image_tag_and_sha() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 "$(printf 'cage-app-12345678\tUp 2 hours\t/home/user/app\tghcr.io/pacificsky/devcontainer-lite:20250301')"
    mock_docker_response "inspect" 0 "/cage-app-12345678|sha256:abcdef1234567890faded"
    mock_docker_response "image" 0 "sha256:abcdef1234567890faded|2025-03-01T12:00:00Z"
    local out; out="$(run_cage list)"
    assert_contains "$out" "20250301" "shows image tag"
    assert_contains "$out" "abcdef12" "shows short image SHA"
    assert_contains "$out" "2025-03-01" "shows image creation date"
}

test_list_shows_image_sha_only_when_no_tag() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 "$(printf 'cage-app-12345678\tUp 2 hours\t/home/user/app\tubuntu')"
    mock_docker_response "inspect" 0 "/cage-app-12345678|sha256:abcdef1234567890faded"
    mock_docker_response "image" 0 "sha256:abcdef1234567890faded|2025-06-15T08:30:00Z"
    local out; out="$(run_cage list)"
    assert_contains "$out" "abcdef12" "shows short SHA when no tag"
    assert_not_contains "$out" "ubuntu" "image name not shown as tag"
    assert_contains "$out" "2025-06-15" "shows date when no tag"
}

test_list_handles_registry_port_in_image() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 "$(printf 'cage-app-12345678\tUp 2 hours\t/home/user/app\tregistry.example.com:5000/myapp:v2')"
    mock_docker_response "inspect" 0 "/cage-app-12345678|sha256:abcdef1234567890faded"
    mock_docker_response "image" 0 "sha256:abcdef1234567890faded|2025-03-01T12:00:00Z"
    local out; out="$(run_cage list)"
    assert_contains "$out" "v2" "shows tag from image with registry port"
    assert_not_contains "$out" "5000" "registry port not treated as tag"
    assert_contains "$out" "2025-03-01" "shows image creation date"
}

test_list_shows_date_when_available() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 "$(printf 'cage-app-12345678\tUp 2 hours\t/home/user/app\tghcr.io/pacificsky/devcontainer-lite:latest')"
    mock_docker_response "inspect" 0 "/cage-app-12345678|sha256:abcdef1234567890faded"
    mock_docker_response "image" 0 "sha256:abcdef1234567890faded|2025-03-01T12:00:00Z"
    local out; out="$(run_cage list)"
    assert_contains "$out" "latest (abcdef12, 2025-03-01)" "shows tag, SHA, and date combined"
}

test_list_handles_missing_image_date() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 "$(printf 'cage-app-12345678\tUp 2 hours\t/home/user/app\tghcr.io/pacificsky/devcontainer-lite:latest')"
    mock_docker_response "inspect" 0 "/cage-app-12345678|sha256:abcdef1234567890faded"
    mock_docker_response "image" 1 ""
    local out; out="$(run_cage list)"
    assert_contains "$out" "latest (abcdef12)" "falls back to tag and SHA without date"
    assert_not_contains "$out" "latest (abcdef12," "no dangling comma when date is missing"
}

# ================================================================
# Tests: cmd_obliterate (global)
# ================================================================

test_obliterate_removes_all_containers_and_volume() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 "abc123
def456"
    mock_docker_response "rm" 0 ""
    mock_docker_response "volume" 0 ""
    local out; out="$(run_cage obliterate 2>&1)"
    assert_contains "$out" "Removing all cage containers" "removes containers"
    assert_contains "$out" "Removing shared home volume" "removes volume"
    assert_contains "$(mock_calls)" "rm -f" "docker rm -f called"
}

test_obliterate_no_containers_no_volume() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 ""
    mock_docker_response "volume" 1 ""
    local out; out="$(run_cage obliterate 2>&1)"
    assert_contains "$out" "No cage containers to remove" "no containers message"
    assert_contains "$out" "No shared home volume to remove" "no volume message"
}

test_obliterate_containers_but_no_volume() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 "abc123"
    mock_docker_response "rm" 0 ""
    mock_docker_response "volume" 1 ""
    local out; out="$(run_cage obliterate 2>&1)"
    assert_contains "$out" "Removing all cage containers" "removes containers"
    assert_contains "$out" "No shared home volume to remove" "no volume"
}

# ================================================================
# Tests: cmd_rmconfig
# ================================================================

test_rmconfig_stops_containers_and_removes_volume() {
    mock_reset
    mock_docker_response "info" 0 ""
    # ps -a (all cage containers)
    mock_docker_response_n "ps" 1 0 "abc123"
    # ps (running only)
    mock_docker_response_n "ps" 2 0 "abc123"
    mock_docker_response "stop" 0 ""
    mock_docker_response "volume" 0 ""
    local out; out="$(run_cage rmconfig 2>&1)"
    assert_contains "$out" "Stopping running cage containers" "stops containers"
    assert_contains "$out" "Removing shared home volume" "removes volume"
}

test_rmconfig_no_containers_removes_volume() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 ""
    mock_docker_response "volume" 0 ""
    local out; out="$(run_cage rmconfig 2>&1)"
    assert_not_contains "$out" "Stopping" "no stop needed"
    assert_contains "$out" "Removing shared home volume" "removes volume"
}

test_rmconfig_no_volume() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 ""
    mock_docker_response "volume" 1 ""
    local out; out="$(run_cage rmconfig 2>&1)"
    assert_contains "$out" "No shared home volume to remove" "no volume message"
}

# ================================================================
# Tests: list / obliterate / rmconfig sweep the cage VM daemon
# ================================================================

test_list_includes_cage_vm_daemon() {
    mock_reset
    mock_uname Darwin
    make_cage_vm_socket
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 ""
    local out; out="$(DOCKER_HOST='' run_cage list)"
    assert_eq "2" "$(mock_call_count ps)" "ps against both daemons"
    assert_contains "$(mock_env_calls)" "unix://$HOME/.colima/cage/docker.sock ps" "second ps hits cage VM"
    local headers
    headers="$(printf '%s\n' "$out" | grep -c "NAMES")" || true
    assert_eq "1" "$headers" "single header row"
    remove_cage_vm_socket
    unmock_uname
}

test_list_single_daemon_without_cage_vm() {
    mock_reset
    mock_uname Darwin
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 ""
    DOCKER_HOST='' run_cage list >/dev/null
    assert_eq "1" "$(mock_call_count ps)" "one ps when no cage VM socket"
    unmock_uname
}

test_obliterate_covers_cage_vm() {
    mock_reset
    mock_uname Darwin
    make_cage_vm_socket
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 ""
    mock_docker_response "volume" 1 ""
    local out; out="$(DOCKER_HOST='' run_cage obliterate 2>&1)"
    assert_eq "2" "$(mock_call_count ps)" "both daemons swept"
    assert_contains "$out" "colima delete --profile cage" "VM removal hint"
    remove_cage_vm_socket
    unmock_uname
}

test_rmconfig_covers_cage_vm() {
    mock_reset
    mock_uname Darwin
    make_cage_vm_socket
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 ""
    mock_docker_response "volume" 1 ""
    DOCKER_HOST='' run_cage rmconfig >/dev/null 2>&1
    assert_eq "2" "$(mock_call_count ps)" "both daemons swept"
    remove_cage_vm_socket
    unmock_uname
}

# ================================================================
# Tests: cmd_restart
# ================================================================

test_restart_existing_container() {
    mock_reset
    mock_docker_response "info" 0 ""
    # First inspect: container exists (running)
    mock_docker_response_n "inspect" 1 0 "true"
    # Inspects 2-5: cage.docker / cage.ports / cage.volumes / cage.image
    # label reads → unmocked, so all empty (plain cage, no recorded config)
    # docker rm -f succeeds
    mock_docker_response "rm" 0 ""
    # Sixth inspect in cmd_enter: container gone → create new
    mock_docker_response_n "inspect" 6 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    local out; out="$(run_cage restart 2>&1)"
    assert_contains "$(mock_calls)" "rm -f" "old container removed"
    assert_eq "1" "$(mock_call_count create)" "new container created"
}

test_restart_no_container() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local out rc=0
    out="$(run_cage restart 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "No container" "error message"
}

test_restart_preserves_docker_mode() {
    mock_reset
    mock_uname Linux
    mock_stat_gid 999
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 0 "true"   # state: exists
    mock_docker_response_n "inspect" 2 0 "host"   # cage.docker label
    # inspects 3-5 (cage.ports/cage.volumes/cage.image labels): unmocked → empty
    mock_docker_response "rm" 0 ""
    mock_docker_response_n "inspect" 6 1 ""       # after rm: none → create
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    local out; out="$(run_cage restart 2>&1)"
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "cage.docker=host" "recreated docker-enabled"
    assert_contains "$calls" "-v /var/run/docker.sock:/var/run/docker.sock" "socket re-mounted"
    assert_contains "$out" "DOCKER-ENABLED CAGE" "banner on host-mode recreate"
    unmock_stat
    unmock_uname
}

test_restart_plain_container_stays_plain() {
    mock_reset
    mock_uname Linux
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 0 "true"
    mock_docker_response_n "inspect" 2 0 ""       # no label
    # inspects 3-5 (cage.ports/cage.volumes/cage.image labels): unmocked → empty
    mock_docker_response "rm" 0 ""
    mock_docker_response_n "inspect" 6 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage restart >/dev/null 2>&1 || true
    # Check for the label assignment "cage.docker=" rather than the bare
    # substring: preserve_docker_mode reads the label via `docker inspect -f
    # '{{index .Config.Labels "cage.docker"}}'`, whose format string contains
    # "cage.docker" and is recorded in mock_calls.  Only a create with a docker
    # label writes "cage.docker=<mode>", which is what "stays plain" must avoid.
    assert_not_contains "$(mock_calls)" "cage.docker=" "no docker args for plain cage"
    unmock_uname
}

test_start_records_flag_labels() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""   # no container → create
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage start -p 3000:3000 -p 5432:5432 -v /models:/models >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "cage.ports=3000:3000 5432:5432" "ports recorded in label"
    assert_contains "$calls" "cage.volumes=/models:/models" "volumes recorded in label"
}

test_start_without_flags_records_no_flag_labels() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage start >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_not_contains "$calls" "cage.ports=" "no ports label without -p"
    assert_not_contains "$calls" "cage.volumes=" "no volumes label without -v"
}

test_restart_restores_ports_and_volumes() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 0 "true"                 # state: exists
    mock_docker_response_n "inspect" 2 0 ""                     # cage.docker: plain
    mock_docker_response_n "inspect" 3 0 "3000:3000 5432:5432"  # cage.ports label
    # cage.volumes label: newline-delimited, first entry has a space in the path
    mock_docker_response_n "inspect" 4 0 "/my data:/data
/models:/models"
    # inspect 5 (cage.image label): unmocked → empty
    mock_docker_response "rm" 0 ""
    mock_docker_response_n "inspect" 6 1 ""                     # gone → create
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage restart >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 3000:3000" "first port restored"
    assert_contains "$calls" "-p 5432:5432" "second port restored"
    assert_contains "$calls" "-v /my data:/data" "spaced volume restored"
    assert_contains "$calls" "-v /models:/models" "second volume restored"
    # Restored flags flow through cmd_enter as CLI flags, so the new
    # container gets the labels re-recorded and survives the next restart.
    assert_contains "$calls" "cage.ports=3000:3000 5432:5432" "ports label re-recorded"
    assert_contains "$calls" "cage.volumes=/my data:/data" "volumes label re-recorded"
}

test_restart_restored_volume_wins_over_mount_file() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 0 "true"
    # inspects 2-3 (cage.docker/cage.ports): unmocked → empty
    mock_docker_response_n "inspect" 4 0 "/mymodels:/models"    # cage.volumes label
    # inspect 5 (cage.image label): unmocked → empty
    mock_docker_response "rm" 0 ""
    mock_docker_response_n "inspect" 6 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    local project_dir; project_dir="$(mktemp -d)"
    echo "/other:/models" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage restart >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v /mymodels:/models" "restored -v applied"
    assert_not_contains "$calls" "/other:/models" "mount file entry for same target skipped"

    rm -rf "$project_dir"
}

test_start_records_image_label() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""   # no container → create
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    CAGE_IMAGE="example.com/custom:1" run_cage start >/dev/null 2>&1 || true
    assert_contains "$(mock_calls)" "cage.image=example.com/custom:1" "image recorded in label"
}

test_restart_recreates_from_recorded_image() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 0 "true"               # state: exists
    # inspects 2-4 (cage.docker/cage.ports/cage.volumes): unmocked → empty
    mock_docker_response_n "inspect" 5 0 "example.com/img:7"  # cage.image label
    mock_docker_response "rm" 0 ""
    mock_docker_response_n "inspect" 6 1 ""                   # gone → create
    mock_docker_response "image" 0 ""                         # image present locally
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    CAGE_IMAGE='' run_cage restart >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "example.com/img:7" "recreated from recorded image"
    assert_contains "$calls" "cage.image=example.com/img:7" "image label re-recorded"
    assert_eq "0" "$(mock_call_count pull)" "no pull when restoring recorded image"
}

test_restart_env_image_overrides_recorded() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 0 "true"
    # inspects 2-4: unmocked → empty
    mock_docker_response_n "inspect" 5 0 "example.com/img:7"  # cage.image (read, then outranked)
    mock_docker_response "rm" 0 ""
    mock_docker_response_n "inspect" 6 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    CAGE_IMAGE="example.com/override:2" run_cage restart >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "cage.image=example.com/override:2" "explicit CAGE_IMAGE wins"
    assert_eq "1" "$(mock_call_count pull)" "explicit image is pulled"
}

test_upgrade_targets_recorded_image() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 0 "true"               # state
    mock_docker_response_n "inspect" 2 0 "example.com/img:7"  # cage.image label
    mock_docker_response "pull" 0 ""
    mock_docker_response_n "inspect" 3 0 "sha256:old"         # container image id
    mock_docker_response "image" 0 "sha256:new"               # newer available
    # inspects 4-6 (cage.docker/cage.ports/cage.volumes): unmocked → empty
    mock_docker_response "rm" 0 ""
    mock_docker_response_n "inspect" 7 1 ""                   # gone → create
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    CAGE_IMAGE='' run_cage upgrade >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "pull example.com/img:7" "pulls the recorded image, not the default"
    assert_not_contains "$calls" "pull ghcr.io/pacificsky" "default image not pulled"
    assert_eq "1" "$(mock_call_count pull)" "single pull (cmd_enter skips the re-pull)"
}

test_restart_hints_when_cage_vm_down() {
    mock_reset
    mock_uname Darwin
    mkdir -p "$HOME/.colima/cage"      # VM profile exists, but no socket
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local out rc=0
    out="$(DOCKER_HOST='' run_cage restart 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "No container" "base error kept"
    assert_contains "$out" "colima start --profile cage" "hint to start the cage VM"
    rm -rf "$HOME/.colima"
    unmock_uname
}

test_upgrade_preserves_docker_mode() {
    mock_reset
    mock_uname Linux
    mock_stat_gid 999
    mock_docker_response "info" 0 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response_n "inspect" 1 0 "true"        # state
    # inspect 2 (cage.image label): unmocked → empty → default image kept
    mock_docker_response_n "inspect" 3 0 "sha256:old"  # container image id
    mock_docker_response "image" 0 "sha256:new"        # newer available
    mock_docker_response_n "inspect" 4 0 "host"        # cage.docker label
    # inspects 5-6 (cage.ports/cage.volumes labels): unmocked → empty
    mock_docker_response "rm" 0 ""
    mock_docker_response_n "inspect" 7 1 ""            # gone → create
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage upgrade >/dev/null 2>&1 || true
    assert_contains "$(mock_calls)" "cage.docker=host" "upgrade keeps docker mode"
    unmock_stat
    unmock_uname
}

test_dstart_warns_when_image_lacks_docker_cli() {
    mock_reset
    mock_uname Linux
    mock_stat_gid 999
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "run" 1 ""      # command -v docker fails in image
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    local out; out="$(run_cage dstart 2>&1)"
    assert_contains "$out" "no docker CLI" "warning shown"
    assert_eq "1" "$(mock_call_count create)" "creation proceeds anyway"
    unmock_stat
    unmock_uname
}

test_dstart_no_warning_when_docker_cli_present() {
    mock_reset
    mock_uname Linux
    mock_stat_gid 999
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "run" 0 "/usr/bin/docker"
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    local out; out="$(run_cage dstart 2>&1)"
    assert_not_contains "$out" "no docker CLI" "no warning when CLI present"
    unmock_stat
    unmock_uname
}

test_start_never_runs_cli_check() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage start >/dev/null 2>&1 || true
    assert_eq "0" "$(mock_call_count run)" "plain start never docker-runs the image"
}

# ================================================================
# Tests: cmd_update
# ================================================================

test_update_rejects_local_image() {
    mock_reset
    mock_docker_response "info" 0 ""
    local out rc=0
    out="$(CAGE_IMAGE="local-only" run_cage update 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "Cannot update local image" "error message"
}

test_update_pulls_image() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "pull" 0 ""
    local out; out="$(run_cage update 2>&1)"
    assert_contains "$out" "Pulling latest image" "pulls message"
    assert_eq "1" "$(mock_call_count pull)" "docker pull called"
    assert_eq "0" "$(mock_call_count inspect)" "no container inspect"
    assert_eq "0" "$(mock_call_count create)" "no docker create"
}

# ================================================================
# Tests: cmd_upgrade
# ================================================================

test_upgrade_rejects_local_image() {
    mock_reset
    mock_docker_response "info" 0 ""
    local out rc=0
    out="$(CAGE_IMAGE="local-only" run_cage upgrade 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "Cannot update local image" "error message"
}

test_upgrade_pulls_and_recreates_when_newer() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "pull" 0 ""
    # First inspect: container exists (running)
    mock_docker_response_n "inspect" 1 0 "true"
    # inspect 2 (cage.image label): unmocked → empty → default image kept
    # image inspect returns different ID → newer available
    mock_docker_response_n "inspect" 3 0 "sha256:old"
    mock_docker_response "image" 0 "sha256:new"
    # Inspects 4-6: cage.docker / cage.ports / cage.volumes label reads →
    # empty (plain cage, no recorded flags)
    mock_docker_response_n "inspect" 4 0 ""
    mock_docker_response "rm" 0 ""
    # After rm, cmd_enter inspect: container gone → create new
    mock_docker_response_n "inspect" 7 1 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    local out; out="$(run_cage upgrade 2>&1)"
    assert_contains "$out" "Pulling latest image" "pulls image"
    # pull called twice: once in cmd_update, once in cmd_enter (creating new container)
    assert_eq "2" "$(mock_call_count pull)" "docker pull called"
    assert_contains "$out" "Removing old container" "removes old container"
    assert_eq "1" "$(mock_call_count create)" "docker create called"
}

test_upgrade_pulls_no_recreate_when_current() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "pull" 0 ""
    # Container exists (running)
    mock_docker_response_n "inspect" 1 0 "true"
    # inspect 2 (cage.image label): unmocked → empty → default image kept
    # image_newer_available: container image and latest image are same
    mock_docker_response_n "inspect" 3 0 "sha256:same"
    mock_docker_response "image" 0 "sha256:same"
    local out; out="$(run_cage upgrade 2>&1)"
    assert_contains "$out" "Pulling latest image" "pulls image"
    assert_contains "$out" "already on the latest image" "already up to date"
    assert_eq "0" "$(mock_call_count rm)" "no docker rm"
    assert_eq "0" "$(mock_call_count create)" "no docker create"
}

test_upgrade_no_existing_container() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "inspect" 1 ""
    local out; out="$(run_cage upgrade 2>&1)"
    assert_contains "$out" "Pulling latest image" "pulls image"
    assert_contains "$out" "No existing container" "info message"
    assert_eq "0" "$(mock_call_count rm)" "no docker rm"
    assert_eq "0" "$(mock_call_count create)" "no docker create"
}

# ================================================================
# Tests: image_newer_available hint in start
# ================================================================

test_start_running_hints_newer_image() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "sha256:old"
    mock_docker_response "image" 0 "sha256:new"
    mock_docker_response "attach" 0 ""
    local out; out="$(run_cage start 2>&1)"
    assert_contains "$out" "cage upgrade" "upgrade hint shown"
}

# ================================================================
# Tests: SSH agent forwarding
# ================================================================

test_start_ssh_agent_linux() {
    # On Linux with SSH_AUTH_SOCK pointing to a real socket, cage.sh should
    # bind-mount it into the container.
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    # Mock uname to report Linux (test may run on macOS).
    cat > "$MOCK_DIR/uname" <<'UNAME_SCRIPT'
#!/usr/bin/env bash
echo "Linux"
UNAME_SCRIPT
    chmod +x "$MOCK_DIR/uname"

    local sock="$MOCK_DIR/fake-agent.sock"
    # Create a Unix socket so the -S test passes.
    python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
" "$sock" 2>/dev/null || socat UNIX-LISTEN:"$sock",fork /dev/null &

    SSH_AUTH_SOCK="$sock" run_cage start >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v ${sock}:/tmp/ssh-agent.sock" "socket bind-mounted"
    assert_contains "$calls" "SSH_AUTH_SOCK=/tmp/ssh-agent.sock" "SSH_AUTH_SOCK set"
    rm -f "$sock"
    rm -f "$MOCK_DIR/uname"
}

test_start_ssh_no_agent() {
    # When SSH_AUTH_SOCK is unset on Linux, no SSH flags should be added.
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    # Mock uname to report Linux (test may run on macOS).
    cat > "$MOCK_DIR/uname" <<'UNAME_SCRIPT'
#!/usr/bin/env bash
echo "Linux"
UNAME_SCRIPT
    chmod +x "$MOCK_DIR/uname"

    unset SSH_AUTH_SOCK
    run_cage start >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_not_contains "$calls" "SSH_AUTH_SOCK" "no SSH env when agent absent"
    assert_not_contains "$calls" "ssh-agent.sock" "no ssh socket mount"
    assert_not_contains "$calls" "ssh-auth.sock" "no ssh socket mount"
    rm -f "$MOCK_DIR/uname"
}

# Helper: make the test environment look like macOS with Colima.
# Creates mock uname (returns Darwin) and mock colima in MOCK_DIR (already on PATH).
# Sets up docker context inspect to return a Colima socket path.
setup_colima_env() {
    local forward_agent="${1:-false}"

    # Mock uname to report Darwin.
    cat > "$MOCK_DIR/uname" <<'UNAME_SCRIPT'
#!/usr/bin/env bash
for arg in "$@"; do
    if [ "$arg" = "-s" ]; then echo "Darwin"; exit 0; fi
done
# Fallback for bare "uname"
echo "Darwin"
UNAME_SCRIPT
    chmod +x "$MOCK_DIR/uname"

    # Mock colima binary (just needs to exist).
    cat > "$MOCK_DIR/colima" <<'COLIMA_SCRIPT'
#!/usr/bin/env bash
exit 0
COLIMA_SCRIPT
    chmod +x "$MOCK_DIR/colima"

    # docker context inspect returns a Colima socket path.
    mock_docker_response "context" 0 "unix:///Users/testuser/.colima/default/docker.sock"

    # Create Colima config.
    mkdir -p "$HOME/.colima/default"
    cat > "$HOME/.colima/default/colima.yaml" <<EOF
cpu: 4
memory: 8
forwardAgent: ${forward_agent}
EOF
}

teardown_colima_env() {
    rm -f "$MOCK_DIR/uname" "$MOCK_DIR/colima"
    rm -rf "$HOME/.colima"
}

test_start_ssh_macos_uses_vm_socket() {
    # On macOS, cage.sh should use /run/host-services/ssh-auth.sock
    # regardless of SSH_AUTH_SOCK value.
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    setup_colima_env true

    SSH_AUTH_SOCK="/tmp/not-a-real-socket" run_cage start >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "/run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock" "VM socket mounted"
    assert_contains "$calls" "SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock" "SSH_AUTH_SOCK points to VM socket"
    assert_not_contains "$calls" "/tmp/not-a-real-socket" "host socket NOT mounted"
    teardown_colima_env
}

test_start_colima_warns_no_ssh_agent() {
    # When Colima is active but forwardAgent is false, warn the user.
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    setup_colima_env false

    local out
    out="$(run_cage start 2>&1)" || true
    assert_contains "$out" "Colima does not have SSH agent forwarding enabled" "warning shown"
    assert_contains "$out" "colima start --ssh-agent" "fix suggestion shown"
    teardown_colima_env
}

test_start_colima_no_warn_when_forwarding_enabled() {
    # No warning when forwardAgent: true.
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    setup_colima_env true

    local out
    out="$(run_cage start 2>&1)" || true
    assert_not_contains "$out" "SSH agent forwarding enabled" "no warning when forwarding on"
    assert_not_contains "$out" "colima start --ssh-agent" "no fix suggestion"
    teardown_colima_env
}

# ================================================================
# Tests: seed_home (home directory seeding)
# ================================================================

test_start_seeds_home_when_seed_dir_exists() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "cp" 0 ""
    mock_docker_response "start" 0 ""
    mock_docker_response "exec" 0 ""
    mock_docker_response "attach" 0 ""

    mkdir -p "$HOME/.config/cage/home/.claude"
    echo '{}' > "$HOME/.config/cage/home/.claude/settings.json"

    local out; out="$(run_cage start 2>&1)"
    assert_contains "$out" "Seeding home directory" "seeding info message"
    assert_eq "1" "$(mock_call_count create)" "docker create called"
    assert_eq "1" "$(mock_call_count cp)" "docker cp called"
    assert_eq "1" "$(mock_call_count exec)" "docker exec called"
    assert_eq "1" "$(mock_call_count start)" "docker start called (detached)"
    assert_eq "1" "$(mock_call_count attach)" "docker attach called"

    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "/tmp/cage-seed" "seed temp dir used"
    assert_contains "$calls" "cp -rn /tmp/cage-seed/. /home/vscode/" "cp -rn in exec"

    rm -rf "$HOME/.config/cage/home"
}

test_start_skips_seed_when_no_seed_dir() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    rm -rf "$HOME/.config/cage/home"

    local out; out="$(run_cage start 2>&1)"
    assert_not_contains "$out" "Seeding" "no seeding message"
    assert_eq "0" "$(mock_call_count cp)" "docker cp NOT called"
    assert_eq "0" "$(mock_call_count exec)" "docker exec NOT called"
    assert_eq "1" "$(mock_call_count create)" "docker create called"
    assert_eq "1" "$(mock_call_count start)" "docker start called"
}

test_start_skips_seed_when_seed_dir_empty() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    mkdir -p "$HOME/.config/cage/home"

    local out; out="$(run_cage start 2>&1)"
    assert_not_contains "$out" "Seeding" "no seeding message for empty dir"
    assert_eq "0" "$(mock_call_count cp)" "docker cp NOT called"
    assert_eq "0" "$(mock_call_count exec)" "docker exec NOT called"

    rm -rf "$HOME/.config/cage/home"
}

test_reattach_does_not_seed() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "image" 1 ""
    mock_docker_response "attach" 0 ""

    mkdir -p "$HOME/.config/cage/home/.claude"
    echo '{}' > "$HOME/.config/cage/home/.claude/settings.json"

    run_cage start >/dev/null 2>&1 || true
    assert_eq "0" "$(mock_call_count cp)" "docker cp NOT called on reattach"
    assert_eq "1" "$(mock_call_count attach)" "docker attach called"

    rm -rf "$HOME/.config/cage/home"
}

test_restart_stopped_does_not_seed() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "false"
    mock_docker_response "image" 1 ""
    mock_docker_response "start" 0 ""

    mkdir -p "$HOME/.config/cage/home/.claude"
    echo '{}' > "$HOME/.config/cage/home/.claude/settings.json"

    run_cage start >/dev/null 2>&1 || true
    assert_eq "0" "$(mock_call_count cp)" "docker cp NOT called on restart"

    rm -rf "$HOME/.config/cage/home"
}

# ================================================================
# Tests: env file support
# ================================================================

test_start_global_env_file() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    mkdir -p "$HOME/.config/cage"
    echo "FOO=bar" > "$HOME/.config/cage/env"

    run_cage start >/dev/null 2>&1 || true
    assert_contains "$(mock_calls)" "--env-file $HOME/.config/cage/env" "global env file in docker create"

    rm -f "$HOME/.config/cage/env"
}

test_start_project_env_file() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    local project_dir; project_dir="$(mktemp -d)"
    echo "BAZ=qux" > "$project_dir/.cage.env"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    assert_contains "$(mock_calls)" "--env-file $project_dir/.cage.env" "project env file in docker create"

    rm -rf "$project_dir"
}

test_start_both_env_files() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    mkdir -p "$HOME/.config/cage"
    echo "GLOBAL=yes" > "$HOME/.config/cage/env"
    local project_dir; project_dir="$(mktemp -d)"
    echo "LOCAL=yes" > "$project_dir/.cage.env"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "--env-file $HOME/.config/cage/env" "global env file present"
    assert_contains "$calls" "--env-file $project_dir/.cage.env" "project env file present"

    rm -f "$HOME/.config/cage/env"
    rm -rf "$project_dir"
}

test_start_no_env_files() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    rm -f "$HOME/.config/cage/env"
    local project_dir; project_dir="$(mktemp -d)"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    assert_not_contains "$(mock_calls)" "--env-file" "no env-file flags when files absent"

    rm -rf "$project_dir"
}

test_start_new_container_prints_enter_and_exit_banners() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    local expected_name; expected_name="$(expected_container_name)"
    local out; out="$(run_cage start 2>&1)"
    assert_contains "$out" "ENTERING CAGE" "enter banner shown"
    assert_contains "$out" "$expected_name" "enter banner contains container name"
    assert_contains "$out" "EXITED CAGE" "exit banner shown"
}

test_start_reattach_prints_enter_and_exit_banners() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "image" 1 ""
    mock_docker_response "attach" 0 ""
    local out; out="$(run_cage start 2>&1)"
    assert_contains "$out" "ENTERING CAGE" "enter banner shown on reattach"
    assert_contains "$out" "EXITED CAGE" "exit banner shown on reattach"
}

test_start_restart_stopped_prints_enter_and_exit_banners() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "false"
    mock_docker_response "image" 1 ""
    mock_docker_response "start" 0 ""
    local out; out="$(run_cage start 2>&1)"
    assert_contains "$out" "ENTERING CAGE" "enter banner shown on restart-stopped"
    assert_contains "$out" "EXITED CAGE" "exit banner shown on restart-stopped"
}

test_shell_prints_enter_and_exit_banners() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "exec" 0 ""
    local expected_name; expected_name="$(expected_container_name)"
    local out; out="$(run_cage shell 2>&1)"
    assert_contains "$out" "ENTERING CAGE" "enter banner shown for shell"
    assert_contains "$out" "$expected_name" "enter banner contains container name"
    assert_contains "$out" "EXITED CAGE" "exit banner shown for shell"
}

test_start_passes_host_uid_gid() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage start >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    local uid gid
    uid="$(id -u)"
    gid="$(id -g)"
    assert_contains "$calls" "-e HOST_UID=${uid}" "HOST_UID env var in docker create"
    assert_contains "$calls" "-e HOST_GID=${gid}" "HOST_GID env var in docker create"
}

test_reattach_does_not_pass_host_uid_gid() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "image" 1 ""
    mock_docker_response "attach" 0 ""
    run_cage start >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_not_contains "$calls" "HOST_UID" "no HOST_UID on reattach"
    assert_not_contains "$calls" "HOST_GID" "no HOST_GID on reattach"
}

test_reattach_does_not_use_env_files() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "image" 1 ""
    mock_docker_response "attach" 0 ""

    mkdir -p "$HOME/.config/cage"
    echo "FOO=bar" > "$HOME/.config/cage/env"
    local project_dir; project_dir="$(mktemp -d)"
    echo "BAZ=qux" > "$project_dir/.cage.env"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    assert_not_contains "$(mock_calls)" "--env-file" "no env-file on reattach"

    rm -f "$HOME/.config/cage/env"
    rm -rf "$project_dir"
}

# ================================================================
# Tests: cmd_dstart (Linux trusted mode)
# ================================================================

# dstart behavior is platform-dependent; these helpers pin the platform.
mock_uname() {
    printf '#!/usr/bin/env bash\necho "%s"\n' "$1" > "$MOCK_DIR/uname"
    chmod +x "$MOCK_DIR/uname"
}
unmock_uname() { rm -f "$MOCK_DIR/uname"; }

# docker_socket_gid runs `stat -c %g <socket>`; the real socket doesn't
# exist in tests, so mock stat to return a fixed gid.
mock_stat_gid() {
    printf '#!/usr/bin/env bash\necho "%s"\n' "$1" > "$MOCK_DIR/stat"
    chmod +x "$MOCK_DIR/stat"
}
unmock_stat() { rm -f "$MOCK_DIR/stat"; }

test_dstart_linux_mounts_socket_and_labels() {
    mock_reset
    mock_uname Linux
    mock_stat_gid 999
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage dstart >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v /var/run/docker.sock:/var/run/docker.sock" "socket mounted"
    assert_contains "$calls" "cage.docker=host" "mode label set"
    assert_contains "$calls" "--group-add 999" "socket gid group added"
    unmock_stat
    unmock_uname
}

test_dstart_linux_prints_warning_banner() {
    mock_reset
    mock_uname Linux
    mock_stat_gid 999
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    local out; out="$(run_cage dstart 2>&1)"
    assert_contains "$out" "DOCKER-ENABLED CAGE" "warning banner shown"
    assert_contains "$out" "root-equivalent" "banner explains exposure"
    unmock_stat
    unmock_uname
}

test_dstart_passes_port_and_volume_flags() {
    mock_reset
    mock_uname Linux
    mock_stat_gid 999
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage dstart -p 3000:3000 -v /data:/data >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 3000:3000" "port flag forwarded"
    assert_contains "$calls" "-v /data:/data" "volume flag forwarded"
    unmock_stat
    unmock_uname
}

test_dstart_no_group_add_when_gid_unknown() {
    mock_reset
    mock_uname Linux
    # No stat mock on Linux CI would find the real socket; force failure.
    printf '#!/usr/bin/env bash\nexit 1\n' > "$MOCK_DIR/stat"
    chmod +x "$MOCK_DIR/stat"
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage dstart >/dev/null 2>&1 || true
    assert_not_contains "$(mock_calls)" "--group-add" "no group-add when gid unknown"
    assert_contains "$(mock_calls)" "cage.docker=host" "container still created"
    unmock_stat
    unmock_uname
}

test_start_does_not_mount_docker_socket() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage start >/dev/null 2>&1 || true
    local calls; calls="$(mock_calls)"
    assert_not_contains "$calls" "/var/run/docker.sock" "plain start never mounts docker socket"
    assert_not_contains "$calls" "cage.docker" "plain start never sets docker label"
}

test_dstart_existing_nondocker_reattaches_with_info() {
    mock_reset
    mock_uname Linux
    mock_docker_response "info" 0 ""
    # cmd_dstart: state check → running
    mock_docker_response_n "inspect" 1 0 "true"
    # cmd_dstart: label check → empty (no cage.docker label)
    mock_docker_response_n "inspect" 2 0 ""
    # cmd_enter: state check → running
    mock_docker_response_n "inspect" 3 0 "true"
    # cmd_enter: inspect 4 = cage.image label (unmocked → empty), then
    # image_newer_available container image id
    mock_docker_response_n "inspect" 5 0 "sha256:same"
    mock_docker_response "image" 0 "sha256:same"
    mock_docker_response "attach" 0 ""
    local out; out="$(run_cage dstart 2>&1)"
    assert_contains "$out" "already exists without docker" "info message shown"
    assert_eq "1" "$(mock_call_count attach)" "re-attaches to existing container"
    assert_eq "0" "$(mock_call_count create)" "does not create a second container"
    unmock_uname
}

# ================================================================
# Tests: cmd_dstart (macOS contained mode)
# ================================================================

# Build a restricted PATH dir containing the mock docker + core tools,
# optionally without colima, to simulate its absence (the dev machine or
# CI may have a real colima on PATH).
make_restricted_bin() {
    local bin_dir="$MOCK_DIR/restricted-bin"
    rm -rf "$bin_dir"
    mkdir -p "$bin_dir"
    cp "$MOCK_DIR/docker" "$bin_dir/docker"
    # The mock resolves calls/responses relative to its own directory —
    # symlink them back to the shared ones so mock_docker_response and
    # mock_call_count keep working for the copied binary.
    ln -sf "$MOCK_RESPONSES_DIR" "$bin_dir/responses"
    ln -sf "$MOCK_CALLS_FILE" "$bin_dir/calls"
    printf '#!/usr/bin/env bash\necho Darwin\n' > "$bin_dir/uname"
    chmod +x "$bin_dir/uname" "$bin_dir/docker"
    local cmd cmd_path
    for cmd in bash printf basename shasum cut grep head tail cat sed xargs id tr stat mktemp ls cp rm mkdir dirname; do
        cmd_path="$(command -v "$cmd" 2>/dev/null)" || true
        [ -n "$cmd_path" ] && ln -sf "$cmd_path" "$bin_dir/$cmd"
    done
    echo "$bin_dir"
}

test_dstart_macos_requires_colima() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local bin_dir; bin_dir="$(make_restricted_bin)"
    local out rc=0
    out="$(PATH="$bin_dir" run_cage dstart 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "brew install colima" "install hint"
    assert_contains "$out" "github.com/pacificsky/cage" "issues link for other runtimes"
    rm -rf "$bin_dir"
}

test_dstart_macos_requires_docker_cli() {
    mock_reset
    local bin_dir; bin_dir="$(make_restricted_bin)"
    # podman present, docker absent → cage falls back to podman.
    mv "$bin_dir/docker" "$bin_dir/podman"
    # colima present.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/colima"
    chmod +x "$bin_dir/colima"
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local out rc=0
    out="$(PATH="$bin_dir" run_cage dstart 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "docker CLI" "explains docker CLI requirement"
    rm -rf "$bin_dir"
}

test_dstart_macos_project_outside_src_root() {
    mock_reset
    mock_uname Darwin
    # colima present (simple mock; richer mock arrives in Task 5).
    printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_DIR/colima"
    chmod +x "$MOCK_DIR/colima"
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    # Src root exists, but the project dir lives outside it.
    mkdir -p "$HOME/src"
    local pdir; pdir="$(mktemp -d)"
    local out rc=0
    out="$( (cd "$pdir" && DOCKER_HOST='' bash "$CAGE_SH" dstart 2>&1) )" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "outside CAGE_SRC_ROOT" "names the actual problem"
    assert_not_contains "$out" "colima delete" "no delete hint when profile absent"
    rm -rf "$pdir" "$MOCK_DIR/colima"
    [ "$HOME" = "$FAKE_HOME" ] && rm -rf "$HOME/src"
    unmock_uname
}

test_dstart_macos_requires_src_root_to_exist() {
    mock_reset
    mock_uname Darwin
    printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_DIR/colima"
    chmod +x "$MOCK_DIR/colima"
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    # Point CAGE_SRC_ROOT at a path that never exists, so the test does
    # not depend on whether $HOME/src happens to be present.
    local absent="$MOCK_DIR/no-such-src"
    local pdir; pdir="$(mktemp -d)"
    local out rc=0
    out="$( (cd "$pdir" && DOCKER_HOST='' CAGE_SRC_ROOT="$absent" bash "$CAGE_SH" dstart 2>&1) )" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "does not exist" "explains the missing directory"
    assert_contains "$out" "mkdir -p" "suggests creating it"
    assert_contains "$out" "CAGE_SRC_ROOT" "mentions the knob"
    assert_not_contains "$out" "outside CAGE_SRC_ROOT" "missing-root error, not the outside-root one"
    rm -rf "$pdir" "$MOCK_DIR/colima"
    unmock_uname
}

test_dstart_macos_src_root_change_hint() {
    mock_reset
    mock_uname Darwin
    printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_DIR/colima"
    chmod +x "$MOCK_DIR/colima"
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    # Profile dir exists → error must include the delete hint.
    mkdir -p "$HOME/.colima/cage"
    mkdir -p "$HOME/src"    # src root exists; project outside it
    local pdir; pdir="$(mktemp -d)"
    local out rc=0
    out="$( (cd "$pdir" && DOCKER_HOST='' bash "$CAGE_SH" dstart 2>&1) )" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "colima delete --profile cage" "delete hint when profile exists"
    rm -rf "$pdir" "$MOCK_DIR/colima"
    [ "$HOME" = "$FAKE_HOME" ] && rm -rf "$HOME/.colima" "$HOME/src"
    unmock_uname
}

# Shared setup for macOS contained-mode happy-path tests: Darwin uname,
# colima mock, a project under the fake $HOME/src, standard docker mocks.
# Sets globals: DPDIR (project dir).
setup_dstart_macos() {
    mock_reset
    mock_uname Darwin
    setup_colima_mock
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    DPDIR="$HOME/src/myproj"
    mkdir -p "$DPDIR"
}

teardown_dstart_macos() {
    teardown_colima_mock
    unmock_uname
    [ "$HOME" = "$FAKE_HOME" ] && rm -rf "$HOME/src"
}

run_dstart_macos() {
    (cd "$DPDIR" && DOCKER_HOST='' bash "$CAGE_SH" dstart 2>&1)
}

test_dstart_macos_provisions_vm_first_run() {
    setup_dstart_macos
    mock_colima_response "status" 1 ""        # VM not running
    mock_colima_response "ssh" 0 "998"        # socket gid inside the VM
    local out; out="$(run_dstart_macos)" || true
    assert_contains "$(colima_calls)" "start --profile cage --mount $HOME/src:w --ssh-agent --cpu 4 --memory 8 --disk 60" "provision command"
    assert_contains "$(colima_calls)" "--activate=false" "does not hijack the user's docker context"
    assert_contains "$out" "cage VM" "explains the one-time provision"
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "cage.docker=colima" "colima mode label"
    assert_contains "$calls" "-v /var/run/docker.sock:/var/run/docker.sock" "VM socket mounted"
    assert_contains "$calls" "--group-add 998" "gid discovered via colima ssh"
    teardown_dstart_macos
}

test_dstart_macos_skips_provision_when_vm_running() {
    setup_dstart_macos
    mock_colima_response "status" 0 "running"
    mock_colima_response "ssh" 0 "998"
    run_dstart_macos >/dev/null || true
    assert_not_contains "$(colima_calls)" "start --profile" "no provision when VM runs"
    assert_contains "$(mock_calls)" "cage.docker=colima" "container still created in VM"
    teardown_dstart_macos
}

test_dstart_macos_vm_size_configurable() {
    setup_dstart_macos
    mock_colima_response "status" 1 ""
    mock_colima_response "ssh" 0 "998"
    mkdir -p "$HOME/.config/cage"
    printf 'CAGE_VM_CPU=8\nCAGE_VM_MEMORY=16\nCAGE_VM_DISK=100\n' > "$HOME/.config/cage/env"
    run_dstart_macos >/dev/null || true
    assert_contains "$(colima_calls)" "--cpu 8 --memory 16 --disk 100" "VM size from config file"
    rm -f "$HOME/.config/cage/env"
    teardown_dstart_macos
}

test_dstart_macos_targets_cage_vm_daemon() {
    setup_dstart_macos
    mock_colima_response "status" 0 "running"
    mock_colima_response "ssh" 0 "998"
    run_dstart_macos >/dev/null || true
    assert_contains "$(mock_env_calls)" "unix://$HOME/.colima/cage/docker.sock create" "create ran against the cage VM daemon"
    teardown_dstart_macos
}

test_dstart_macos_colima_start_failure_hint() {
    setup_dstart_macos
    mock_colima_response "status" 1 ""
    mock_colima_response "start" 1 "some colima error"
    local out rc=0
    out="$(run_dstart_macos)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "colima delete --profile cage" "corrupt-profile hint"
    teardown_dstart_macos
}

test_dstart_macos_conflicts_with_default_daemon_container() {
    setup_dstart_macos
    mock_colima_response "status" 0 "running"
    # Default daemon already has a NON-docker container for this project.
    mock_docker_response_n "inspect" 1 0 "true"   # state in default daemon
    mock_docker_response_n "inspect" 2 0 ""       # label empty
    local out rc=0
    out="$(run_dstart_macos)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "cage rm" "tells user to remove the old cage first"
    teardown_dstart_macos
}

test_start_reattaches_docker_enabled_silently() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "image" 1 ""
    mock_docker_response "attach" 0 ""
    local out; out="$(run_cage start 2>&1)"
    assert_not_contains "$out" "DOCKER-ENABLED" "no warning banner on plain start"
    assert_not_contains "$out" "without docker" "no docker info message on plain start"
    assert_eq "1" "$(mock_call_count attach)" "re-attaches"
}

# ================================================================
# Tests: cross-daemon routing (macOS cage VM)
# ================================================================

# Create a real unix socket at the cage VM socket path (under FAKE_HOME).
make_cage_vm_socket() {
    mkdir -p "$HOME/.colima/cage"
    python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
" "$HOME/.colima/cage/docker.sock"
}

remove_cage_vm_socket() {
    [ "$HOME" = "$FAKE_HOME" ] && rm -rf "$HOME/.colima"
    return 0
}

test_stop_routes_to_cage_vm() {
    mock_reset
    mock_uname Darwin
    make_cage_vm_socket
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 1 ""        # not in default daemon
    mock_docker_response_n "inspect" 2 0 "exists"  # routing probe finds it in VM
    mock_docker_response_n "inspect" 3 0 "true"    # state after routing: running
    mock_docker_response "stop" 0 ""
    local out; out="$(DOCKER_HOST='' run_cage stop 2>&1)"
    assert_contains "$out" "Stopping" "container stopped"
    assert_contains "$(mock_env_calls)" "unix://$HOME/.colima/cage/docker.sock stop" "stop ran against cage VM daemon"
    remove_cage_vm_socket
    unmock_uname
}

test_status_routes_to_cage_vm() {
    mock_reset
    mock_uname Darwin
    make_cage_vm_socket
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 1 ""
    mock_docker_response_n "inspect" 2 0 "exists"
    mock_docker_response_n "inspect" 3 0 "true"    # state
    mock_docker_response_n "inspect" 4 0 "colima"  # cage.docker label
    mock_docker_response "port" 0 ""
    local out; out="$(DOCKER_HOST='' run_cage status)"
    assert_contains "$out" "State:     running" "found the VM container"
    assert_contains "$out" "Docker:    colima" "docker mode from VM container"
    remove_cage_vm_socket
    unmock_uname
}

test_no_routing_without_cage_vm_socket() {
    mock_reset
    mock_uname Darwin
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local out rc=0
    out="$(DOCKER_HOST='' run_cage stop 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "No container" "plain not-found error"
    unmock_uname
}

test_no_routing_on_linux() {
    mock_reset
    mock_uname Linux
    make_cage_vm_socket
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local out rc=0
    out="$(DOCKER_HOST='' run_cage stop 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_eq "1" "$(mock_call_count inspect)" "no routing probe on Linux"
    remove_cage_vm_socket
    unmock_uname
}

test_start_reattaches_via_routing() {
    mock_reset
    mock_uname Darwin
    make_cage_vm_socket
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 1 ""        # not in default daemon
    mock_docker_response_n "inspect" 2 0 "exists"  # probe
    mock_docker_response_n "inspect" 3 0 "true"    # state: running
    # inspect 4 (cage.image label): unmocked → empty
    mock_docker_response_n "inspect" 5 0 "sha256:same"  # image_newer_available
    mock_docker_response "image" 0 "sha256:same"
    mock_docker_response "attach" 0 ""
    DOCKER_HOST='' run_cage start >/dev/null 2>&1 || true
    assert_eq "0" "$(mock_call_count create)" "no new container created"
    assert_contains "$(mock_env_calls)" "unix://$HOME/.colima/cage/docker.sock attach" "attached to VM container"
    remove_cage_vm_socket
    unmock_uname
}

test_upgrade_routes_before_pull() {
    mock_reset
    mock_uname Darwin
    make_cage_vm_socket
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 1 ""             # not in default daemon
    mock_docker_response_n "inspect" 2 0 "exists"       # probe finds it in VM
    mock_docker_response_n "inspect" 3 0 "true"         # state (routed)
    # inspect 4 (cage.image label): unmocked → empty
    mock_docker_response "pull" 0 ""
    mock_docker_response_n "inspect" 5 0 "sha256:same"  # container image id
    mock_docker_response "image" 0 "sha256:same"        # already latest
    local out; out="$(DOCKER_HOST='' run_cage upgrade 2>&1)"
    assert_contains "$out" "already on the latest" "no recreation needed"
    assert_contains "$(mock_env_calls)" "unix://$HOME/.colima/cage/docker.sock pull" "pull ran against cage VM daemon"
    remove_cage_vm_socket
    unmock_uname
}

# ================================================================
# Tests: mount file support
# ================================================================

# Shared setup for the mount-file tests: fresh mocks for a container that
# does not exist yet, plus an empty project dir.  Echoes the project dir.
setup_mount_test() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    rm -f "$HOME/.config/cage/mounts"
    mkdir -p "$HOME/.config/cage"
    mktemp -d
}

test_start_global_mounts_file() {
    local project_dir; project_dir="$(setup_mount_test)"
    echo "/data:/data" > "$HOME/.config/cage/mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    assert_contains "$(mock_calls)" "-v /data:/data" "global mount in docker create"

    rm -f "$HOME/.config/cage/mounts"
    rm -rf "$project_dir"
}

test_start_project_mounts_file() {
    local project_dir; project_dir="$(setup_mount_test)"
    echo "/models:/models:ro" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    assert_contains "$(mock_calls)" "-v /models:/models:ro" "project mount in docker create"

    rm -rf "$project_dir"
}

test_start_both_mounts_files() {
    local project_dir; project_dir="$(setup_mount_test)"
    echo "/data:/data" > "$HOME/.config/cage/mounts"
    echo "/models:/models" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v /data:/data" "global mount present"
    assert_contains "$calls" "-v /models:/models" "project mount present"

    rm -f "$HOME/.config/cage/mounts"
    rm -rf "$project_dir"
}

test_start_no_mounts_files() {
    local project_dir; project_dir="$(setup_mount_test)"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    # Only cage's own two mounts (project dir and shared home) should appear.
    assert_eq "2" "$(grep -o -- '-v ' <<<"$calls" | wc -l | tr -d ' ')" \
        "no extra -v flags when mount files absent"

    rm -rf "$project_dir"
}

test_start_mounts_file_ignores_comments_and_blanks() {
    local project_dir; project_dir="$(setup_mount_test)"
    printf '# a comment\n\n  \n  /data:/data  \n' > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v /data:/data" "spec is read despite surrounding noise"
    assert_not_contains "$calls" "a comment" "comment not passed to docker"
    assert_eq "3" "$(grep -o -- '-v ' <<<"$calls" | wc -l | tr -d ' ')" \
        "blank lines produce no mounts"

    rm -rf "$project_dir"
}

test_start_mounts_file_expands_tilde() {
    local project_dir; project_dir="$(setup_mount_test)"
    echo "~/notes:/notes" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    assert_contains "$(mock_calls)" "-v ${HOME}/notes:/notes" "leading ~/ expanded to \$HOME"

    rm -rf "$project_dir"
}

test_start_mounts_file_same_path_shorthand() {
    local project_dir; project_dir="$(setup_mount_test)"
    printf '/srv/data\n~/notes\n' > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v /srv/data:/srv/data" "colon-less line mounted at same path"
    assert_contains "$calls" "-v ${HOME}/notes:${HOME}/notes" "shorthand expands ~ on both sides"

    rm -rf "$project_dir"
}

test_start_mounts_file_same_path_with_options() {
    local project_dir; project_dir="$(setup_mount_test)"
    printf '/srv/data::ro\n~/notes::ro,z\n' > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v /srv/data:/srv/data:ro" "'path::ro' means same path, read-only"
    assert_contains "$calls" "-v ${HOME}/notes:${HOME}/notes:ro,z" "options list preserved verbatim"

    rm -rf "$project_dir"
}

test_start_mounts_file_same_path_empty_options() {
    local project_dir; project_dir="$(setup_mount_test)"
    echo "/srv/data::" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    assert_contains "$(mock_calls)" "-v /srv/data:/srv/data " "trailing '::' with no options is plain same-path"

    rm -rf "$project_dir"
}

test_start_mounts_file_explicit_target_unaffected() {
    local project_dir; project_dir="$(setup_mount_test)"
    printf '/a:/b:ro\ncache-vol:/home/vscode/.cache\n' > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v /a:/b:ro" "explicit host:container:opts passed through"
    assert_contains "$calls" "-v cache-vol:/home/vscode/.cache" "named volume passed through"

    rm -rf "$project_dir"
}

test_start_mounts_file_same_path_target_participates_in_precedence() {
    local project_dir; project_dir="$(setup_mount_test)"
    echo "/data::ro" > "$HOME/.config/cage/mounts"
    echo "/project/data:/data" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    # The '::' form's target is /data, so the project entry must still win.
    assert_contains "$calls" "-v /project/data:/data" "project mount wins over '::' global"
    assert_not_contains "$calls" "/data:/data:ro" "global '::' mount dropped for shared target"

    rm -f "$HOME/.config/cage/mounts"
    rm -rf "$project_dir"
}

test_start_mounts_file_rejects_relative_container_path() {
    local project_dir; project_dir="$(setup_mount_test)"
    echo "/srv/notes:ro" > "$project_dir/.cage.mounts"

    local out rc=0
    out="$(cd "$project_dir" && run_cage start 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exits non-zero on a relative container path"
    assert_contains "$out" "container path 'ro' is not absolute" "names the offending path"
    assert_contains "$out" "host::options" "suggests the '::' spelling"
    assert_not_contains "$(mock_calls)" "create" "container is not created"

    rm -rf "$project_dir"
}

test_start_mounts_file_rejects_tilde_container_path() {
    local project_dir; project_dir="$(setup_mount_test)"
    echo "/srv/x:~/x:ro" > "$project_dir/.cage.mounts"

    local out rc=0
    out="$(cd "$project_dir" && run_cage start 2>&1)" || rc=$?
    assert_eq "1" "$rc" "exits non-zero on a container-side ~"
    assert_contains "$out" "container path '~/x' is not absolute" "names the unexpanded ~ path"

    rm -rf "$project_dir"
}

test_start_project_mounts_override_global() {
    local project_dir; project_dir="$(setup_mount_test)"
    echo "/global/data:/data" > "$HOME/.config/cage/mounts"
    echo "/project/data:/data" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v /project/data:/data" "project mount wins for shared target"
    assert_not_contains "$calls" "/global/data" "global mount dropped for shared target"

    rm -f "$HOME/.config/cage/mounts"
    rm -rf "$project_dir"
}

test_start_cli_volume_overrides_mounts_files() {
    local project_dir; project_dir="$(setup_mount_test)"
    echo "/global/data:/data" > "$HOME/.config/cage/mounts"
    echo "/project/data:/data" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start -v /cli/data:/data >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v /cli/data:/data" "command-line mount wins for shared target"
    assert_not_contains "$calls" "/project/data" "project mount dropped for shared target"
    assert_not_contains "$calls" "/global/data" "global mount dropped for shared target"

    rm -f "$HOME/.config/cage/mounts"
    rm -rf "$project_dir"
}

test_start_cli_volume_keeps_unrelated_file_mounts() {
    local project_dir; project_dir="$(setup_mount_test)"
    echo "/models:/models" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start -v /cli/data:/data >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v /cli/data:/data" "command-line mount present"
    assert_contains "$calls" "-v /models:/models" "unrelated file mount kept"

    rm -rf "$project_dir"
}

test_start_mounts_file_ro_option_target_matching() {
    local project_dir; project_dir="$(setup_mount_test)"
    echo "/global/data:/data:ro" > "$HOME/.config/cage/mounts"
    echo "/project/data:/data" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v /project/data:/data" "project mount wins"
    assert_not_contains "$calls" "/global/data" "target matched despite :ro option on global"

    rm -f "$HOME/.config/cage/mounts"
    rm -rf "$project_dir"
}

test_dstart_applies_mounts_file() {
    local project_dir; project_dir="$(setup_mount_test)"
    mock_uname Linux
    mock_stat_gid 999
    echo "/models:/models" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage dstart >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    # dstart delegates to cmd_enter, so mount files apply there too — this
    # pins that delegation, which is the only reason it works.
    assert_contains "$calls" "-v /models:/models" "mount file applied by dstart"
    assert_contains "$calls" "cage.docker=host" "still a docker-enabled cage"

    unmock_stat
    unmock_uname
    rm -rf "$project_dir"
}

test_dstart_cli_volume_overrides_mounts_file() {
    local project_dir; project_dir="$(setup_mount_test)"
    mock_uname Linux
    mock_stat_gid 999
    echo "/file/data:/data" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage dstart -v /cli/data:/data >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-v /cli/data:/data" "command-line mount wins under dstart"
    assert_not_contains "$calls" "/file/data" "file mount dropped for shared target"

    unmock_stat
    unmock_uname
    rm -rf "$project_dir"
}

test_reattach_does_not_use_mounts_files() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "image" 1 ""
    mock_docker_response "attach" 0 ""

    mkdir -p "$HOME/.config/cage"
    echo "/data:/data" > "$HOME/.config/cage/mounts"
    local project_dir; project_dir="$(mktemp -d)"
    echo "/models:/models" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    assert_not_contains "$(mock_calls)" "-v " "no mounts on reattach"

    rm -f "$HOME/.config/cage/mounts"
    rm -rf "$project_dir"
}

test_restart_reapplies_mounts_files() {
    mock_reset
    mock_docker_response "info" 0 ""
    # First inspect: container exists.  Second (from cmd_enter): gone after rm.
    mock_docker_response_n "inspect" 1 0 "true"
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "rm" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    local project_dir; project_dir="$(mktemp -d)"
    echo "/models:/models" > "$project_dir/.cage.mounts"

    (cd "$project_dir" && run_cage restart >/dev/null 2>&1 || true)
    assert_contains "$(mock_calls)" "-v /models:/models" "mount file reapplied on restart"

    rm -rf "$project_dir"
}

# ================================================================
# Tests: port file support
# ================================================================

# Shared setup for the port-file tests: fresh mocks for a container that
# does not exist yet, plus an empty project dir.  Echoes the project dir.
setup_ports_test() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    rm -f "$HOME/.config/cage/ports"
    mkdir -p "$HOME/.config/cage"
    mktemp -d
}

test_start_global_ports_file() {
    local project_dir; project_dir="$(setup_ports_test)"
    echo "8080:80" > "$HOME/.config/cage/ports"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    assert_contains "$(mock_calls)" "-p 8080:80" "global port in docker create"

    rm -f "$HOME/.config/cage/ports"
    rm -rf "$project_dir"
}

test_start_project_ports_file() {
    local project_dir; project_dir="$(setup_ports_test)"
    echo "3000:3000" > "$project_dir/.cage.ports"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    assert_contains "$(mock_calls)" "-p 3000:3000" "project port in docker create"

    rm -rf "$project_dir"
}

test_start_both_ports_files() {
    local project_dir; project_dir="$(setup_ports_test)"
    echo "8080:80" > "$HOME/.config/cage/ports"
    echo "3000:3000" > "$project_dir/.cage.ports"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 8080:80" "global port present"
    assert_contains "$calls" "-p 3000:3000" "project port present"

    rm -f "$HOME/.config/cage/ports"
    rm -rf "$project_dir"
}

test_start_project_ports_override_global() {
    local project_dir; project_dir="$(setup_ports_test)"
    echo "8080:80" > "$HOME/.config/cage/ports"
    echo "9090:80" > "$project_dir/.cage.ports"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 9090:80" "project spec wins for container port 80"
    assert_not_contains "$calls" "8080:80" "global spec for same container port skipped"

    rm -f "$HOME/.config/cage/ports"
    rm -rf "$project_dir"
}

test_start_cli_port_overrides_ports_files() {
    local project_dir; project_dir="$(setup_ports_test)"
    echo "8888:80" > "$project_dir/.cage.ports"

    (cd "$project_dir" && run_cage start -p 9999:80 >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 9999:80" "CLI spec wins for container port 80"
    assert_not_contains "$calls" "8888:80" "file spec for same container port skipped"

    rm -rf "$project_dir"
}

test_start_cli_port_keeps_unrelated_file_ports() {
    local project_dir; project_dir="$(setup_ports_test)"
    echo "8080:80" > "$project_dir/.cage.ports"

    (cd "$project_dir" && run_cage start -p 3000:3000 >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 3000:3000" "CLI port applied"
    assert_contains "$calls" "-p 8080:80" "file port for a different container port kept"

    rm -rf "$project_dir"
}

test_start_ports_file_udp_distinct_from_tcp() {
    local project_dir; project_dir="$(setup_ports_test)"
    echo "5353:53/udp" > "$project_dir/.cage.ports"

    (cd "$project_dir" && run_cage start -p 9953:53 >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 5353:53/udp" "udp mapping kept"
    assert_contains "$calls" "-p 9953:53" "tcp mapping to same port number kept"

    rm -rf "$project_dir"
}

test_start_ports_file_ignores_comments_and_blanks() {
    local project_dir; project_dir="$(setup_ports_test)"
    printf '# a comment\n\n  \n  3000:3000  \n' > "$project_dir/.cage.ports"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 3000:3000" "spec is read despite surrounding noise"
    assert_not_contains "$calls" "a comment" "comment not passed to docker"
    assert_eq "1" "$(grep -o -- '-p ' <<<"$calls" | wc -l | tr -d ' ')" \
        "blank lines produce no ports"

    rm -rf "$project_dir"
}

test_start_ports_file_not_recorded_in_label() {
    local project_dir; project_dir="$(setup_ports_test)"
    echo "8080:80" > "$project_dir/.cage.ports"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 8080:80" "file port applied"
    # File ports are re-read on every creation; only CLI -p flags belong
    # in the cage.ports label.
    assert_not_contains "$calls" "cage.ports=" "file port not frozen into the label"

    rm -rf "$project_dir"
}

test_reattach_does_not_use_ports_files() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "image" 1 ""
    mock_docker_response "attach" 0 ""

    mkdir -p "$HOME/.config/cage"
    echo "8080:80" > "$HOME/.config/cage/ports"
    local project_dir; project_dir="$(mktemp -d)"
    echo "3000:3000" > "$project_dir/.cage.ports"

    (cd "$project_dir" && run_cage start >/dev/null 2>&1 || true)
    assert_not_contains "$(mock_calls)" "-p " "no ports on reattach"

    rm -f "$HOME/.config/cage/ports"
    rm -rf "$project_dir"
}

test_restart_reapplies_ports_files() {
    mock_reset
    mock_docker_response "info" 0 ""
    # First inspect: container exists.  Catch-all: label reads empty, and
    # after rm the container is gone.
    mock_docker_response_n "inspect" 1 0 "true"
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "rm" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""

    local project_dir; project_dir="$(mktemp -d)"
    echo "18080:80" > "$project_dir/.cage.ports"

    (cd "$project_dir" && run_cage restart >/dev/null 2>&1 || true)
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 18080:80" "ports file reapplied on restart"
    assert_not_contains "$calls" "cage.ports=" "reapplied file port still not labeled"

    rm -rf "$project_dir"
}


# ================================================================
# Run all tests
# ================================================================

main() {
    echo "cage.sh test suite"
    echo "========================================="

    echo ""
    echo "--- container_name ---"
    run_test test_container_name_known_path
    run_test test_container_name_deterministic
    run_test test_container_name_different_paths_differ
    run_test test_container_name_uses_basename

    # All remaining tests use mock docker.
    setup_mock
    trap teardown_mock EXIT

    echo ""
    echo "--- CLI: help and version ---"
    run_test test_no_args_shows_help
    run_test test_help_command
    run_test test_help_h_flag
    run_test test_help_long_flag
    run_test test_version_V
    run_test test_version_long
    run_test test_version_command
    run_test test_help_mentions_dstart
    run_test test_unknown_command_fails

    echo ""
    echo "--- ensure_docker ---"
    run_test test_docker_not_running_error
    run_test test_podman_fallback

    echo ""
    echo "--- container_state (via status) ---"
    run_test test_status_shows_running
    run_test test_status_shows_stopped
    run_test test_status_shows_none
    run_test test_status_shows_container_name
    run_test test_status_no_ports_when_none
    run_test test_status_shows_docker_host
    run_test test_status_shows_docker_none
    run_test test_status_shows_recorded_config_when_stopped
    run_test test_status_no_docker_line_when_no_container

    echo ""
    echo "--- cmd_stop ---"
    run_test test_stop_running_container
    run_test test_stop_already_stopped
    run_test test_stop_no_container

    echo ""
    echo "--- cmd_rm ---"
    run_test test_rm_running_uses_force
    run_test test_rm_stopped_no_force
    run_test test_rm_no_container

    echo ""
    echo "--- cmd_enter (start) ---"
    run_test test_start_new_container_pulls_and_creates
    run_test test_start_reattach_running
    run_test test_start_restart_stopped
    run_test test_start_ignores_port_flags_when_running
    run_test test_start_ignores_port_flags_when_stopped
    run_test test_start_passes_port_to_docker_create
    run_test test_start_multiple_ports
    run_test test_start_volume_flag
    run_test test_start_mixed_port_and_volume
    run_test test_start_p_missing_arg
    run_test test_start_v_missing_arg
    run_test test_start_unknown_flag
    run_test test_start_no_pull_for_local_image
    run_test test_start_docker_create_mounts
    run_test test_start_container_hostname
    run_test test_start_cage_image_override

    echo ""
    echo "--- cmd_shell ---"
    run_test test_shell_running
    run_test test_shell_not_running
    run_test test_shell_no_container

    echo ""
    echo "--- cmd_list ---"
    run_test test_list_filters_by_label
    run_test test_list_shows_image_column_header
    run_test test_list_shows_image_tag_and_sha
    run_test test_list_shows_image_sha_only_when_no_tag
    run_test test_list_handles_registry_port_in_image
    run_test test_list_shows_date_when_available
    run_test test_list_handles_missing_image_date

    echo ""
    echo "--- cmd_obliterate (global) ---"
    run_test test_obliterate_removes_all_containers_and_volume
    run_test test_obliterate_no_containers_no_volume
    run_test test_obliterate_containers_but_no_volume

    echo ""
    echo "--- cmd_rmconfig ---"
    run_test test_rmconfig_stops_containers_and_removes_volume
    run_test test_rmconfig_no_containers_removes_volume
    run_test test_rmconfig_no_volume

    echo ""
    echo "--- list / obliterate / rmconfig sweep cage VM daemon ---"
    run_test test_list_includes_cage_vm_daemon
    run_test test_list_single_daemon_without_cage_vm
    run_test test_obliterate_covers_cage_vm
    run_test test_rmconfig_covers_cage_vm

    echo ""
    echo "--- cmd_restart ---"
    run_test test_restart_existing_container
    run_test test_restart_no_container
    run_test test_restart_preserves_docker_mode
    run_test test_restart_plain_container_stays_plain
    run_test test_start_records_flag_labels
    run_test test_start_without_flags_records_no_flag_labels
    run_test test_restart_restores_ports_and_volumes
    run_test test_restart_restored_volume_wins_over_mount_file
    run_test test_start_records_image_label
    run_test test_restart_recreates_from_recorded_image
    run_test test_restart_env_image_overrides_recorded
    run_test test_upgrade_targets_recorded_image
    run_test test_restart_hints_when_cage_vm_down
    run_test test_upgrade_preserves_docker_mode
    run_test test_dstart_warns_when_image_lacks_docker_cli
    run_test test_dstart_no_warning_when_docker_cli_present
    run_test test_start_never_runs_cli_check

    echo ""
    echo "--- cmd_update ---"
    run_test test_update_rejects_local_image
    run_test test_update_pulls_image

    echo ""
    echo "--- cmd_upgrade ---"
    run_test test_upgrade_rejects_local_image
    run_test test_upgrade_pulls_and_recreates_when_newer
    run_test test_upgrade_pulls_no_recreate_when_current
    run_test test_upgrade_no_existing_container

    echo ""
    echo "--- image upgrade hint ---"
    run_test test_start_running_hints_newer_image

    echo ""
    echo "--- SSH agent forwarding ---"
    run_test test_start_ssh_agent_linux
    run_test test_start_ssh_no_agent
    run_test test_start_ssh_macos_uses_vm_socket
    run_test test_start_colima_warns_no_ssh_agent
    run_test test_start_colima_no_warn_when_forwarding_enabled

    echo ""
    echo "--- seed_home (home directory seeding) ---"
    run_test test_start_seeds_home_when_seed_dir_exists
    run_test test_start_skips_seed_when_no_seed_dir
    run_test test_start_skips_seed_when_seed_dir_empty
    run_test test_reattach_does_not_seed
    run_test test_restart_stopped_does_not_seed

    echo ""
    echo "--- env file support ---"
    run_test test_start_global_env_file
    run_test test_start_project_env_file
    run_test test_start_both_env_files
    run_test test_start_no_env_files
    run_test test_start_new_container_prints_enter_and_exit_banners
    run_test test_start_reattach_prints_enter_and_exit_banners
    run_test test_start_restart_stopped_prints_enter_and_exit_banners
    run_test test_shell_prints_enter_and_exit_banners
    run_test test_start_passes_host_uid_gid
    run_test test_reattach_does_not_pass_host_uid_gid
    run_test test_reattach_does_not_use_env_files

    echo ""
    echo "--- cmd_dstart (Linux trusted mode) ---"
    run_test test_dstart_linux_mounts_socket_and_labels
    run_test test_dstart_linux_prints_warning_banner
    run_test test_dstart_passes_port_and_volume_flags
    run_test test_dstart_no_group_add_when_gid_unknown
    run_test test_start_does_not_mount_docker_socket
    run_test test_dstart_existing_nondocker_reattaches_with_info
    run_test test_start_reattaches_docker_enabled_silently

    echo ""
    echo "--- cmd_dstart (macOS contained mode) ---"
    run_test test_dstart_macos_requires_colima
    run_test test_dstart_macos_requires_docker_cli
    run_test test_dstart_macos_project_outside_src_root
    run_test test_dstart_macos_requires_src_root_to_exist
    run_test test_dstart_macos_src_root_change_hint
    run_test test_dstart_macos_provisions_vm_first_run
    run_test test_dstart_macos_skips_provision_when_vm_running
    run_test test_dstart_macos_vm_size_configurable
    run_test test_dstart_macos_targets_cage_vm_daemon
    run_test test_dstart_macos_colima_start_failure_hint
    run_test test_dstart_macos_conflicts_with_default_daemon_container

    echo ""
    echo "--- cross-daemon routing (macOS cage VM) ---"
    run_test test_stop_routes_to_cage_vm
    run_test test_status_routes_to_cage_vm
    run_test test_no_routing_without_cage_vm_socket
    run_test test_no_routing_on_linux
    run_test test_start_reattaches_via_routing
    run_test test_upgrade_routes_before_pull

    echo ""
    echo "--- mount file support ---"
    run_test test_start_global_mounts_file
    run_test test_start_project_mounts_file
    run_test test_start_both_mounts_files
    run_test test_start_no_mounts_files
    run_test test_start_mounts_file_ignores_comments_and_blanks
    run_test test_start_mounts_file_expands_tilde
    run_test test_start_mounts_file_same_path_shorthand
    run_test test_start_mounts_file_same_path_with_options
    run_test test_start_mounts_file_same_path_empty_options
    run_test test_start_mounts_file_explicit_target_unaffected
    run_test test_start_mounts_file_same_path_target_participates_in_precedence
    run_test test_start_mounts_file_rejects_relative_container_path
    run_test test_start_mounts_file_rejects_tilde_container_path
    run_test test_start_project_mounts_override_global
    run_test test_start_cli_volume_overrides_mounts_files
    run_test test_start_cli_volume_keeps_unrelated_file_mounts
    run_test test_start_mounts_file_ro_option_target_matching
    run_test test_dstart_applies_mounts_file
    run_test test_dstart_cli_volume_overrides_mounts_file
    run_test test_reattach_does_not_use_mounts_files
    run_test test_restart_reapplies_mounts_files

    echo ""
    echo "--- port file support ---"
    run_test test_start_global_ports_file
    run_test test_start_project_ports_file
    run_test test_start_both_ports_files
    run_test test_start_project_ports_override_global
    run_test test_start_cli_port_overrides_ports_files
    run_test test_start_cli_port_keeps_unrelated_file_ports
    run_test test_start_ports_file_udp_distinct_from_tcp
    run_test test_start_ports_file_ignores_comments_and_blanks
    run_test test_start_ports_file_not_recorded_in_label
    run_test test_reattach_does_not_use_ports_files
    run_test test_restart_reapplies_ports_files

    print_summary
}

main "$@"
