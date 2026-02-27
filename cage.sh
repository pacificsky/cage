#!/usr/bin/env bash
set -euo pipefail

VERSION="0.2.0"
IMAGE="${CAGE_IMAGE:-ghcr.io/pacificsky/devcontainer-lite:latest}"
HOME_VOL="cage-home"

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
    state="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" || {
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
    docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker (or colima) first."
}

image_newer_available() {
    local name="$1"
    local container_image_id
    container_image_id="$(docker inspect -f '{{.Image}}' "$name" 2>/dev/null)" || return 1
    local latest_image_id
    latest_image_id="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null)" || return 1
    [ "$container_image_id" != "$latest_image_id" ]
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
                info "A newer image is available. Run 'cage.sh update' to upgrade."
            fi
            info "Re-attaching to $name"
            docker attach "$name"
            ;;
        stopped)
            if [ ${#port_flags[@]} -gt 0 ]; then
                info "Container already exists — ignoring -p flags. Use 'cage.sh rm' to recreate with new ports."
            fi
            if image_newer_available "$name"; then
                info "A newer image is available. Run 'cage.sh update' to upgrade."
            fi
            info "Restarting $name"
            docker start -ai "$name"
            ;;
        none)
            if [[ "$IMAGE" == */* ]]; then
                info "Pulling latest image..."
                docker pull "$IMAGE"
            fi
            info "Creating $name"

            local -a mount_args=(
                -v "${project_dir}:${project_dir}"
                -v "${HOME_VOL}:/home/vscode"
            )

            # Forward the host SSH agent so keys don't prompt for passphrases.
            # Docker Desktop for Mac exposes the agent at a magic VM path.
            local -a ssh_agent_args=()
            if [[ -S "/run/host-services/ssh-auth.sock" ]] 2>/dev/null || \
               docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi "docker desktop"; then
                ssh_agent_args=(
                    -v /run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock
                    -e SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock
                )
            elif [[ -n "${SSH_AUTH_SOCK:-}" ]] && [[ -S "$SSH_AUTH_SOCK" ]]; then
                ssh_agent_args=(
                    -v "${SSH_AUTH_SOCK}:/tmp/ssh-agent.sock"
                    -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
                )
            fi

            docker run -it \
                --name "$name" \
                --hostname "$name" \
                --workdir "$project_dir" \
                ${port_flags[@]+"${port_flags[@]}"} \
                "${mount_args[@]}" \
                ${ssh_agent_args[@]+"${ssh_agent_args[@]}"} \
                -l "cage.project=${project_dir}" \
                "$IMAGE"
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
            docker stop "$name"
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
            docker rm -f "$name"
            ;;
        stopped)
            info "Removing $name"
            docker rm "$name"
            ;;
        none)
            die "No container for $project_dir"
            ;;
    esac
}

cmd_rmconfig() {
    local ids
    ids="$(docker ps -a --filter "label=cage.project" -q)" || true
    if [ -n "$ids" ]; then
        local running
        running="$(docker ps --filter "label=cage.project" -q)" || true
        if [ -n "$running" ]; then
            info "Stopping running cage containers"
            echo "$running" | xargs docker stop
        fi
    fi
    if docker volume inspect "$HOME_VOL" >/dev/null 2>&1; then
        info "Removing shared home volume $HOME_VOL"
        docker volume rm "$HOME_VOL"
    else
        info "No shared home volume to remove"
    fi
}

cmd_obliterate() {
    local ids
    ids="$(docker ps -a --filter "label=cage.project" -q)" || true
    if [ -n "$ids" ]; then
        info "Removing all cage containers"
        echo "$ids" | xargs docker rm -f
    else
        info "No cage containers to remove"
    fi
    if docker volume inspect "$HOME_VOL" >/dev/null 2>&1; then
        info "Removing shared home volume $HOME_VOL"
        docker volume rm "$HOME_VOL"
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
        ports="$(docker port "$name" 2>/dev/null)" || true
        if [ -n "$ports" ]; then
            echo "Ports:"
            echo "$ports" | sed 's/^/  /'
        else
            echo "Ports:     (none)"
        fi
    fi
}

cmd_list() {
    local format='table {{.Names}}\t{{.Status}}\t{{.Label "cage.project"}}'
    docker ps -a --filter "label=cage.project" --format "$format"
}

cmd_shell() {
    local project_dir="$1"
    local name
    name="$(container_name "$project_dir")"
    local state
    state="$(container_state "$name")"

    [ "$state" = "running" ] || die "Container $name is not running"
    info "Opening shell in $name"
    docker exec -it "$name" zsh
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

    docker rm -f "$name" >/dev/null 2>&1 || true
    cmd_enter "$project_dir"
}

cmd_update() {
    local project_dir="$1"
    local name
    name="$(container_name "$project_dir")"

    if [[ "$IMAGE" != */* ]]; then
        die "Cannot update local image '$IMAGE'. Pull or build it manually."
    fi

    info "Pulling latest image..."
    docker pull "$IMAGE"

    local state
    state="$(container_state "$name")"
    if [ "$state" != "none" ]; then
        if image_newer_available "$name"; then
            info "Removing old container $name"
            docker rm -f "$name" >/dev/null 2>&1 || true
            info "Starting fresh container with new image"
            cmd_enter "$project_dir"
        else
            info "Container is already on the latest image."
        fi
    else
        info "No existing container. Use 'cage.sh start' to create one."
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
  restart   Remove and recreate container (volumes preserved)
  obliterate Remove all cage containers and shared home volume
  rmconfig  Stop all containers and remove shared home volume
  update    Pull latest image and recreate container
  help      Show this help

Environment:
  CAGE_IMAGE    Override container image (default: ghcr.io/pacificsky/devcontainer-lite:latest)

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
        update) ensure_docker; cmd_update "$project_dir" ;;
        *)      die "Unknown command: $cmd. Run 'cage.sh help' for usage." ;;
    esac
}

main "$@"
