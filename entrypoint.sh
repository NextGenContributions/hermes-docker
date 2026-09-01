#!/usr/bin/env bash
# entrypoint.sh
# Wraps the Hermes agent's original entrypoint so that important persistent files and
# directories can be kept outside the container and symlinked into /opt/data
# (or /opt/data/profiles/<profile>) at startup.
set -euo pipefail

# Path to the image's original dispatch entrypoint that we ultimately exec.
ORIGINAL_ENTRYPOINT="/opt/hermes/docker/entrypoint-dispatch.sh"

# The image runs a privileged bootstrap as root and then drops to this user via
# s6-setuidgid inside main-wrapper.sh / the s6 service run scripts. Persistent
# storage must therefore be writable by this user after any UID/GID remap.
HERMES_USER="hermes"

# Numeric UID/GID that files and directories under PERSISTENT_DATA_HOME should
# be owned by. Populated by set_target_uid_gid() when the container starts as root.
TARGET_UID=""
TARGET_GID=""

log() {
    echo "[entrypoint] $*" >&2
}

# Resolve the UID/GID that the hermes runtime will actually use. The upstream
# image supports remapping the hermes user via HERMES_UID/HERMES_GID (and the
# PUID/PGID aliases used by NAS containers). If those variables are set to valid
# numeric values we match them so the persistent volume ends up owned by the
# same UID/GID the runtime will drop to. Otherwise we fall back to the baked-in
# hermes UID/GID (10000:10000).
set_target_uid_gid() {
    if [[ "$(id -u)" -ne 0 ]]; then
        TARGET_UID=""
        TARGET_GID=""
        return
    fi

    local uid_var="${HERMES_UID:-${PUID:-}}"
    local gid_var="${HERMES_GID:-${PGID:-}}"

    if [[ -n "$uid_var" ]] && [[ "$uid_var" =~ ^[0-9]+$ ]] && (( 10#$uid_var >= 1 && 10#$uid_var <= 65534 )); then
        TARGET_UID="$uid_var"
    else
        TARGET_UID=$(id -u "$HERMES_USER")
    fi

    if [[ -n "$gid_var" ]] && [[ "$gid_var" =~ ^[0-9]+$ ]] && (( 10#$gid_var >= 1 && 10#$gid_var <= 65534 )); then
        TARGET_GID="$gid_var"
    else
        TARGET_GID=$(id -g "$HERMES_USER")
    fi
}

# Change ownership of a path to the target UID/GID. Only runs when we are root.
# Directories are optionally recursively chowned because their contents may have
# been created with the wrong owner during a previous start.
chown_target() {
    local path="$1"
    local recursive="${2:-0}"

    [[ "$(id -u)" -eq 0 ]] || return 0
    [[ -n "$TARGET_UID" && -n "$TARGET_GID" ]] || return 0
    [[ -e "$path" || -L "$path" ]] || return 0

    if [[ "$recursive" -eq 1 ]]; then
        # -h makes chown follow the symlink itself, not the target it points to.
        chown -h -R "$TARGET_UID:$TARGET_GID" "$path" 2>/dev/null || log "Warning: failed to chown -R $path"
    else
        # -h ensures symbolic links are changed, not the files they point to.
        chown -h "$TARGET_UID:$TARGET_GID" "$path" 2>/dev/null || log "Warning: failed to chown $path"
    fi
}

# Create a symlink at $dest pointing to $src.
# - Creates the parent directory of $dest if needed and makes sure it is owned
#   by the target user so the Hermes runtime can write other files there.
# - If $dest is already a symlink, removes it first so we can update the link.
# - If $dest exists as a real file or directory, we warn and skip to avoid
#   accidentally overwriting data that may already be inside the container.
ensure_symlink() {
    local src="$1"
    local dest="$2"

    mkdir -p "$(dirname "$dest")"
    chown_target "$(dirname "$dest")"

    if [[ -L "$dest" ]]; then
        rm "$dest"
    elif [[ -e "$dest" ]]; then
        log "Warning: destination exists and is not a symlink: $dest"
        return 1
    fi

    # If the source file does not exist yet, create an empty placeholder on the
    # persistent volume. This avoids dangling symlinks and ensures the runtime
    # user can write the real file through the symlink later.
    if [[ ! -e "$src" && ! -L "$src" ]]; then
        touch "$src"
        chown_target "$src"
    fi

    ln -s "$src" "$dest"
    chown_target "$dest"
}

# Symlink a comma-separated list of targets from $source_base to $dest_base.
# This is used both for the default agent profile and for additional profiles.
setup_persistent_targets() {
    local source_base="$1"
    local dest_base="$2"
    local targets="$3"

    # Nothing to do if no targets were specified.
    [[ -z "$targets" ]] && return 0

    # Ensure the source root exists and is writable by the runtime user.
    if [[ ! -e "$source_base" ]]; then
        mkdir -p "$source_base"
    fi
    chown_target "$source_base"

    # Split the comma-separated list into an array.
    local IFS=','
    local target_list
    read -ra target_list <<< "$targets"

    for raw_target in "${target_list[@]}"; do
        # Allow whitespace around commas for readability in the env var.
        local target
        target=$(printf '%s' "$raw_target" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -z "$target" ]] && continue

        # A trailing slash indicates the target is a directory.
        local is_dir=0
        [[ "$target" == */ ]] && is_dir=1

        # Strip trailing slash so paths are constructed consistently.
        target="${target%/}"

        local src="${source_base}/${target}"
        local dest="${dest_base}/${target}"

        if [[ "$is_dir" -eq 1 ]]; then
            # Ensure the source directory exists on the host mount and is owned
            # by the runtime user, then link it into the container's expected
            # location.
            mkdir -p "$src"
            chown_target "$src" 1
            ensure_symlink "$src" "$dest" || continue
        else
            # Ensure the source file's parent directory exists and is writable
            # by the runtime user. The file itself will be created by the
            # application later if it does not exist yet.
            mkdir -p "$(dirname "$src")"
            chown_target "$(dirname "$src")"
            if [[ -e "$src" ]]; then
                chown_target "$src"
            fi
            ensure_symlink "$src" "$dest" || continue

            # SQLite databases are often accompanied by -shm and -wal files.
            # If the target is a .db file, symlink those companion files too.
            # if [[ "$target" == *.db ]]; then
            #     local db_base="${src%.db}"
            #     local db_dest_base="${dest%.db}"
            #     for ext in db-shm db-wal; do
            #         ensure_symlink "${db_base}.${ext}" "${db_dest_base}.${ext}"
            #     done
            # fi
        fi
    done
}

main() {
    # This script must run as root so it can create directories on the
    # persistent volume and adjust ownership before the original Hermes
    # entrypoint drops privileges. main-wrapper.sh will reject arbitrary
    # --user UIDs, but supports HERMES_UID/HERMES_GID/PUID/PGID remapping.
    set_target_uid_gid

    # Default profile: link targets from $PERSISTENT_DATA_HOME into /opt/data.
    if [[ -n "${PERSISTENT_DATA_HOME:-}" && -n "${PERSISTENT_TARGETS:-}" ]]; then
        setup_persistent_targets "$PERSISTENT_DATA_HOME" "/opt/data" "$PERSISTENT_TARGETS"
    fi

    # Additional named profiles: repeat the same linking under
    # /opt/data/profiles/<profile> for every profile listed in
    # $ADDITIONAL_PROFILES.
    if [[ -n "${PERSISTENT_DATA_HOME:-}" && -n "${ADDITIONAL_PROFILES:-}" ]]; then
        local IFS=','
        local profile_list
        read -ra profile_list <<< "$ADDITIONAL_PROFILES"

        # Create profiles dirs and ensure they are owned by the target user.
        SRC_PROFILES_DIR="${PERSISTENT_DATA_HOME}/profiles"
        mkdir -p "$SRC_PROFILES_DIR"
        chown_target "$SRC_PROFILES_DIR"
        DEST_PROFILES_DIR="/opt/data/profiles"
        mkdir -p "$DEST_PROFILES_DIR"
        chown_target "$DEST_PROFILES_DIR"

        for raw_profile in "${profile_list[@]}"; do
            local profile
            profile=$(printf '%s' "$raw_profile" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            [[ -z "$profile" ]] && continue

            setup_persistent_targets \
                "${SRC_PROFILES_DIR}/${profile}" \
                "${DEST_PROFILES_DIR}/${profile}" \
                "$PERSISTENT_TARGETS"
        done
    fi

    # Hand off to the original Hermes entrypoint, replacing this shell process.
    exec "$ORIGINAL_ENTRYPOINT" "$@"
}

main "$@"
