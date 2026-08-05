#!/usr/bin/env bash
set -euo pipefail

VERSION="0.9.0"
IMAGE="${CAGE_IMAGE:-ghcr.io/pacificsky/devcontainer-lite:latest}"
HOME_VOL="cage-home"
COLIMA_PROFILE="cage"
COLIMA_CAGE_SOCK="$HOME/.colima/cage/docker.sock"
CAGE_DOCKER_MODE=""   # "", "host", or "colima" — set by dstart / preserve_docker_mode

# Detect container runtime: prefer docker, fall back to podman.
if command -v docker &>/dev/null; then
    DOCKER=docker
elif command -v podman &>/dev/null; then
    DOCKER=podman
else
    DOCKER=docker   # let ensure_docker report the error
fi

# --- Helpers ---

die() { echo "error: $*" >&2; exit 1; }
info() { echo "cage: $*" >&2; }

cage_banner_enter() {
    local name="$1"
    local c="\033[1;36m" r="\033[0m"
    local line="═══════════════════════════════════════════════════════════════"
    printf '%b\n' "${c}${line}${r}" >&2
    printf '%b\n' "${c}  ▶  ENTERING CAGE: ${name}${r}" >&2
    printf '%b\n' "${c}  ▶  Type 'exit' or press Ctrl+D to return to host${r}" >&2
    printf '%b\n' "${c}${line}${r}" >&2
}

cage_banner_exit() {
    local name="$1"
    local c="\033[1;33m" r="\033[0m"
    local line="═══════════════════════════════════════════════════════════════"
    printf '%b\n' "${c}${line}${r}" >&2
    printf '%b\n' "${c}  ◀  EXITED CAGE: ${name} — back on host${r}" >&2
    printf '%b\n' "${c}${line}${r}" >&2
}

drop_into_cage() {
    local name="$1"; shift
    cage_banner_enter "$name"
    local rc=0
    "$@" || rc=$?
    cage_banner_exit "$name"
    return $rc
}

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

# On macOS a project's container may live in the cage colima VM rather than
# the default daemon.  If it isn't found locally, retarget this invocation.
route_to_container() {
    local name="$1"
    [[ "$(uname -s)" == "Darwin" ]] || return 0
    [ -n "${DOCKER_HOST:-}" ] && return 0          # already targeted
    [ -S "$COLIMA_CAGE_SOCK" ] || return 0         # no cage VM → nothing to route to
    [ "$(container_state "$name")" = "none" ] || return 0
    if DOCKER_HOST="unix://$COLIMA_CAGE_SOCK" $DOCKER inspect "$name" >/dev/null 2>&1; then
        export DOCKER_HOST="unix://$COLIMA_CAGE_SOCK"
    fi
    return 0
}

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

# Warn (never fail) when the image lacks the docker CLI — compose work
# inside a docker-enabled cage needs it.  Images without sh also trip
# this check; the warning is advisory either way.
check_docker_cli_in_image() {
    if ! $DOCKER run --rm --entrypoint sh "$IMAGE" -c 'command -v docker' >/dev/null 2>&1; then
        info "Warning: image $IMAGE has no docker CLI — 'docker' commands inside the cage will fail."
        info "Use an image that ships the docker CLI and compose plugin."
    fi
}

container_name() {
    local abs_path="$1"
    local dirname
    dirname="$(basename "$abs_path")"
    local hash
    hash="$(printf '%s' "$abs_path" | shasum -a 256 | cut -c1-8)"
    echo "cage-${dirname}-${hash}"
}

container_state() {
    local name="$1"
    local state
    state="$($DOCKER inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" || {
        echo "none"
        return
    }
    if [ "$state" = "true" ]; then
        echo "running"
    else
        echo "stopped"
    fi
}

ensure_docker() {
    $DOCKER info >/dev/null 2>&1 || die "Docker is not running. Start Docker (or colima/podman) first."
}

