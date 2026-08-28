#!/usr/bin/env bash
# Copy the cage-home (and optionally cage-brew) Docker volume from one colima
# VM's daemon to another — typically from the default colima VM, where plain
# `cage start` used to keep /home/vscode, into the dedicated 'cage' VM that
# `cage dstart` provisions.  Named volumes are per-daemon, so the cage VM
# starts with a fresh home; this script carries the old one over.
#
# Run on the Mac with BOTH VMs running.  Nothing on the host is touched.
#
# Usage:
#   scripts/migrate-home-to-cage-vm.sh [options]
#
# Options:
#   --from HOST      source DOCKER_HOST   (default: unix://$HOME/.colima/default/docker.sock)
#   --to HOST        target DOCKER_HOST   (default: unix://$HOME/.colima/cage/docker.sock)
#   --claude-only    copy only Claude Code / Codex state instead of all of /home/vscode
#   --brew           also copy the cage-brew volume (/home/linuxbrew)
#   --exclude PAT    tar --exclude pattern, repeatable (full mode only; e.g. --exclude ./.cache)
#   --force          proceed even if a container is using a volume on either side
#   -y, --yes        don't prompt for confirmation
#   -n, --dry-run    show what would be copied (tar listing) without writing
#
# Semantics: an overlay, not a mirror.  Files from the source overwrite the
# same paths on the target; files that exist only on the target are kept.
# Ownership is carried numerically (both VMs run the same image, so
# vscode is the same uid/gid on both sides).

set -euo pipefail

HOME_VOL="cage-home"
BREW_VOL="cage-brew"
HELPER_IMAGE="alpine:3"

SRC_HOST="unix://$HOME/.colima/default/docker.sock"
DST_HOST="unix://$HOME/.colima/cage/docker.sock"
CLAUDE_ONLY=0
COPY_BREW=0
FORCE=0
YES=0
DRY_RUN=0
EXCLUDES=()

# Paths (relative to /home/vscode) that make up Claude Code / Codex state.
CLAUDE_PATHS=(
    ./.claude            # settings, projects/memory, sessions, todos, plugins, skills, credentials
    ./.claude.json       # account, onboarding, MCP servers, per-project trust
    ./.claude.json.backup
    ./.codex             # Codex CLI config/auth/sessions
)

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "$*" >&2; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --from)        [ $# -ge 2 ] || die "--from needs a value"; SRC_HOST="$2"; shift 2 ;;
        --to)          [ $# -ge 2 ] || die "--to needs a value";   DST_HOST="$2"; shift 2 ;;
        --claude-only) CLAUDE_ONLY=1; shift ;;
        --brew)        COPY_BREW=1; shift ;;
        --exclude)     [ $# -ge 2 ] || die "--exclude needs a value"; EXCLUDES+=("$2"); shift 2 ;;
        --force)       FORCE=1; shift ;;
        -y|--yes)      YES=1; shift ;;
        -n|--dry-run)  DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (see --help)" ;;
    esac
done

