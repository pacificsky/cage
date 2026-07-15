# `cage dstart` (Docker-Enabled Cages) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `dstart` subcommand that creates a docker-enabled cage: the agent gets a docker socket so it can run `docker compose` for multi-service projects — the host socket on Linux (trusted), a dedicated mount-restricted colima VM on macOS (contained).

**Architecture:** Everything lives in the single `cage.sh` script (repo convention). Docker-enablement is a creation-time container property recorded in a `cage.docker=host|colima` label. On macOS, all docker commands for a docker-enabled project are retargeted at the colima `cage` profile's daemon by exporting `DOCKER_HOST`; a routing helper lets every other subcommand find containers living in that VM. Spec: `docs/superpowers/specs/2026-07-08-dstart-docker-enabled-cages-design.md`.

**Tech Stack:** Bash (3.2-compatible), Docker/Podman CLI, colima. Mock-based unit tests (`tests/test_cage.sh`), real-runtime integration tests (`tests/test_integration.sh`).

## Global Constraints

- Bash 3.2 compatible: no associative arrays, no `${var,,}`, use parallel arrays (existing convention in `cmd_list`).
- Single-script architecture: all implementation goes in `cage.sh`. No new source files.
- Unit tests must pass on BOTH macOS dev machines and Linux CI. Any test exercising platform-dependent behavior MUST mock `uname` (helpers provided in Task 1).
- Array expansion under `set -u` uses the existing pattern: `${arr[@]+"${arr[@]}"}`.
- Exact names (used across tasks — do not vary):
  - Subcommand: `dstart`
  - Label: `cage.docker` with values `host` or `colima`
  - Colima profile: `cage`; its socket: `$HOME/.colima/cage/docker.sock`
  - Globals in cage.sh: `COLIMA_PROFILE="cage"`, `COLIMA_CAGE_SOCK="$HOME/.colima/cage/docker.sock"`, `CAGE_DOCKER_MODE=""`
  - Config knobs: `CAGE_SRC_ROOT` (default `$HOME/src`), `CAGE_VM_CPU` (default `4`), `CAGE_VM_MEMORY` (default `8`)
  - Functions: `cage_config_get`, `docker_socket_path`, `docker_socket_gid`, `container_docker_mode`, `cage_banner_docker_warning`, `cmd_dstart`, `setup_colima_cage`, `route_to_container`, `preserve_docker_mode`, `check_docker_cli_in_image`, `list_daemon_containers`, `obliterate_daemon`, `rmconfig_daemon`
- Version bumps to `0.9.0` in Task 10 (three version tests update with it).
- Run unit tests with: `bash tests/test_cage.sh` (expect `Failed: 0`).

---

### Task 1: Linux trusted mode — `dstart` mounts the host socket

**Files:**
- Modify: `cage.sh` (globals after line 6; helpers after `drop_into_cage` ~line 48; `cmd_enter` create block ~line 195-215; new `cmd_dstart` before `cmd_stop`; `main()` case ~line 527)
- Test: `tests/test_cage.sh`

**Interfaces:**
- Consumes: existing `cmd_enter`, `container_name`, `container_state`, `die`, `info`.
- Produces (later tasks rely on these exact signatures):
  - `CAGE_DOCKER_MODE` global: `""` | `"host"` | `"colima"`; when non-empty, `cmd_enter`'s create adds the socket mount, label, and `--group-add`.
  - `docker_socket_path()` → prints host-side socket path for the current mode/runtime.
  - `docker_socket_gid()` → prints numeric gid owning the socket, or empty if unknown.
  - `container_docker_mode(name)` → prints `host`, `colima`, or empty (no label).
  - `cage_banner_docker_warning()` → prints red banner to stderr.
  - `cmd_dstart(project_dir, flags...)` → full dstart entry point (Linux branch complete; macOS branch is a `die` placeholder replaced in Task 4).
  - `cage_config_get(KEY)` → prints value from environment, else from `~/.config/cage/env`, else empty; expands leading `~`.
- Note for implementer: `check_docker_cli_in_image` is called from the create block but only defined as a no-op stub here; Task 9 gives it its real body.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_cage.sh` after the `test_reattach_does_not_use_env_files` function (~line 1418):

```bash
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
```

Register in `main()` of the test file, before `print_summary`:

```bash
    echo ""
    echo "--- cmd_dstart (Linux trusted mode) ---"
    run_test test_dstart_linux_mounts_socket_and_labels
    run_test test_dstart_linux_prints_warning_banner
    run_test test_dstart_passes_port_and_volume_flags
    run_test test_dstart_no_group_add_when_gid_unknown
    run_test test_start_does_not_mount_docker_socket
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_cage.sh 2>&1 | tail -20`
Expected: the five new tests FAIL (dstart is an unknown command); all pre-existing tests still pass.

- [ ] **Step 3: Implement**

In `cage.sh`, add globals after line 6 (`HOME_VOL="cage-home"`):

```bash
COLIMA_PROFILE="cage"
COLIMA_CAGE_SOCK="$HOME/.colima/cage/docker.sock"
CAGE_DOCKER_MODE=""   # "", "host", or "colima" — set by dstart / preserve_docker_mode
```

Add helpers after `drop_into_cage` (after line 48):

```bash
cage_banner_docker_warning() {
    local c="\033[1;31m" r="\033[0m"
    local line="═══════════════════════════════════════════════════════════════"
    printf '%b\n' "${c}${line}${r}" >&2
    printf '%b\n' "${c}  ⚠  DOCKER-ENABLED CAGE (trusted mode)${r}" >&2
    printf '%b\n' "${c}  ⚠  The agent holds the host docker socket — root-equivalent${r}" >&2
    printf '%b\n' "${c}  ⚠  access to this machine.${r}" >&2
    printf '%b\n' "${c}${line}${r}" >&2
}

