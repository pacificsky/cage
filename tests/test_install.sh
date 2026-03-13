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

    # Build a restricted PATH that excludes system curl.
    # Symlink only the external tools the install script needs.
    local safe_bin="$MOCK_DIR/safe_bin"
    mkdir -p "$safe_bin"
    local tool
    for tool in sed head mktemp mkdir chmod cp rm basename cat; do
        local tool_path
        tool_path="$(command -v "$tool" 2>/dev/null)" || true
        [ -n "$tool_path" ] && ln -sf "$tool_path" "$safe_bin/$tool"
    done

    export PATH="$MOCK_DIR/bin:$FAKE_INSTALL_DIR:$safe_bin"

    local output
    output="$(/bin/sh "$INSTALL_SH" 2>&1)"
    assert_contains "$output" "Installed cage 0.9.0" "should install via wget"
    teardown_mock
}

test_no_download_tool() {
    setup_mock
    rm "$MOCK_DIR/bin/curl"
    # Set PATH to only our mock bin dir (no curl, no wget).
    # Run with /bin/sh absolute path so sh is resolved.
    # The script dies at download() before needing any external tools -
    # command, printf, and exit are all shell builtins.
    export PATH="$MOCK_DIR/bin"

    local output rc=0
    output="$(/bin/sh "$INSTALL_SH" 2>&1)" || rc=$?
    assert_eq "1" "$rc" "should exit with error"
    assert_contains "$output" "curl or wget" "should mention both tools"
    teardown_mock
}

test_api_failure() {
    setup_mock
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