[ "$CLAUDE_ONLY" = 1 ] && [ ${#EXCLUDES[@]} -gt 0 ] && die "--exclude only applies to a full copy, not --claude-only"

command -v docker >/dev/null 2>&1 || die "docker CLI not found (brew install docker)"

src() { DOCKER_HOST="$SRC_HOST" docker "$@"; }
dst() { DOCKER_HOST="$DST_HOST" docker "$@"; }

# --- Preflight -------------------------------------------------------------

check_daemon() {
    local label="$1" host="$2" fn="$3"
    case "$host" in
        unix://*) [ -S "${host#unix://}" ] || die "$label daemon socket ${host#unix://} does not exist.
       Is that VM running?  (colima list; colima start [--profile cage])" ;;
    esac
    "$fn" info >/dev/null 2>&1 || die "$label daemon at $host is not responding."
}

check_daemon "Source" "$SRC_HOST" src
check_daemon "Target" "$DST_HOST" dst

src_id="$(src info --format '{{.ID}}' 2>/dev/null || true)"
dst_id="$(dst info --format '{{.ID}}' 2>/dev/null || true)"
[ -n "$src_id" ] && [ "$src_id" = "$dst_id" ] && die "source and target are the same daemon ($SRC_HOST vs $DST_HOST)"

volumes=("$HOME_VOL")
[ "$COPY_BREW" = 1 ] && volumes+=("$BREW_VOL")

for vol in "${volumes[@]}"; do
    src volume inspect "$vol" >/dev/null 2>&1 \
        || die "volume '$vol' does not exist on the source daemon ($SRC_HOST) — nothing to migrate."
    # The target volume should already have been initialised from the image
    # (image dotfiles + ~/.config/cage/home seed) by a first `cage dstart`.
    # Populating an empty volume ourselves would suppress that copy-on-first-
    # use, which is fine for a full copy but leaves a --claude-only home
    # without its baseline dotfiles — so insist on it in that mode.
    if ! dst volume inspect "$vol" >/dev/null 2>&1; then
        if [ "$CLAUDE_ONLY" = 1 ] || [ "$DRY_RUN" = 1 ]; then
            die "volume '$vol' does not exist on the target daemon ($DST_HOST).
       Run 'cage dstart' once (then exit) so the cage VM's home is initialised, and retry."
        fi
        info "Target volume '$vol' does not exist; it will be created."
    fi
done

# Refuse to copy from/into a volume with a live writer unless --force.
busy=""
for vol in "${volumes[@]}"; do
    s="$(src ps -q --filter "volume=$vol" | tr '\n' ' ')"
    d="$(dst ps -q --filter "volume=$vol" | tr '\n' ' ')"
    [ -n "${s// /}" ] && busy+="  source: containers using $vol: $s"$'\n'
    [ -n "${d// /}" ] && busy+="  target: containers using $vol: $d"$'\n'
done
if [ -n "$busy" ]; then
    if [ "$FORCE" = 1 ]; then
        info "Warning: copying while containers are running (--force):"; info "$busy"
    else
        die "containers are running against the volumes being copied:
$busy       Stop them first ('cage stop' in each project, or docker stop), or pass --force."
    fi
fi

# Make sure the helper image is present on both sides before we start
# streaming — a pull mid-pipe would show up as a confusing tar error.
for fn in src dst; do
    if ! $fn image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
        info "Pulling $HELPER_IMAGE on $fn daemon..."
        $fn pull -q "$HELPER_IMAGE" >/dev/null
    fi
done

# --- Plan ------------------------------------------------------------------

vol_size() { "$1" run --rm -v "$2:/v:ro" "$HELPER_IMAGE" du -sh /v 2>/dev/null | cut -f1; }

info ""
info "Source: $SRC_HOST"
info "Target: $DST_HOST"
for vol in "${volumes[@]}"; do
    info "  $vol  (source size: $(vol_size src "$vol"))"
done
if [ "$CLAUDE_ONLY" = 1 ]; then
    info "Mode:   Claude/Codex state only: ${CLAUDE_PATHS[*]}"
else
    info "Mode:   full copy of the volume(s)"
    [ ${#EXCLUDES[@]} -gt 0 ] && info "Exclude: ${EXCLUDES[*]}"
fi
info "Files on the target with the same path are overwritten; other target files are kept."
info ""

if [ "$DRY_RUN" = 0 ] && [ "$YES" = 0 ]; then
    read -r -p "Proceed? [y/N] " answer
    case "$answer" in y|Y|yes|YES) ;; *) info "Aborted."; exit 1 ;; esac
fi

# --- Copy ------------------------------------------------------------------

copy_volume() {
    local vol="$1"
    local -a create_args=(-C /from --numeric-owner -cf -)
    local -a paths=()

    if [ "$CLAUDE_ONLY" = 1 ] && [ "$vol" = "$HOME_VOL" ]; then
        # Only include paths that exist; busybox tar errors on missing members.
        local p
        for p in "${CLAUDE_PATHS[@]}"; do
            if src run --rm -v "$vol:/from:ro" "$HELPER_IMAGE" test -e "/from/$p"; then
                paths+=("$p")
            fi
        done
        [ ${#paths[@]} -gt 0 ] || die "none of ${CLAUDE_PATHS[*]} exist in $vol on the source"
    else
        local e
        for e in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do create_args+=(--exclude "$e"); done
        paths=(.)
    fi

    info "Copying $vol ..."
    if [ "$DRY_RUN" = 1 ]; then
        src run --rm -v "$vol:/from:ro" "$HELPER_IMAGE" tar "${create_args[@]}" "${paths[@]}" \
            | dst run --rm -i "$HELPER_IMAGE" tar --numeric-owner -tvf -
        return
    fi

    # Stream tar out of the source daemon and straight into the target daemon.
    # Both helper containers run as root so ownership/permissions/mtimes
    # survive; --numeric-owner keeps vscode's uid rather than name-mapping
    # through alpine's passwd.
    src run --rm -v "$vol:/from:ro" "$HELPER_IMAGE" tar "${create_args[@]}" "${paths[@]}" \
        | dst run --rm -i -v "$vol:/to" "$HELPER_IMAGE" tar -C /to --numeric-owner -xpf -
    info "  done: $vol ($(vol_size dst "$vol") on target)"
}

for vol in "${volumes[@]}"; do
    copy_volume "$vol"
done

info ""
[ "$DRY_RUN" = 1 ] && { info "Dry run: nothing was written."; exit 0; }
info "Migration complete.  In a project, run 'cage dstart' to use the cage VM;"
info "the old volume on the source daemon was left untouched."