# Read KEY from the environment, falling back to ~/.config/cage/env
# (docker env-file format).  Last occurrence wins, matching --env-file.
cage_config_get() {
    local key="$1"
    local val="${!key:-}"
    if [ -z "$val" ] && [ -f "$HOME/.config/cage/env" ]; then
        val="$(grep -E "^${key}=" "$HOME/.config/cage/env" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    fi
    val="${val/#\~/$HOME}"
    echo "$val"
}

# Host-side path of the daemon socket to mount into a docker-enabled cage.
docker_socket_path() {
    if [ "$CAGE_DOCKER_MODE" = "colima" ]; then
        # Resolved by the colima-cage daemon, so this path is inside the VM.
        echo "/var/run/docker.sock"
    elif [ "$DOCKER" = "podman" ]; then
        local rootless="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
        if [ -S "$rootless" ]; then echo "$rootless"; else echo "/run/podman/podman.sock"; fi
    else
        echo "/var/run/docker.sock"
    fi
}

# Numeric gid owning the daemon socket, so the non-root container user can
# be added to it with --group-add.  Empty output = unknown (skip group-add).
docker_socket_gid() {
    if [ "$CAGE_DOCKER_MODE" = "colima" ]; then
        colima ssh --profile "$COLIMA_PROFILE" -- stat -c %g /var/run/docker.sock 2>/dev/null | tr -d '[:space:]' || true
    else
        stat -c %g "$(docker_socket_path)" 2>/dev/null | tr -d '[:space:]' || true
    fi
}

# The cage.docker label of an existing container: "host", "colima", or "".
container_docker_mode() {
    local mode
    mode="$($DOCKER inspect -f '{{index .Config.Labels "cage.docker"}}' "$1" 2>/dev/null)" || mode=""
    [ "$mode" = "<no value>" ] && mode=""
    echo "$mode"
}

# Real body arrives in Task 9 (image docker-CLI presence warning).
check_docker_cli_in_image() { :; }
```

In `cmd_enter`, after the `env_file_args` block (after line 201) add:

```bash
            # Docker-enabled cage: mount the daemon socket and record the mode.
            local -a docker_args=()
            if [ -n "$CAGE_DOCKER_MODE" ]; then
                local sock gid
                sock="$(docker_socket_path)"
                docker_args=(
                    -v "${sock}:/var/run/docker.sock"
                    -l "cage.docker=${CAGE_DOCKER_MODE}"
                )
                gid="$(docker_socket_gid)"
                [ -n "$gid" ] && docker_args+=(--group-add "$gid")
                check_docker_cli_in_image
            fi
```

and add `${docker_args[@]+"${docker_args[@]}"}` to the `docker create` invocation, after the `env_file_args` line (line 210):

```bash
                ${env_file_args[@]+"${env_file_args[@]}"} \
                ${docker_args[@]+"${docker_args[@]}"} \
```

Add `cmd_dstart` before `cmd_stop` (~line 226):

```bash
cmd_dstart() {
    local project_dir="$1"
    shift

    local name
    name="$(container_name "$project_dir")"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        die "dstart on macOS lands in Task 4"   # placeholder, replaced in Task 4
    else
        CAGE_DOCKER_MODE="host"
        cage_banner_docker_warning
    fi

    ensure_docker

    if [ "$(container_state "$name")" != "none" ] && [ -z "$(container_docker_mode "$name")" ]; then
        info "Container already exists without docker — re-attaching. Use 'cage rm' then 'cage dstart' to enable docker."
    fi

    cmd_enter "$project_dir" "$@"
}
```

In `main()`, change the `start)` case (line 527) to `start|dstart)` and dispatch at the end:

```bash
        start|dstart)
            # Parse -p and -v flags after the subcommand
            local -a port_flags=() vol_flags=()
            while [ $# -gt 0 ]; do
                case "$1" in
                    -p)
                        [ $# -ge 2 ] || die "-p requires an argument"
                        port_flags+=(-p "$2")
                        shift 2
                        ;;
                    -v)
                        [ $# -ge 2 ] || die "-v requires an argument"
                        vol_flags+=(-v "$2")
                        shift 2
                        ;;
                    *)  die "Unknown flag for ${cmd}: $1" ;;
                esac
            done
            if [ "$cmd" = "dstart" ]; then
                cmd_dstart "$project_dir" ${port_flags[@]+"${port_flags[@]}"} ${vol_flags[@]+"${vol_flags[@]}"}
            else
                ensure_docker
                cmd_enter "$project_dir" ${port_flags[@]+"${port_flags[@]}"} ${vol_flags[@]+"${vol_flags[@]}"}
            fi
            ;;
```

(Note: the error message becomes `Unknown flag for ${cmd}: $1` — for `start` it still prints "Unknown flag for start", keeping the existing test green.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_cage.sh 2>&1 | tail -20`
Expected: all tests pass, `Failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add cage.sh tests/test_cage.sh
git commit -m "Add dstart subcommand: Linux trusted mode with host socket mount"
```

---

### Task 2: `dstart`/`start` interplay on an existing container

**Files:**
- Modify: `cage.sh` (no changes expected — this pins behavior already implemented in Task 1)
- Test: `tests/test_cage.sh`

**Interfaces:**
- Consumes: `cmd_dstart`, `container_docker_mode` from Task 1.
- Produces: pinned behavior — `dstart` on an existing non-docker container re-attaches with an info line; plain `start` on any container re-attaches without docker-related output.

- [ ] **Step 1: Write the failing tests**