image_newer_available() {
    local name="$1"
    local container_image_id
    container_image_id="$($DOCKER inspect -f '{{.Image}}' "$name" 2>/dev/null)" || return 1
    local latest_image_id
    latest_image_id="$($DOCKER image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null)" || return 1
    [ "$container_image_id" != "$latest_image_id" ]
}

# Warn if Colima is the active Docker runtime but SSH agent forwarding is off.
check_colima_ssh_agent() {
    command -v colima &>/dev/null || return 0

    local docker_host="${DOCKER_HOST:-}"
    if [[ -z "$docker_host" ]]; then
        docker_host="$($DOCKER context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" || true
    fi
    [[ "$docker_host" == *colima* ]] || return 0

    # Extract profile name from socket path (~/.colima/<profile>/docker.sock).
    local colima_profile="default"
    if [[ "$docker_host" =~ \.colima/([^/]+)/ ]]; then
        colima_profile="${BASH_REMATCH[1]}"
    fi

    local colima_config="$HOME/.colima/${colima_profile}/colima.yaml"
    if [[ -f "$colima_config" ]] && grep -q 'forwardAgent:.*true' "$colima_config"; then
        return 0
    fi

    info "Warning: Colima does not have SSH agent forwarding enabled."
    info "SSH keys won't be available inside the container."
    info "Fix: colima stop && colima start --ssh-agent"
}

# Read mount specs from a mounts file, one per line.  Blank lines and lines
# starting with '#' are ignored.  A leading '~/' expands to $HOME.  A line with
# no ':' is shorthand for mounting a host path at the same absolute path inside
# the container, the way the project dir is mounted.  Anything else is handed to
# docker verbatim, so ':ro' options and named volumes work as usual.
read_mounts_file() {
    local file="$1"
    [ -f "$file" ] || return 0

    local spec
    # No IFS= here, so read strips leading/trailing whitespace from each line.
    while read -r spec || [ -n "$spec" ]; do
        case "$spec" in
            ""|"#"*) continue ;;
            "~/"*)   spec="${HOME}/${spec#\~/}" ;;
        esac
        case "$spec" in
            *:*) ;;
            *)   spec="${spec}:${spec}" ;;
        esac
        printf '%s\n' "$spec"
    done < "$file"
}

# The container-side target of a docker -v spec: the field after the first
# colon, with any trailing options (':ro') removed.
mount_target() {
    local spec="$1"
    local rest="${spec#*:}"
    printf '%s\n' "${rest%%:*}"
}

