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
    printf '%s\n%s' "$exit_code" "$output" > "$MOCK_RESPONSES_DIR/$subcmd"
}

# Set the response for the Nth invocation of a docker subcommand.
#   mock_docker_response_n <subcmd> <N> <exit_code> [stdout_text]
mock_docker_response_n() {
    local subcmd="$1" n="$2" exit_code="$3" output="${4:-}"
    printf '%s\n%s' "$exit_code" "$output" > "$MOCK_RESPONSES_DIR/${subcmd}_${n}"
}

# Return all recorded docker invocations (one per line).
mock_calls() { cat "$MOCK_CALLS_FILE"; }

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
    rm -f "$MOCK_RESPONSES_DIR"/*
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
    local out; out="$(run_cage -V)";      assert_contains "$out" "cage 0.1.0"
}
test_version_long() {
    local out; out="$(run_cage --version)"; assert_contains "$out" "cage 0.1.0"
}
test_version_command() {
    local out; out="$(run_cage version)"; assert_contains "$out" "cage 0.1.0"
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

test_start_new_container_pulls_and_runs() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "run" 0 ""
    local out; out="$(run_cage start 2>&1)"
    assert_contains "$out" "Pulling latest image" "pulls image"
    assert_contains "$out" "Creating" "creating message"
    assert_eq "1" "$(mock_call_count run)" "docker run called"
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
    assert_contains "$out" "ignoring -p flags" "port-ignored warning"
}

test_start_ignores_port_flags_when_stopped() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "false"
    mock_docker_response "image" 1 ""
    mock_docker_response "start" 0 ""
    local out; out="$(run_cage start -p 3000:3000 2>&1)"
    assert_contains "$out" "ignoring -p flags" "port-ignored warning"
}

test_start_passes_port_to_docker_run() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "run" 0 ""
    run_cage start -p 3000:3000 2>&1 >/dev/null || true
    assert_contains "$(mock_calls)" "-p 3000:3000" "port flag in docker run"
}

test_start_multiple_ports() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "run" 0 ""
    run_cage start -p 3000:3000 -p 8080:8080 2>&1 >/dev/null || true
    local calls; calls="$(mock_calls)"
    assert_contains "$calls" "-p 3000:3000" "first port"
    assert_contains "$calls" "-p 8080:8080" "second port"
}

test_start_volume_flag() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "run" 0 ""
    run_cage start -v /data:/data 2>&1 >/dev/null || true
    assert_contains "$(mock_calls)" "-v /data:/data" "volume flag in docker run"
}

test_start_mixed_port_and_volume() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "run" 0 ""
    run_cage start -p 3000:3000 -v /data:/data -p 8080:8080 2>&1 >/dev/null || true
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
    mock_docker_response "run" 0 ""
    local out
    out="$(CAGE_IMAGE="my-local-image" run_cage start 2>&1)"
    assert_not_contains "$out" "Pulling" "no pull for local image"
    assert_eq "0" "$(mock_call_count pull)" "docker pull not called"
}

test_start_docker_run_mounts() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "run" 0 ""
    run_cage start 2>&1 >/dev/null || true
    local calls; calls="$(mock_calls)"
    local pdir; pdir="$(pwd)"
    assert_contains "$calls" "-v ${pdir}:${pdir}" "project dir mounted"
    assert_contains "$calls" "--workdir ${pdir}" "workdir is project dir"
    assert_contains "$calls" "cage.project=${pdir}" "cage.project label"
    assert_contains "$calls" "/home/vscode/.ssh:ro" "ssh mount read-only"
    assert_contains "$calls" "/home/vscode/.gitconfig:ro" "gitconfig mount read-only"
}

test_start_container_hostname() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "run" 0 ""
    run_cage start 2>&1 >/dev/null || true
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
    mock_docker_response "run" 0 ""
    CAGE_IMAGE="custom/img:v2" run_cage start 2>&1 >/dev/null || true
    assert_contains "$(mock_calls)" "custom/img:v2" "custom image in docker run"
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
    mock_docker_response "ps" 0 "cage-app-12345678  Up 2 hours  /home/user/app"
    local out; out="$(run_cage list)"
    assert_contains "$out" "cage-app" "lists cage containers"
    assert_contains "$(mock_calls)" "label=cage.project" "filters by cage.project label"
}

# ================================================================
# Tests: cmd_obliterate
# ================================================================

test_obliterate_removes_container_and_volume() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 0 "true"
    mock_docker_response "rm" 0 ""
    mock_docker_response "volume" 0 ""
    local out; out="$(run_cage obliterate 2>&1)"
    assert_contains "$out" "Stopping and removing" "removes container"
    assert_contains "$out" "Removing volume" "removes volume"
}

test_obliterate_no_container_only_volume() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""      # no container
    mock_docker_response "volume" 0 ""        # volume exists
    local out; out="$(run_cage obliterate 2>&1)"
    assert_not_contains "$out" "Stopping" "no container removal"
    assert_contains "$out" "Removing volume" "still removes volume"
}

# ================================================================
# Tests: cmd_restart
# ================================================================

test_restart_existing_container() {
    mock_reset
    mock_docker_response "info" 0 ""
    # First inspect: container exists (running)
    mock_docker_response_n "inspect" 1 0 "true"
    # docker rm -f succeeds
    mock_docker_response "rm" 0 ""
    # Second inspect in cmd_enter: container gone → create new
    mock_docker_response_n "inspect" 2 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "run" 0 ""
    local out; out="$(run_cage restart 2>&1)"
    assert_contains "$(mock_calls)" "rm -f" "old container removed"
    assert_eq "1" "$(mock_call_count run)" "new container created"
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
    mock_docker_response "inspect" 1 ""   # no existing container
    local out; out="$(run_cage update 2>&1)"
    assert_contains "$out" "Pulling latest image" "pulls message"
    assert_eq "1" "$(mock_call_count pull)" "docker pull called"
}

test_update_no_existing_container() {
    mock_reset
    mock_docker_response "info" 0 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "inspect" 1 ""
    local out; out="$(run_cage update 2>&1)"
    assert_contains "$out" "No existing container" "info message"
    assert_eq "0" "$(mock_call_count run)" "no docker run"
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
    assert_contains "$out" "newer image is available" "upgrade hint shown"
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
    run_test test_unknown_command_fails

    echo ""
    echo "--- ensure_docker ---"
    run_test test_docker_not_running_error

    echo ""
    echo "--- container_state (via status) ---"
    run_test test_status_shows_running
    run_test test_status_shows_stopped
    run_test test_status_shows_none
    run_test test_status_shows_container_name
    run_test test_status_no_ports_when_none

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
    run_test test_start_new_container_pulls_and_runs
    run_test test_start_reattach_running
    run_test test_start_restart_stopped
    run_test test_start_ignores_port_flags_when_running
    run_test test_start_ignores_port_flags_when_stopped
    run_test test_start_passes_port_to_docker_run
    run_test test_start_multiple_ports
    run_test test_start_volume_flag
    run_test test_start_mixed_port_and_volume
    run_test test_start_p_missing_arg
    run_test test_start_v_missing_arg
    run_test test_start_unknown_flag
    run_test test_start_no_pull_for_local_image
    run_test test_start_docker_run_mounts
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

    echo ""
    echo "--- cmd_obliterate ---"
    run_test test_obliterate_removes_container_and_volume
    run_test test_obliterate_no_container_only_volume

    echo ""
    echo "--- cmd_restart ---"
    run_test test_restart_existing_container
    run_test test_restart_no_container

    echo ""
    echo "--- cmd_update ---"
    run_test test_update_rejects_local_image
    run_test test_update_pulls_image
    run_test test_update_no_existing_container

    echo ""
    echo "--- image upgrade hint ---"
    run_test test_start_running_hints_newer_image

    print_summary
}

main "$@"
