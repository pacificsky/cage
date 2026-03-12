#!/usr/bin/env bash
set -euo pipefail

VERSION="0.7.0"
IMAGE="${CAGE_IMAGE:-ghcr.io/pacificsky/devcontainer-lite:latest}"
HOME_VOL="cage-home"

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
    local -a port_flags=("$@")

    local name
    name="$(container_name "$project_dir")"
    local state
    state="$(container_state "$name")"

    case "$state" in
        running)
            if [ ${#port_flags[@]} -gt 0 ]; then
                info "Container already exists — ignoring -p flags. Use 'cage.sh rm' to recreate with new ports."
            fi
            if image_newer_available "$name"; then
                info "A newer image is available. Run 'cage upgrade' to upgrade."
            fi
            info "Re-attaching to $name"
            $DOCKER attach "$name"
            ;;
        stopped)
            if [ ${#port_flags[@]} -gt 0 ]; then
                info "Container already exists — ignoring -p flags. Use 'cage.sh rm' to recreate with new ports."
            fi
            if image_newer_available "$name"; then
                info "A newer image is available. Run 'cage upgrade' to upgrade."
            fi
            info "Restarting $name"
            $DOCKER start -ai "$name"
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

            $DOCKER create -it \
                --name "$name" \
                --hostname "$name" \
                --workdir "$project_dir" \
                ${port_flags[@]+"${port_flags[@]}"} \
                "${mount_args[@]}" \
                ${ssh_agent_args[@]+"${ssh_agent_args[@]}"} \
                -e UV_PROJECT_ENVIRONMENT=.cage-venv \
                -l "cage.project=${project_dir}" \
                "$IMAGE" >/dev/null

            if seed_home "$name"; then
                $DOCKER attach "$name"
            else
                $DOCKER start -ai "$name"
            fi
            ;;
    esac
}

cmd_stop() {
    local project_dir="$1"
    local name
    name="$(container_name "$project_dir")"
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

cmd_rmconfig() {
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

cmd_obliterate() {
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

cmd_status() {
    local project_dir="$1"
    local name
    name="$(container_name "$project_dir")"
    local state
    state="$(container_state "$name")"

    echo "Container: $name"
    echo "State:     $state"

    if [ "$state" != "none" ]; then
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

cmd_list() {
    # Docker uses .Label "key"; Podman uses index .Labels "key".
    local label_tpl='{{.Label "cage.project"}}'
    [ "$DOCKER" = "podman" ] && label_tpl='{{index .Labels "cage.project"}}'

    local fmt="%-35s %-25s %-32s %s\n"
    printf "$fmt" "NAMES" "STATUS" "IMAGE" "PROJECT"

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

cmd_shell() {
    local project_dir="$1"
    local name
    name="$(container_name "$project_dir")"
    local state
    state="$(container_state "$name")"

    [ "$state" = "running" ] || die "Container $name is not running"
    info "Opening shell in $name"
    $DOCKER exec -it "$name" zsh
}

cmd_restart() {
    local project_dir="$1"
    local name
    name="$(container_name "$project_dir")"
    local state
    state="$(container_state "$name")"

    if [ "$state" = "none" ]; then
        die "No container for $project_dir. Use 'cage start' to create one."
    fi

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
    local state
    state="$(container_state "$name")"
    if [ "$state" != "none" ]; then
        if image_newer_available "$name"; then
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
  CAGE_IMAGE    Override container image (default: ghcr.io/pacificsky/devcontainer-lite:latest)

Seed directory:
  ~/.config/cage/home/    Files copied (no-clobber) into /home/vscode/ on new containers

Port (-p) and volume (-v) flags only apply when creating a new container.
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
        start)
            # Parse -p and -v flags after start subcommand
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
                    *)  die "Unknown flag for start: $1" ;;
                esac
            done
            ensure_docker
            cmd_enter "$project_dir" ${port_flags[@]+"${port_flags[@]}"} ${vol_flags[@]+"${vol_flags[@]}"}
            ;;
        stop)   ensure_docker; cmd_stop "$project_dir" ;;
        rm)     ensure_docker; cmd_rm "$project_dir" ;;
        status) ensure_docker; cmd_status "$project_dir" ;;
        list)   ensure_docker; cmd_list ;;
        shell)  ensure_docker; cmd_shell "$project_dir" ;;
        restart) ensure_docker; cmd_restart "$project_dir" ;;
        obliterate) ensure_docker; cmd_obliterate ;;
        rmconfig) ensure_docker; cmd_rmconfig ;;
        update) ensure_docker; cmd_update ;;
        upgrade) ensure_docker; cmd_upgrade "$project_dir" ;;
        *)      die "Unknown command: $cmd. Run 'cage.sh help' for usage." ;;
    esac
}

main "$@"