# Emit '-v' and '<spec>' (one per line) for every extra mount declared in
# ~/.config/cage/mounts and <project>/.cage.mounts.  When two mounts share a
# container target the more specific one wins: a -v on the command line beats
# the per-project file, which beats the global file.
build_mount_args() {
    local project_dir="$1"
    shift

    # Targets already claimed by command-line -v flags, delimited for lookup.
    local claimed="|"
    local target
    while [ $# -gt 0 ]; do
        if [ "$1" = "-v" ] && [ $# -ge 2 ]; then
            target="$(mount_target "$2")"
            claimed="${claimed}${target}|"
            shift 2
        else
            shift
        fi
    done

    local -a specs=()
    local spec
    while IFS= read -r spec; do
        specs+=("$spec")
    done < <(read_mounts_file "$HOME/.config/cage/mounts"
             read_mounts_file "${project_dir}/.cage.mounts")

    # Walk back to front so the last declaration of a target is the one kept,
    # prepending each survivor so the emitted order still matches the files.
    local -a out=()
    local i
    for (( i=${#specs[@]}-1; i>=0; i-- )); do
        target="$(mount_target "${specs[$i]}")"
        case "$claimed" in
            *"|${target}|"*) continue ;;
        esac
        claimed="${claimed}${target}|"
        out=(-v "${specs[$i]}" ${out[@]+"${out[@]}"})
    done

    [ ${#out[@]} -gt 0 ] || return 0
    printf '%s\n' "${out[@]}"
}

# Copy seed files from ~/.config/cage/home/ into the container's /home/vscode/.
# Uses cp -n (no-clobber) so existing files in the volume are never overwritten.
# The container must be in "created" (stopped) state.  This function starts
# it (detached) so docker exec can run, and returns 0.  If there is nothing
# to seed it returns 1 and leaves the container stopped.
seed_home() {
    local name="$1"
    local seed_dir="$HOME/.config/cage/home"

    [ -d "$seed_dir" ] || return 1
    [ -n "$(ls -A "$seed_dir" 2>/dev/null)" ] || return 1

    info "Seeding home directory from $seed_dir"
    $DOCKER cp "$seed_dir/." "$name:/tmp/cage-seed"
    $DOCKER start "$name"
    $DOCKER exec "$name" sh -c 'cp -rn /tmp/cage-seed/. /home/vscode/ && rm -rf /tmp/cage-seed'
    return 0
}

# --- Subcommands ---

cmd_enter() {
    local project_dir="$1"
    shift
    # Holds the -p and -v flags collected from the command line.
    local -a cli_flags=("$@")

    local name
    name="$(container_name "$project_dir")"
    route_to_container "$name"
    ensure_docker
    local state
    state="$(container_state "$name")"

    case "$state" in
        running)
            if [ ${#cli_flags[@]} -gt 0 ]; then
                info "Container already exists — ignoring -p/-v flags. Use 'cage.sh rm' to recreate with new ports and mounts."
            fi
            if image_newer_available "$name"; then
                info "A newer image is available. Run 'cage upgrade' to upgrade."
            fi
            info "Re-attaching to $name"
            drop_into_cage "$name" $DOCKER attach "$name"
            ;;
        stopped)
            if [ ${#cli_flags[@]} -gt 0 ]; then
                info "Container already exists — ignoring -p/-v flags. Use 'cage.sh rm' to recreate with new ports and mounts."
            fi
            if image_newer_available "$name"; then
                info "A newer image is available. Run 'cage upgrade' to upgrade."
            fi
            info "Restarting $name"
            drop_into_cage "$name" $DOCKER start -ai "$name"
            ;;
        none)
            if [[ "$IMAGE" == */* ]]; then
                info "Pulling latest image..."
                $DOCKER pull "$IMAGE"
            fi
            info "Creating $name"

            local -a mount_args=(
                -v "${project_dir}:${project_dir}"
                -v "${HOME_VOL}:/home/vscode"
            )

            # Extra mounts declared in ~/.config/cage/mounts and .cage.mounts.
            local -a extra_mount_args=()
            local mount_arg
            while IFS= read -r mount_arg; do
                extra_mount_args+=("$mount_arg")
            done < <(build_mount_args "$project_dir" ${cli_flags[@]+"${cli_flags[@]}"})

            # Forward the host SSH agent so git/ssh work inside the container.
            local -a ssh_agent_args=()
            if [[ "$(uname -s)" == "Darwin" ]]; then
                # macOS: host sockets can't be bind-mounted across the VM
                # boundary.  Docker Desktop and Colima (with --ssh-agent)
                # expose a VM-internal proxy at /run/host-services/ssh-auth.sock.
                ssh_agent_args=(
                    -v /run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock
                    -e SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock
                )
                check_colima_ssh_agent
            elif [[ -n "${SSH_AUTH_SOCK:-}" ]] && [[ -S "$SSH_AUTH_SOCK" ]]; then
                # Linux: bind-mount the host socket directly.
                ssh_agent_args=(
                    -v "${SSH_AUTH_SOCK}:/tmp/ssh-agent.sock"
                    -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
                )
            fi

            # Inject environment variables from env files (if present).
            # Global first; per-project overrides for duplicate keys.
            local -a env_file_args=()
            local global_env="$HOME/.config/cage/env"
            local project_env="${project_dir}/.cage.env"
            [[ -f "$global_env" ]] && env_file_args+=(--env-file "$global_env")
            [[ -f "$project_env" ]] && env_file_args+=(--env-file "$project_env")

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

            $DOCKER create -it \
                --name "$name" \
                --hostname "$name" \
                --workdir "$project_dir" \
                ${cli_flags[@]+"${cli_flags[@]}"} \
                "${mount_args[@]}" \
                ${extra_mount_args[@]+"${extra_mount_args[@]}"} \
                ${ssh_agent_args[@]+"${ssh_agent_args[@]}"} \
                ${env_file_args[@]+"${env_file_args[@]}"} \
                ${docker_args[@]+"${docker_args[@]}"} \
                -e UV_PROJECT_ENVIRONMENT=.cage-venv \
                -e HOST_UID="$(id -u)" \
                -e HOST_GID="$(id -g)" \
                -l "cage.project=${project_dir}" \
                "$IMAGE" >/dev/null

            if seed_home "$name"; then
                drop_into_cage "$name" $DOCKER attach "$name"
            else
                drop_into_cage "$name" $DOCKER start -ai "$name"
            fi
            ;;
    esac
}

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

    if ! colima status --profile "$COLIMA_PROFILE" >/dev/null 2>&1; then
        local cpu memory disk
        cpu="$(cage_config_get CAGE_VM_CPU)"
        cpu="${cpu:-4}"
        memory="$(cage_config_get CAGE_VM_MEMORY)"
        memory="${memory:-8}"
        disk="$(cage_config_get CAGE_VM_DISK)"
        disk="${disk:-60}"
        info "Starting the cage VM (first run provisions it — takes about a minute)..."
        colima start --profile "$COLIMA_PROFILE" \
            --mount "${src_root}:w" \
            --ssh-agent \
            --cpu "$cpu" \
            --memory "$memory" \
            --disk "$disk" \
            --activate=false \
            || die "colima failed to start the cage VM. If the profile is corrupt, try: colima delete --profile $COLIMA_PROFILE"
    fi

    export DOCKER_HOST="unix://$COLIMA_CAGE_SOCK"
}

cmd_dstart() {
    local project_dir="$1"
    shift

    local name
    name="$(container_name "$project_dir")"

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
        CAGE_DOCKER_MODE="host"
        cage_banner_docker_warning
    fi

    ensure_docker

    if [ "$(container_state "$name")" != "none" ] && [ -z "$(container_docker_mode "$name")" ]; then
        info "Container already exists without docker — re-attaching. Use 'cage rm' then 'cage dstart' to enable docker."
    fi

    cmd_enter "$project_dir" "$@"
}

cmd_stop() {
    local project_dir="$1"
    local name
    name="$(container_name "$project_dir")"
    route_to_container "$name"
    ensure_docker
    local state
    state="$(container_state "$name")"

    case "$state" in
        running)
            info "Stopping $name"
            $DOCKER stop "$name"
            ;;
        stopped)
            info "$name is already stopped"
            ;;
        none)
            die "No container for $project_dir"
            ;;
    esac
}

cmd_rm() {
    local project_dir="$1"
    local name
    name="$(container_name "$project_dir")"
    route_to_container "$name"
    ensure_docker
    local state
    state="$(container_state "$name")"

    case "$state" in
        running)
            info "Stopping and removing $name"
            $DOCKER rm -f "$name"
            ;;
        stopped)
            info "Removing $name"
            $DOCKER rm "$name"
            ;;
        none)
            die "No container for $project_dir"
            ;;
    esac
}

# True when this invocation should also sweep the cage VM daemon.
cage_vm_daemon_reachable() {
    [[ "$(uname -s)" == "Darwin" ]] || return 1
    [ -z "${DOCKER_HOST:-}" ] || return 1
    [ -S "$COLIMA_CAGE_SOCK" ]
}

rmconfig_daemon() {
    local ids
    ids="$($DOCKER ps -a --filter "label=cage.project" -q)" || true
    if [ -n "$ids" ]; then
        local running
        running="$($DOCKER ps --filter "label=cage.project" -q)" || true
        if [ -n "$running" ]; then
            info "Stopping running cage containers"
            echo "$running" | xargs $DOCKER stop
        fi
    fi
    if $DOCKER volume inspect "$HOME_VOL" >/dev/null 2>&1; then
        info "Removing shared home volume $HOME_VOL"
        $DOCKER volume rm "$HOME_VOL"
    else
        info "No shared home volume to remove"
    fi
}

obliterate_daemon() {
    local ids
    ids="$($DOCKER ps -a --filter "label=cage.project" -q)" || true
    if [ -n "$ids" ]; then
        info "Removing all cage containers"
        echo "$ids" | xargs $DOCKER rm -f
    else
        info "No cage containers to remove"
    fi
    if $DOCKER volume inspect "$HOME_VOL" >/dev/null 2>&1; then
        info "Removing shared home volume $HOME_VOL"
        $DOCKER volume rm "$HOME_VOL"
    else
        info "No shared home volume to remove"
    fi
}

cmd_rmconfig() {
    rmconfig_daemon
    if cage_vm_daemon_reachable; then
        info "Cleaning the cage VM daemon"
        ( export DOCKER_HOST="unix://$COLIMA_CAGE_SOCK"; rmconfig_daemon )
    fi
}

cmd_obliterate() {
    obliterate_daemon
    if cage_vm_daemon_reachable; then
        info "Cleaning the cage VM daemon"
        ( export DOCKER_HOST="unix://$COLIMA_CAGE_SOCK"; obliterate_daemon )
        info "To remove the cage VM entirely: colima delete --profile $COLIMA_PROFILE"
    fi
}

cmd_status() {
    local project_dir="$1"
    local name
    name="$(container_name "$project_dir")"
    route_to_container "$name"
    ensure_docker
    local state
    state="$(container_state "$name")"

    echo "Container: $name"
    echo "State:     $state"

    if [ "$state" != "none" ]; then
        local dmode
        dmode="$(container_docker_mode "$name")"
        echo "Docker:    ${dmode:-none}"

        local ports
        ports="$($DOCKER port "$name" 2>/dev/null)" || true
        if [ -n "$ports" ]; then
            echo "Ports:"
            echo "$ports" | sed 's/^/  /'
        else
            echo "Ports:     (none)"
        fi
    fi
}

list_daemon_containers() {
    local show_header="$1"
    # Docker uses .Label "key"; Podman uses index .Labels "key".
    local label_tpl='{{.Label "cage.project"}}'
    [ "$DOCKER" = "podman" ] && label_tpl='{{index .Labels "cage.project"}}'

    local fmt="%-35s %-25s %-32s %s\n"
    if [ "$show_header" = "with_header" ]; then
        printf "$fmt" "NAMES" "STATUS" "IMAGE" "PROJECT"
    fi

    # Collect container rows from docker ps.
    local -a names=() statuses=() projects=() images=()
    while IFS=$'\t' read -r name status project image; do
        names+=("$name")
        statuses+=("$status")
        projects+=("$project")
        images+=("$image")
    done < <($DOCKER ps -a --filter "label=cage.project" \
        --format "{{.Names}}\t{{.Status}}\t${label_tpl}\t{{.Image}}")

    [ ${#names[@]} -eq 0 ] && return 0

    # Batch-fetch image SHAs for all containers in a single inspect call.
    # Use parallel arrays instead of associative array for Bash 3.x compat.
    local -a sha_keys=() sha_vals=() sha_full=()
    while IFS='|' read -r cname csha; do
        sha_keys+=("$cname")
        sha_full+=("$csha")
        csha="${csha#sha256:}"
        sha_vals+=("${csha:0:8}")
    done < <($DOCKER inspect --format '{{.Name}}|{{.Image}}' "${names[@]}" 2>/dev/null |
        sed 's|^/||')

    # Batch-fetch image creation dates. Deduplicate full image IDs first.
    local -a date_keys=() date_vals=()
    local -a unique_ids=()
    local k already
    for k in "${sha_full[@]}"; do
        already=""
        local u
        for u in "${unique_ids[@]+"${unique_ids[@]}"}"; do
            [ "$u" = "$k" ] && { already=1; break; }
        done
        [ -z "$already" ] && unique_ids+=("$k")
    done
    if [ ${#unique_ids[@]} -gt 0 ]; then
        while IFS='|' read -r did dcreated; do
            date_keys+=("$did")
            date_vals+=("${dcreated:0:10}")
        done < <($DOCKER image inspect --format '{{.Id}}|{{.Created}}' "${unique_ids[@]}" 2>/dev/null)
    fi

    local i
    for (( i=0; i<${#names[@]}; i++ )); do
        local image="${images[$i]}"
        # Extract tag: strip registry/repo prefix (everything up to last colon
        # after the last slash) to avoid confusing registry ports with tags.
        local repo_tag="${image##*/}"
        local tag="${repo_tag##*:}"
        [ "$tag" = "$repo_tag" ] && tag=""
        # Look up SHA and full image ID from parallel arrays.
        local img_sha="" img_full="" j
        for (( j=0; j<${#sha_keys[@]}; j++ )); do
            if [ "${sha_keys[$j]}" = "${names[$i]}" ]; then
                img_sha="${sha_vals[$j]}"
                img_full="${sha_full[$j]}"
                break
            fi
        done
        # Look up creation date from image inspect results.
        local img_date=""
        if [ -n "$img_full" ]; then
            local d
            for (( d=0; d<${#date_keys[@]}; d++ )); do
                if [ "${date_keys[$d]}" = "$img_full" ]; then
                    img_date="${date_vals[$d]}"
                    break
                fi
            done
        fi
        local img_desc
        if [ -n "$tag" ] && [ -n "$img_sha" ] && [ -n "$img_date" ]; then
            img_desc="${tag} (${img_sha}, ${img_date})"
        elif [ -n "$tag" ] && [ -n "$img_sha" ]; then
            img_desc="${tag} (${img_sha})"
        elif [ -n "$img_sha" ] && [ -n "$img_date" ]; then
            img_desc="${img_sha} (${img_date})"
        elif [ -n "$img_sha" ]; then
            img_desc="${img_sha}"
        else
            img_desc="${image}"
        fi
        printf "$fmt" "${names[$i]}" "${statuses[$i]}" "$img_desc" "${projects[$i]}"
    done
}

cmd_list() {
    list_daemon_containers with_header
    if cage_vm_daemon_reachable; then
        ( export DOCKER_HOST="unix://$COLIMA_CAGE_SOCK"; list_daemon_containers no_header )
    fi
}

cmd_shell() {
    local project_dir="$1"
    local name
    name="$(container_name "$project_dir")"
    route_to_container "$name"
    ensure_docker
    local state
    state="$(container_state "$name")"

    [ "$state" = "running" ] || die "Container $name is not running"
    info "Opening shell in $name"
    drop_into_cage "$name" $DOCKER exec -it "$name" zsh
}

cmd_restart() {
    local project_dir="$1"
    local name
    name="$(container_name "$project_dir")"
    route_to_container "$name"
    ensure_docker
    local state
    state="$(container_state "$name")"

    if [ "$state" = "none" ]; then
        die "No container for $project_dir. Use 'cage start' to create one."
    fi

    preserve_docker_mode "$name"
    $DOCKER rm -f "$name" >/dev/null 2>&1 || true
    cmd_enter "$project_dir"
}

cmd_update() {
    if [[ "$IMAGE" != */* ]]; then
        die "Cannot update local image '$IMAGE'. Pull or build it manually."
    fi
    info "Pulling latest image..."
    $DOCKER pull "$IMAGE"
}

cmd_upgrade() {
    local project_dir="$1"
    cmd_update
    local name
    name="$(container_name "$project_dir")"
    route_to_container "$name"
    local state
    state="$(container_state "$name")"
    if [ "$state" != "none" ]; then
        if image_newer_available "$name"; then
            preserve_docker_mode "$name"
            info "Removing old container $name"
            $DOCKER rm -f "$name" >/dev/null 2>&1 || true
            info "Starting fresh container with new image"
            cmd_enter "$project_dir"
        else
            info "Container is already on the latest image."
        fi
    else
        info "No existing container. Use 'cage start' to create one."
    fi
}

cmd_help() {
    cat <<'EOF'
Usage: cage.sh <command> [options]

Commands:
  start [-p hostPort:containerPort]... [-v hostPath:containerPath]...
            Create new container or re-attach to existing one for CWD
  dstart [-p ...] [-v ...]
            Like start, but docker-enabled: the agent gets a docker socket
            and can run docker/compose for multi-service projects.
            Linux: mounts the host socket (trusted — see warning banner).
            macOS: uses a dedicated colima VM 'cage' that mounts only
            CAGE_SRC_ROOT (contained — requires colima).
  stop      Stop container for CWD project
  rm        Stop and remove container for CWD project
  status    Show container name, state, and port mappings
  list      List all cage containers
  shell     Open additional bash shell in running container
  restart   Remove and recreate container (shared home volume preserved)
  obliterate Destroy shared home volume and all cage containers (caution!!!)
  rmconfig  Stop all containers and remove shared home volume (containers are preserved, but will be recreated with fresh home on next start)
  update    Pull latest container image
  upgrade   Pull latest image and recreate container
  help      Show this help

Environment:
  CAGE_IMAGE      Override container image (default: ghcr.io/pacificsky/devcontainer-lite:latest)
  CAGE_SRC_ROOT   Source root mounted into the macOS cage VM (default: ~/src)
  CAGE_VM_CPU     CPUs for the macOS cage VM (default: 4)
  CAGE_VM_MEMORY  Memory in GiB for the macOS cage VM (default: 8)
  CAGE_VM_DISK    Disk in GiB for the macOS cage VM (default: 60)
                  (all of the above also read from ~/.config/cage/env)

Seed directory:
  ~/.config/cage/home/    Files copied (no-clobber) into /home/vscode/ on new containers

Environment files:
  ~/.config/cage/env      Global env vars for all containers (optional)
  .cage.env               Per-project env vars (optional, overrides global)
                          Format: KEY=VALUE lines, # comments, blank lines

Mount files:
  ~/.config/cage/mounts   Global extra mounts for all containers (optional)
  .cage.mounts            Per-project extra mounts (optional, overrides global)
                          Format: one docker -v spec per line.  Blank lines
                          and lines starting with # are ignored, '~/' expands
                          to $HOME, and a line with no ':' is mounted at the
                          same absolute path inside the container.

Port (-p), volume (-v) flags and config files only apply when creating a new container.
To change: cage.sh rm && cage.sh start -p 3000:3000 -v /data:/data
EOF
}

# --- Main ---

main() {
    local project_dir
    project_dir="$(pwd)"

    local cmd="${1:-}"
    [ $# -gt 0 ] && shift

    case "$cmd" in
        "")     cmd_help ;;
        -h|--help|help)
                cmd_help ;;
        -V|--version|version)
                echo "cage $VERSION" ;;
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
                cmd_enter "$project_dir" ${port_flags[@]+"${port_flags[@]}"} ${vol_flags[@]+"${vol_flags[@]}"}
            fi
            ;;
        stop)   cmd_stop "$project_dir" ;;
        rm)     cmd_rm "$project_dir" ;;
        status) cmd_status "$project_dir" ;;
        list)   ensure_docker; cmd_list ;;
        shell)  cmd_shell "$project_dir" ;;
        restart) cmd_restart "$project_dir" ;;
        obliterate) ensure_docker; cmd_obliterate ;;
        rmconfig) ensure_docker; cmd_rmconfig ;;
        update) ensure_docker; cmd_update ;;
        upgrade) ensure_docker; cmd_upgrade "$project_dir" ;;
        *)      die "Unknown command: $cmd. Run 'cage.sh help' for usage." ;;
    esac
}

main "$@"