Add after `test_start_does_not_mount_docker_socket`:

```bash
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
    # cmd_enter: image_newer_available container image id
    mock_docker_response_n "inspect" 4 0 "sha256:same"
    mock_docker_response "image" 0 "sha256:same"
    mock_docker_response "attach" 0 ""
    local out; out="$(run_cage dstart 2>&1)"
    assert_contains "$out" "already exists without docker" "info message shown"
    assert_eq "1" "$(mock_call_count attach)" "re-attaches to existing container"
    assert_eq "0" "$(mock_call_count create)" "does not create a second container"
    unmock_uname
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
```

Register in the test `main()` under the dstart section:

```bash
    run_test test_dstart_existing_nondocker_reattaches_with_info
    run_test test_start_reattaches_docker_enabled_silently
```

- [ ] **Step 2: Run tests**

Run: `bash tests/test_cage.sh 2>&1 | tail -20`
Expected: both new tests PASS immediately (behavior shipped in Task 1). If either fails, fix `cmd_dstart` — the info message text must contain "already exists without docker" and re-attach must go through `cmd_enter` without creating.

- [ ] **Step 3: Commit**

```bash
git add tests/test_cage.sh
git commit -m "Pin dstart/start re-attach interplay with tests"
```

---

### Task 3: `cage status` shows the docker mode

**Files:**
- Modify: `cage.sh:305-325` (`cmd_status`)
- Test: `tests/test_cage.sh`

**Interfaces:**
- Consumes: `container_docker_mode` (Task 1).
- Produces: `status` output line `Docker:    <host|colima|none>` for existing containers (alignment matches `Container: ` / `State:     `).

- [ ] **Step 1: Write the failing tests**

```bash
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

test_status_no_docker_line_when_no_container() {
    mock_reset
    mock_uname Linux
    mock_docker_response "info" 0 ""
    mock_docker_response "inspect" 1 ""
    local out; out="$(run_cage status)"
    assert_not_contains "$out" "Docker:" "no docker line when state=none"
    unmock_uname
}
```

Register:

```bash
    run_test test_status_shows_docker_host
    run_test test_status_shows_docker_none
    run_test test_status_no_docker_line_when_no_container
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_cage.sh 2>&1 | tail -20`
Expected: first two FAIL (no Docker line yet), third passes.

- [ ] **Step 3: Implement**

In `cmd_status`, inside the `if [ "$state" != "none" ]` block, before the ports lookup:

```bash
    if [ "$state" != "none" ]; then
        local dmode
        dmode="$(container_docker_mode "$name")"
        echo "Docker:    ${dmode:-none}"

        local ports
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_cage.sh 2>&1 | tail -20`
Expected: `Failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add cage.sh tests/test_cage.sh
git commit -m "Show docker mode in cage status"
```

---

### Task 4: macOS gates — require colima + docker CLI, enforce CAGE_SRC_ROOT

**Files:**
- Modify: `cage.sh` (`cmd_dstart` Darwin branch; new `setup_colima_cage` before `cmd_dstart`)
- Test: `tests/test_cage.sh`

**Interfaces:**
- Consumes: `cage_config_get`, `die`, `COLIMA_PROFILE` (Task 1).
- Produces: `setup_colima_cage(project_dir)` — validates colima presence, docker CLI, and src-root containment; Task 5 extends it with VM provisioning + `DOCKER_HOST` export. Error messages contain: `brew install colima`, `github.com/pacificsky/cage`, `CAGE_SRC_ROOT`, and (when the profile exists) `colima delete --profile cage`.

- [ ] **Step 1: Write the failing tests**

```bash
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
    # Project dir outside the default CAGE_SRC_ROOT ($HOME/src).
    local pdir; pdir="$(mktemp -d)"
    local out rc=0
    out="$( (cd "$pdir" && DOCKER_HOST= bash "$CAGE_SH" dstart 2>&1) )" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "CAGE_SRC_ROOT" "mentions the knob"
    assert_not_contains "$out" "colima delete" "no delete hint when profile absent"
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
    local pdir; pdir="$(mktemp -d)"
    local out rc=0
    out="$( (cd "$pdir" && DOCKER_HOST= bash "$CAGE_SH" dstart 2>&1) )" || rc=$?
    assert_eq "1" "$rc" "exit code"
    assert_contains "$out" "colima delete --profile cage" "delete hint when profile exists"
    rm -rf "$pdir" "$MOCK_DIR/colima" "$HOME/.colima"
    unmock_uname
}
```

Register:

```bash
    echo ""
    echo "--- cmd_dstart (macOS contained mode) ---"
    run_test test_dstart_macos_requires_colima
    run_test test_dstart_macos_requires_docker_cli
    run_test test_dstart_macos_project_outside_src_root
    run_test test_dstart_macos_src_root_change_hint
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_cage.sh 2>&1 | tail -20`
Expected: all four new tests FAIL (Darwin branch is the Task 1 placeholder `die`).

- [ ] **Step 3: Implement**

Add `setup_colima_cage` before `cmd_dstart` in `cage.sh`:

```bash
# macOS contained mode: validate prerequisites and (Task 5) target the
# dedicated colima 'cage' profile whose VM mounts only CAGE_SRC_ROOT.
setup_colima_cage() {
    local project_dir="$1"

    command -v colima &>/dev/null || die "dstart on macOS requires colima (brew install colima).
       Docker Desktop / OrbStack sockets would hand the agent your file-shared home directory,
       so cage only supports colima here.  Want another runtime supported?
       Open an issue: https://github.com/pacificsky/cage/issues"

    [ "$DOCKER" = "docker" ] || die "dstart on macOS requires the docker CLI (colima's docker runtime). Install it: brew install docker"

    local src_root
    src_root="$(cage_config_get CAGE_SRC_ROOT)"
    src_root="${src_root:-$HOME/src}"
    src_root="${src_root%/}"

    case "$project_dir/" in
        "$src_root"/*) ;;
        *)
            local hint=""
            if [ -d "$HOME/.colima/$COLIMA_PROFILE" ]; then
                hint=" Note: the cage VM keeps the mounts it was created with — after changing CAGE_SRC_ROOT, run 'colima delete --profile $COLIMA_PROFILE' and dstart again."
            fi
            die "project $project_dir is outside CAGE_SRC_ROOT ($src_root), so it can't be mounted into the cage VM. Set CAGE_SRC_ROOT in ~/.config/cage/env or move the project.$hint"
            ;;
    esac
}
```

Replace the Darwin placeholder in `cmd_dstart`:

```bash
    if [[ "$(uname -s)" == "Darwin" ]]; then
        setup_colima_cage "$project_dir"
        CAGE_DOCKER_MODE="colima"
    else
        CAGE_DOCKER_MODE="host"
        cage_banner_docker_warning
    fi
```

(After Task 4, macOS dstart inside `CAGE_SRC_ROOT` proceeds against the default daemon — that's incomplete, fixed by Task 5. The gate tests above only exercise `die` paths, so they pass.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_cage.sh 2>&1 | tail -20`
Expected: `Failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add cage.sh tests/test_cage.sh
git commit -m "Add macOS dstart gates: colima + docker CLI required, CAGE_SRC_ROOT guard"
```

---

### Task 5: macOS contained mode — provision and target the colima `cage` VM

**Files:**
- Modify: `cage.sh` (`setup_colima_cage` gains provisioning + `DOCKER_HOST` export; `cmd_dstart` gains the default-daemon conflict check)
- Test: `tests/test_cage.sh` (richer colima mock infrastructure + tests)

**Interfaces:**
- Consumes: Task 4's `setup_colima_cage`, Task 1's `CAGE_DOCKER_MODE` plumbing.
- Produces:
  - `setup_colima_cage` ends with `export DOCKER_HOST="unix://$COLIMA_CAGE_SOCK"`; all subsequent `$DOCKER` calls in the invocation hit the cage VM's daemon.
  - VM provisioning command (exact): `colima start --profile cage --mount <src_root>:w --ssh-agent --cpu <cpu> --memory <memory>` — run only when `colima status --profile cage` fails.
  - Test helpers other tasks may reuse: `setup_colima_mock`, `mock_colima_response <subcmd> <exit_code> [stdout]`, `colima_calls`.

- [ ] **Step 1: Add colima mock infrastructure to the test framework**

Add after `mock_reset` (~line 213 of `tests/test_cage.sh`):

```bash
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
```

- [ ] **Step 2: Write the failing tests**

```bash
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
    rm -rf "$HOME/src"
}

run_dstart_macos() {
    (cd "$DPDIR" && DOCKER_HOST= bash "$CAGE_SH" dstart 2>&1)
}

test_dstart_macos_provisions_vm_first_run() {
    setup_dstart_macos
    mock_colima_response "status" 1 ""        # VM not running
    mock_colima_response "ssh" 0 "998"        # socket gid inside the VM
    local out; out="$(run_dstart_macos)" || true
    assert_contains "$(colima_calls)" "start --profile cage --mount $HOME/src:w --ssh-agent --cpu 4 --memory 8" "provision command"
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
    printf 'CAGE_VM_CPU=8\nCAGE_VM_MEMORY=16\n' > "$HOME/.config/cage/env"
    run_dstart_macos >/dev/null || true
    assert_contains "$(colima_calls)" "--cpu 8 --memory 16" "VM size from config file"
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
```

Note: `mock_env_calls` (used above) is added in this task too — extend the mock docker script in `setup_mock`: after the line `echo "$*" >> "$CALLS_FILE"` add:

```bash
echo "${DOCKER_HOST:-<unset>} $*" >> "$MOCK_DIR/env_calls"
```

and add helper + reset support:

```bash
# Return recorded invocations prefixed with the DOCKER_HOST each saw.
mock_env_calls() { cat "$MOCK_DIR/env_calls" 2>/dev/null; }
```

and in `mock_reset` add: `: > "$MOCK_DIR/env_calls"` and in `setup_mock` (after `touch "$MOCK_CALLS_FILE"`): `touch "$MOCK_DIR/env_calls"`.

Register the tests:

```bash
    run_test test_dstart_macos_provisions_vm_first_run
    run_test test_dstart_macos_skips_provision_when_vm_running
    run_test test_dstart_macos_vm_size_configurable
    run_test test_dstart_macos_targets_cage_vm_daemon
    run_test test_dstart_macos_colima_start_failure_hint
    run_test test_dstart_macos_conflicts_with_default_daemon_container
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash tests/test_cage.sh 2>&1 | tail -25`
Expected: the six new tests FAIL; everything else passes.

- [ ] **Step 4: Implement**

Append to `setup_colima_cage` (after the `case` guard):

```bash
    if ! colima status --profile "$COLIMA_PROFILE" >/dev/null 2>&1; then
        local cpu memory
        cpu="$(cage_config_get CAGE_VM_CPU)"
        cpu="${cpu:-4}"
        memory="$(cage_config_get CAGE_VM_MEMORY)"
        memory="${memory:-8}"
        info "Starting the cage VM (first run provisions it — takes about a minute)..."
        colima start --profile "$COLIMA_PROFILE" \
            --mount "${src_root}:w" \
            --ssh-agent \
            --cpu "$cpu" \
            --memory "$memory" \
            || die "colima failed to start the cage VM. If the profile is corrupt, try: colima delete --profile $COLIMA_PROFILE"
    fi

    export DOCKER_HOST="unix://$COLIMA_CAGE_SOCK"
```

In `cmd_dstart`, add the conflict check at the top of the Darwin branch (before `setup_colima_cage`):

```bash
    if [[ "$(uname -s)" == "Darwin" ]]; then
        # A pre-existing non-docker cage lives in the default daemon; a
        # docker-enabled one would live in the cage VM.  Two containers for
        # one project is a footgun — refuse and let the user pick.
        if $DOCKER info >/dev/null 2>&1 \
            && [ "$(container_state "$name")" != "none" ] \
            && [ -z "$(container_docker_mode "$name")" ]; then
            die "this project already has a cage without docker in the default daemon. Run 'cage rm' first, then 'cage dstart'."
        fi
        setup_colima_cage "$project_dir"
        CAGE_DOCKER_MODE="colima"
    else
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test_cage.sh 2>&1 | tail -25`
Expected: `Failed: 0`.

- [ ] **Step 6: Commit**

```bash
git add cage.sh tests/test_cage.sh
git commit -m "macOS dstart: provision and target the restricted colima cage VM"
```

---

### Task 6: Cross-daemon routing — other subcommands find containers in the cage VM

**Files:**
- Modify: `cage.sh` (new `route_to_container` after `container_docker_mode`; call it in `cmd_enter`, `cmd_stop`, `cmd_rm`, `cmd_status`, `cmd_shell`)
- Test: `tests/test_cage.sh`

**Interfaces:**
- Consumes: `COLIMA_CAGE_SOCK`, `container_state`, `mock_env_calls` (Task 5).
- Produces: `route_to_container(name)` — on macOS, when the container isn't in the current daemon and the cage VM socket exists and has it, exports `DOCKER_HOST="unix://$COLIMA_CAGE_SOCK"` for the rest of the invocation. No-op on Linux, when `DOCKER_HOST` is already set, or when the container is found locally. Task 7 also calls it.

- [ ] **Step 1: Write the failing tests**

```bash
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

remove_cage_vm_socket() { rm -rf "$HOME/.colima"; }

test_stop_routes_to_cage_vm() {
    mock_reset
    mock_uname Darwin
    make_cage_vm_socket
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 1 ""        # not in default daemon
    mock_docker_response_n "inspect" 2 0 "exists"  # routing probe finds it in VM
    mock_docker_response_n "inspect" 3 0 "true"    # state after routing: running
    mock_docker_response "stop" 0 ""
    local out; out="$(DOCKER_HOST= run_cage stop 2>&1)"
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
    local out; out="$(DOCKER_HOST= run_cage status)"
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
    out="$(DOCKER_HOST= run_cage stop 2>&1)" || rc=$?
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
    out="$(DOCKER_HOST= run_cage stop 2>&1)" || rc=$?
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
    mock_docker_response_n "inspect" 4 0 "sha256:same"  # image_newer_available
    mock_docker_response "image" 0 "sha256:same"
    mock_docker_response "attach" 0 ""
    DOCKER_HOST= run_cage start >/dev/null 2>&1 || true
    assert_eq "0" "$(mock_call_count create)" "no new container created"
    assert_contains "$(mock_env_calls)" "unix://$HOME/.colima/cage/docker.sock attach" "attached to VM container"
    remove_cage_vm_socket
    unmock_uname
}
```

Register:

```bash
    echo ""
    echo "--- cross-daemon routing (macOS cage VM) ---"
    run_test test_stop_routes_to_cage_vm
    run_test test_status_routes_to_cage_vm
    run_test test_no_routing_without_cage_vm_socket
    run_test test_no_routing_on_linux
    run_test test_start_reattaches_via_routing
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_cage.sh 2>&1 | tail -25`
Expected: routing tests FAIL (`No container` errors / wrong daemon).

- [ ] **Step 3: Implement**

Add after `container_docker_mode` in `cage.sh`:

```bash
# On macOS a project's container may live in the cage colima VM rather than
# the default daemon.  If it isn't found locally, retarget this invocation.
route_to_container() {
    local name="$1"
    [[ "$(uname -s)" == "Darwin" ]] || return 0
    [ -n "${DOCKER_HOST:-}" ] && return 0          # already targeted
    [ "$(container_state "$name")" = "none" ] || return 0
    [ -S "$COLIMA_CAGE_SOCK" ] || return 0
    if DOCKER_HOST="unix://$COLIMA_CAGE_SOCK" $DOCKER inspect "$name" >/dev/null 2>&1; then
        export DOCKER_HOST="unix://$COLIMA_CAGE_SOCK"
    fi
    return 0
}
```

Insert `route_to_container "$name"` between the `name=` assignment and the `state=` assignment in each of: `cmd_enter` (line ~139-141), `cmd_stop`, `cmd_rm`, `cmd_status`, `cmd_shell`. Example for `cmd_stop`:

```bash
    local name
    name="$(container_name "$project_dir")"
    route_to_container "$name"
    local state
    state="$(container_state "$name")"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_cage.sh 2>&1 | tail -25`
Expected: `Failed: 0`. (Existing tests are unaffected: on real-Darwin runs the probe only fires when a `~/.colima/cage/docker.sock` socket exists under `FAKE_HOME`, which no other test creates; on Linux the function returns immediately.)

- [ ] **Step 5: Commit**

```bash
git add cage.sh tests/test_cage.sh
git commit -m "Route cage subcommands to the colima cage VM daemon when needed"
```

---

### Task 7: Preserve docker mode across `restart` and `upgrade`

**Files:**
- Modify: `cage.sh` (`cmd_restart`, `cmd_upgrade`; new `preserve_docker_mode` after `route_to_container`)
- Test: `tests/test_cage.sh`

**Interfaces:**
- Consumes: `container_docker_mode`, `route_to_container`, `CAGE_DOCKER_MODE`, `cage_banner_docker_warning`.
- Produces: `preserve_docker_mode(name)` — reads the label off the existing container and sets `CAGE_DOCKER_MODE` (plus the warning banner for `host` mode) so the recreation path in `cmd_enter` keeps the cage docker-enabled.

- [ ] **Step 1: Write the failing tests**

```bash
test_restart_preserves_docker_mode() {
    mock_reset
    mock_uname Linux
    mock_stat_gid 999
    mock_docker_response "info" 0 ""
    mock_docker_response_n "inspect" 1 0 "true"   # state: exists
    mock_docker_response_n "inspect" 2 0 "host"   # cage.docker label
    mock_docker_response "rm" 0 ""
    mock_docker_response_n "inspect" 3 1 ""       # after rm: none → create
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
    mock_docker_response "rm" 0 ""
    mock_docker_response_n "inspect" 3 1 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage restart >/dev/null 2>&1 || true
    assert_not_contains "$(mock_calls)" "cage.docker" "no docker args for plain cage"
    unmock_uname
}

test_upgrade_preserves_docker_mode() {
    mock_reset
    mock_uname Linux
    mock_stat_gid 999
    mock_docker_response "info" 0 ""
    mock_docker_response "pull" 0 ""
    mock_docker_response_n "inspect" 1 0 "true"        # state
    mock_docker_response_n "inspect" 2 0 "sha256:old"  # container image id
    mock_docker_response "image" 0 "sha256:new"        # newer available
    mock_docker_response_n "inspect" 3 0 "host"        # label
    mock_docker_response "rm" 0 ""
    mock_docker_response_n "inspect" 4 1 ""            # gone → create
    mock_docker_response "create" 0 ""
    mock_docker_response "start" 0 ""
    run_cage upgrade >/dev/null 2>&1 || true
    assert_contains "$(mock_calls)" "cage.docker=host" "upgrade keeps docker mode"
    unmock_stat
    unmock_uname
}
```

Register:

```bash
    run_test test_restart_preserves_docker_mode
    run_test test_restart_plain_container_stays_plain
    run_test test_upgrade_preserves_docker_mode
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_cage.sh 2>&1 | tail -25`
Expected: the two `preserves` tests FAIL (recreated container has no docker args); `stays_plain` may pass.

- [ ] **Step 3: Implement**

Add after `route_to_container` in `cage.sh`:

```bash
# Recreation flows (restart, upgrade) must keep a docker-enabled cage
# docker-enabled: restore CAGE_DOCKER_MODE from the container's label
# before the old container is removed.
preserve_docker_mode() {
    local name="$1"
    local mode
    mode="$(container_docker_mode "$name")"
    [ -n "$mode" ] || return 0
    CAGE_DOCKER_MODE="$mode"
    [ "$mode" = "host" ] && cage_banner_docker_warning
    return 0
}
```

In `cmd_restart` (line ~433), add routing + preservation:

```bash
cmd_restart() {
    local project_dir="$1"
    local name
    name="$(container_name "$project_dir")"
    route_to_container "$name"
    local state
    state="$(container_state "$name")"

    if [ "$state" = "none" ]; then
        die "No container for $project_dir. Use 'cage start' to create one."
    fi

    preserve_docker_mode "$name"
    $DOCKER rm -f "$name" >/dev/null 2>&1 || true
    cmd_enter "$project_dir"
}
```

In `cmd_upgrade`, add routing after `name=` and preservation just before removal:

```bash
    local name
    name="$(container_name "$project_dir")"
    route_to_container "$name"
    local state
    state="$(container_state "$name")"
    if [ "$state" != "none" ]; then
        if image_newer_available "$name"; then
            preserve_docker_mode "$name"
            info "Removing old container $name"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_cage.sh 2>&1 | tail -25`
Expected: `Failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add cage.sh tests/test_cage.sh
git commit -m "Preserve docker mode across restart and upgrade"
```

---

### Task 8: `list`, `obliterate`, `rmconfig` cover the cage VM daemon

**Files:**
- Modify: `cage.sh` (`cmd_list` → `list_daemon_containers` + wrapper; `cmd_obliterate` → `obliterate_daemon` + wrapper; `cmd_rmconfig` → `rmconfig_daemon` + wrapper)
- Test: `tests/test_cage.sh`

**Interfaces:**
- Consumes: `COLIMA_CAGE_SOCK`, `make_cage_vm_socket` test helper (Task 6).
- Produces: `list_daemon_containers <with_header|no_header>` (body of old `cmd_list`, header conditional); `obliterate_daemon` / `rmconfig_daemon` (bodies of old commands). Wrappers run the body once normally, then once with `DOCKER_HOST="unix://$COLIMA_CAGE_SOCK"` when on Darwin, the socket exists, and `DOCKER_HOST` isn't already set. `obliterate` prints the hint `colima delete --profile cage`.

- [ ] **Step 1: Write the failing tests**

```bash
test_list_includes_cage_vm_daemon() {
    mock_reset
    mock_uname Darwin
    make_cage_vm_socket
    mock_docker_response "info" 0 ""
    mock_docker_response "ps" 0 ""
    local out; out="$(DOCKER_HOST= run_cage list)"
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
    DOCKER_HOST= run_cage list >/dev/null
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
    local out; out="$(DOCKER_HOST= run_cage obliterate 2>&1)"
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
    DOCKER_HOST= run_cage rmconfig >/dev/null 2>&1
    assert_eq "2" "$(mock_call_count ps)" "both daemons swept"
    remove_cage_vm_socket
    unmock_uname
}
```

Register:

```bash
    run_test test_list_includes_cage_vm_daemon
    run_test test_list_single_daemon_without_cage_vm
    run_test test_obliterate_covers_cage_vm
    run_test test_rmconfig_covers_cage_vm
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_cage.sh 2>&1 | tail -25`
Expected: the four new tests FAIL (single-daemon behavior); `test_list_single_daemon_without_cage_vm` may pass already.

- [ ] **Step 3: Implement**

Rename `cmd_list` to `list_daemon_containers` taking a header flag — change the signature and the two header lines only:

```bash
list_daemon_containers() {
    local show_header="$1"
    # Docker uses .Label "key"; Podman uses index .Labels "key".
    local label_tpl='{{.Label "cage.project"}}'
    [ "$DOCKER" = "podman" ] && label_tpl='{{index .Labels "cage.project"}}'

    local fmt="%-35s %-25s %-32s %s\n"
    if [ "$show_header" = "with_header" ]; then
        printf "$fmt" "NAMES" "STATUS" "IMAGE" "PROJECT"
    fi
    ... (rest of the old cmd_list body unchanged) ...
}
```

New wrappers (a shared predicate keeps them symmetrical):

```bash
# True when this invocation should also sweep the cage VM daemon.
cage_vm_daemon_reachable() {
    [[ "$(uname -s)" == "Darwin" ]] || return 1
    [ -z "${DOCKER_HOST:-}" ] || return 1
    [ -S "$COLIMA_CAGE_SOCK" ]
}

cmd_list() {
    list_daemon_containers with_header
    if cage_vm_daemon_reachable; then
        DOCKER_HOST="unix://$COLIMA_CAGE_SOCK" list_daemon_containers no_header
    fi
}
```

Rename the bodies of `cmd_obliterate` → `obliterate_daemon` and `cmd_rmconfig` → `rmconfig_daemon` (contents unchanged), then:

```bash
cmd_obliterate() {
    obliterate_daemon
    if cage_vm_daemon_reachable; then
        info "Cleaning the cage VM daemon"
        DOCKER_HOST="unix://$COLIMA_CAGE_SOCK" obliterate_daemon
        info "To remove the cage VM entirely: colima delete --profile $COLIMA_PROFILE"
    fi
}

cmd_rmconfig() {
    rmconfig_daemon
    if cage_vm_daemon_reachable; then
        info "Cleaning the cage VM daemon"
        DOCKER_HOST="unix://$COLIMA_CAGE_SOCK" rmconfig_daemon
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_cage.sh 2>&1 | tail -25`
Expected: `Failed: 0` (existing list/obliterate/rmconfig tests keep passing — no cage VM socket exists under `FAKE_HOME` in them).

- [ ] **Step 5: Commit**

```bash
git add cage.sh tests/test_cage.sh
git commit -m "Sweep the colima cage VM daemon in list, obliterate, and rmconfig"
```

---

### Task 9: Warn when the image lacks the docker CLI

**Files:**
- Modify: `cage.sh` (replace the Task 1 stub `check_docker_cli_in_image`)
- Test: `tests/test_cage.sh`

**Interfaces:**
- Consumes: called from `cmd_enter`'s docker_args block (wired in Task 1).
- Produces: `check_docker_cli_in_image()` — runs a one-shot `sh -c 'command -v docker'` in the image; on failure prints a non-fatal warning naming the image.

- [ ] **Step 1: Write the failing tests**

```bash
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
```

Register:

```bash
    run_test test_dstart_warns_when_image_lacks_docker_cli
    run_test test_dstart_no_warning_when_docker_cli_present
    run_test test_start_never_runs_cli_check
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_cage.sh 2>&1 | tail -25`
Expected: `test_dstart_warns_when_image_lacks_docker_cli` FAILS (stub never warns); the other two pass.

- [ ] **Step 3: Implement**

Replace the stub in `cage.sh`:

```bash
# Warn (never fail) when the image lacks the docker CLI — compose work
# inside a docker-enabled cage needs it.  Images without sh also trip
# this check; the warning is advisory either way.
check_docker_cli_in_image() {
    if ! $DOCKER run --rm --entrypoint sh "$IMAGE" -c 'command -v docker' >/dev/null 2>&1; then
        info "Warning: image $IMAGE has no docker CLI — 'docker' commands inside the cage will fail."
        info "Use an image that ships the docker CLI and compose plugin."
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_cage.sh 2>&1 | tail -25`
Expected: `Failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add cage.sh tests/test_cage.sh
git commit -m "Warn when the cage image lacks the docker CLI"
```

---

### Task 10: Docs, help text, and version bump

**Files:**
- Modify: `cage.sh` (line 4 `VERSION`; `cmd_help` lines 477-510)
- Modify: `tests/test_cage.sh` (three version assertions, lines ~311-317; one new help test)
- Modify: `README.md` (new "Docker inside your cage" section)
- Modify: `CLAUDE.md` (subcommands table, env vars, new design notes)

**Interfaces:**
- Consumes: everything shipped in Tasks 1-9.
- Produces: user-facing documentation; `VERSION="0.9.0"`.

- [ ] **Step 1: Update version tests and add help test**

In `tests/test_cage.sh`, change the three assertions at lines ~311-317 from `"cage 0.8.0"` to `"cage 0.9.0"`, and add:

```bash
test_help_mentions_dstart() {
    local out; out="$(run_cage help)"
    assert_contains "$out" "dstart" "help documents dstart"
    assert_contains "$out" "CAGE_SRC_ROOT" "help documents CAGE_SRC_ROOT"
}
```

Register under the help/version section: `run_test test_help_mentions_dstart`

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_cage.sh 2>&1 | tail -20`
Expected: three version tests + the help test FAIL.

- [ ] **Step 3: Implement**

In `cage.sh`: set `VERSION="0.9.0"`. In `cmd_help`, add after the `start` entry:

```
  dstart [-p ...] [-v ...]
            Like start, but docker-enabled: the agent gets a docker socket
            and can run docker/compose for multi-service projects.
            Linux: mounts the host socket (trusted — see warning banner).
            macOS: uses a dedicated colima VM 'cage' that mounts only
            CAGE_SRC_ROOT (contained — requires colima).
```

and extend the `Environment:` section:

```
  CAGE_SRC_ROOT   Source root mounted into the macOS cage VM (default: ~/src)
  CAGE_VM_CPU     CPUs for the macOS cage VM (default: 4)
  CAGE_VM_MEMORY  Memory in GiB for the macOS cage VM (default: 8)
                  (all three also read from ~/.config/cage/env)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_cage.sh 2>&1 | tail -20`
Expected: `Failed: 0`.

- [ ] **Step 5: Update README.md**

Add a section after the existing usage docs (adapt placement to the README's structure — it uses progressive disclosure, so this goes with the advanced material):

```markdown
## Docker inside your cage (multi-service projects)

For full-stack projects where the services themselves run in containers, use
`cage dstart` instead of `cage start`. The agent gets a docker socket and can
run `docker compose up/down/build`, read service logs, and exec into services.

    cage dstart

What the agent's docker socket controls depends on your platform:

- **Linux — trusted mode.** The host daemon's socket is mounted into the cage.
  This is convenient but not contained: a socket is root-equivalent on the
  machine. cage prints a warning banner so nobody is surprised.
- **macOS — contained mode.** cage provisions a dedicated
  [colima](https://github.com/abiosoft/colima) VM (profile `cage`) that mounts
  only `CAGE_SRC_ROOT` (default `~/src`). The agent container and everything it
  spawns live inside that VM. A socket escape is worth at most your project
  checkouts — not your home directory. Requires colima
  (`brew install colima`); Docker Desktop and OrbStack are not supported for
  dstart because their sockets expose your file-shared home directory.

Because cage mounts your project at the same absolute path everywhere (and
colima preserves host paths in the VM), compose files with relative bind
mounts (`./src:/app/src`) work unchanged.

Notes:

- Docker-enablement is a creation-time property. `cage status` shows it
  (`Docker: host|colima|none`). To toggle it: `cage rm`, then
  `cage dstart` (or `cage start`).
- To reach a compose service from inside the cage, join its network:
  `docker network connect <network> $(hostname)`. On macOS, published ports
  are also forwarded to Mac localhost by colima.
- `cage rm` removes the agent container but not the services it started —
  use `docker compose down` first, or on macOS nuke everything with
  `colima delete --profile cage`.
- macOS: the cage VM's daemon has its own `cage-home` volume, so your first
  dstart needs a one-time re-login to Claude (the seed directory applies as
  usual).
- VM sizing: `CAGE_VM_CPU` (default 4) and `CAGE_VM_MEMORY` (default 8 GiB),
  set in the environment or `~/.config/cage/env`. Changing `CAGE_SRC_ROOT`
  after the VM exists requires `colima delete --profile cage`.
```

- [ ] **Step 6: Update CLAUDE.md**

- Add to the Subcommands list: `cage.sh dstart` — docker-enabled start (Linux: host socket; macOS: colima `cage` VM).
- Add to Environment Variables: `CAGE_SRC_ROOT`, `CAGE_VM_CPU`, `CAGE_VM_MEMORY` (defaults `~/src`, 4, 8; also read from `~/.config/cage/env`).
- Add a short "Docker-Enabled Cages" design section: the `cage.docker=host|colima` label, `DOCKER_HOST` retargeting to `~/.colima/cage/docker.sock`, cross-daemon routing (`route_to_container`), and mode preservation on restart/upgrade.

- [ ] **Step 7: Run full unit suite and commit**

Run: `bash tests/test_cage.sh 2>&1 | tail -5`
Expected: `Failed: 0`.

```bash
git add cage.sh tests/test_cage.sh README.md CLAUDE.md
git commit -m "Document dstart, bump version to 0.9.0"
```

---

### Task 11: Integration tests (Linux CI, real daemon)

**Files:**
- Modify: `tests/test_integration.sh`

**Interfaces:**
- Consumes: `dstart` trusted mode from Tasks 1-2, status line from Task 3.
- Produces: real-runtime coverage of the Linux trusted path. dstart tests run only when the runtime is docker (podman CI hosts may have no reachable socket at the mounted path).

- [ ] **Step 1: Write the tests**

Add to `tests/test_integration.sh` before the `main()` function:

```bash
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
```

Register in the integration `main()`, after the "listing and cleanup" section:

```bash
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
```

- [ ] **Step 2: Verify locally what can be verified**

Integration tests refuse to run on macOS (by design). Verify syntax only:

Run: `bash -n tests/test_integration.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`

Then run the full unit suite one more time: `bash tests/test_cage.sh 2>&1 | tail -5`
Expected: `Failed: 0`.

- [ ] **Step 3: Commit**

```bash
git add tests/test_integration.sh
git commit -m "Add integration tests for dstart trusted mode"
```

(The integration workflow triggers on push to main; watch the CI run after the branch merges — `gh run watch` — and fix any Linux-only failures.)
