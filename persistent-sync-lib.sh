#!/usr/bin/env bash
# persistent-sync-lib.sh
# Shared helper functions used by the Hermes persistent-data wrapper and the
# s6-overlay sync service. Operates on the rclone alias remote "persistent:"
# (pointing at $PERSISTENT_DATA_HOME) and the local /opt/data directory.
set -euo pipefail

# Path to the image's original dispatch entrypoint.
ORIGINAL_ENTRYPOINT="/opt/hermes/docker/entrypoint-dispatch.sh"

# Rclone config used for the persistent-data remote.
RCLONE_CONFIG_FILE="/tmp/rclone.conf"

# The Hermes runtime user. The upstream image supports remapping this user via
# HERMES_UID/HERMES_GID (and the PUID/PGID aliases).
HERMES_USER="hermes"

# UID/GID that the runtime user will actually have. Set by set_target_uid_gid.
TARGET_UID=""
TARGET_GID=""

# Parsed target list and per-target sync frequencies. Populated by load_sync_targets.
# SYNC_TARGET_LIST is an indexed array of target names; SYNC_TARGET_FREQS is an associative
# array mapping each target to its sync interval in seconds.
declare -a SYNC_TARGET_LIST
declare -A SYNC_TARGET_FREQS

# Allow callers to override the log prefix (entrypoint vs. s6 service).
LOG_PREFIX="${LOG_PREFIX:-[persistent-sync]}"

log() {
    echo "$LOG_PREFIX $*" >&2
}

# Resolve the UID/GID that the hermes runtime will use. Falls back to the
# baked-in hermes UID/GID when no remap variables are provided.
set_target_uid_gid() {
    log "Resolving target UID/GID for runtime user '$HERMES_USER'"
    # If we are not running as root we cannot chown anything, so leave the
    # target UID/GID empty; chown_target will become a no-op.
    if [[ "$(id -u)" -ne 0 ]]; then
        TARGET_UID=""
        TARGET_GID=""
        return
    fi

    # HERMES_UID/HERMES_GID take precedence; fall back to the common NAS-style
    # PUID/PGID aliases if they are not set.
    local uid_var="${HERMES_UID:-${PUID:-}}"
    local gid_var="${HERMES_GID:-${PGID:-}}"

    # Accept only non-root numeric IDs inside the valid Linux UID/GID range.
    if [[ -n "$uid_var" ]] && [[ "$uid_var" =~ ^[0-9]+$ ]] && (( 10#$uid_var >= 1 && 10#$uid_var <= 65534 )); then
        TARGET_UID="$uid_var"
        log "Using remapped UID from environment: $TARGET_UID"
    else
        TARGET_UID=$(id -u "$HERMES_USER")
        log "Using baked-in UID for '$HERMES_USER': $TARGET_UID"
    fi

    if [[ -n "$gid_var" ]] && [[ "$gid_var" =~ ^[0-9]+$ ]] && (( 10#$gid_var >= 1 && 10#$gid_var <= 65534 )); then
        TARGET_GID="$gid_var"
        log "Using remapped GID from environment: $TARGET_GID"
    else
        TARGET_GID=$(id -g "$HERMES_USER")
        log "Using baked-in GID for '$HERMES_USER': $TARGET_GID"
    fi
}

# Change ownership of a path to the target UID/GID. Only runs when we are root.
chown_target() {
    local path="$1"
    local recursive="${2:-0}"

    # Only chown when running as root and when we know the target UID/GID.
    [[ "$(id -u)" -eq 0 ]] || return 0
    [[ -n "$TARGET_UID" && -n "$TARGET_GID" ]] || return 0
    # Skip paths that do not exist (and are not dangling symlinks).
    [[ -e "$path" || -L "$path" ]] || return 0

    if [[ "$recursive" -eq 1 ]]; then
        # -h ensures symlinks themselves are changed, not the files they point to.
        chown -h -R "$TARGET_UID:$TARGET_GID" "$path" 2>/dev/null || log "Warning: failed to chown -R $path"
    else
        chown -h "$TARGET_UID:$TARGET_GID" "$path" 2>/dev/null || log "Warning: failed to chown $path"
    fi
}

# Ensure a directory exists and is owned by the runtime user.
ensure_dir_owned() {
    local dir="$1"
    # Create the directory only if it is missing. mkdir -p is idempotent, but
    # checking first avoids unnecessary metadata writes on network storage.
    if [[ ! -e "$dir" ]]; then
        log "Creating directory: $dir"
        mkdir -p "$dir"
    fi
    # Fix ownership so the Hermes runtime user can read and write here.
    chown_target "$dir"
}

# Create the rclone alias remote pointing at $PERSISTENT_DATA_HOME.
setup_rclone_remote() {
    if [[ -z "${PERSISTENT_DATA_HOME:-}" ]]; then
        log "PERSISTENT_DATA_HOME is not set; skipping rclone setup"
        return 1
    fi

    log "Configuring rclone alias remote 'persistent:' -> $PERSISTENT_DATA_HOME"
    # Write a minimal rclone config that exposes the persistent-data mount as
    # the "persistent:" remote. An alias remote wraps a local path and lets us
    # keep the sync commands symmetrical (persistent: <-> /opt/data).
    cat > "$RCLONE_CONFIG_FILE" <<EOF
[persistent]
type = alias
remote = ${PERSISTENT_DATA_HOME}
EOF
    chmod 600 "$RCLONE_CONFIG_FILE"
    export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"
}

# Parse PERSISTENT_TARGETS_SYNC_FREQ into seconds. Supports plain seconds or a
# suffix of s, m, h, d. Defaults to 3600 seconds (1 hour).
parse_sync_interval() {
    local value="${1:-3600}"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
    elif [[ "$value" =~ ^([0-9]+)s$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^([0-9]+)m$ ]]; then
        echo "$(( ${BASH_REMATCH[1]} * 60 ))"
    elif [[ "$value" =~ ^([0-9]+)h$ ]]; then
        echo "$(( ${BASH_REMATCH[1]} * 3600 ))"
    elif [[ "$value" =~ ^([0-9]+)d$ ]]; then
        echo "$(( ${BASH_REMATCH[1]} * 86400 ))"
    else
        log "Warning: invalid sync interval '$value', using 3600s"
        echo 3600
    fi
}

# Parse the PERSISTENT_TARGETS_SYNC string into SYNC_TARGET_LIST and SYNC_TARGET_FREQS.
# Each item can be either:
#   - "target"                     -> uses default_freq
#   - "(target| freq)"             -> uses the per-target freq
# The pipe separator keeps tuple parsing simple because entries themselves are
# separated by commas. Frequencies accept the same suffixes as parse_sync_interval
# (s/m/h/d).
load_sync_targets() {
    local targets="$1"
    local default_freq="$2"

    SYNC_TARGET_LIST=()
    SYNC_TARGET_FREQS=()

    [[ -z "$targets" ]] && return 0

    local IFS=','
    local raw_list
    read -ra raw_list <<< "$targets"

    for raw_target in "${raw_list[@]}"; do
        local item
        item=$(printf '%s' "$raw_target" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -z "$item" ]] && continue

        local target=""
        local freq=""

        # Detect tuple syntax (target| freq) by matching surrounding parentheses.
        if [[ "$item" == "("*")" ]]; then
            local inner="${item#(}"
            inner="${inner%)}"

            if [[ "$inner" == *"|"* ]]; then
                target="${inner%%|*}"
                freq="${inner#*|}"
                target=$(printf '%s' "$target" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                freq=$(printf '%s' "$freq" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            else
                target="$inner"
                freq="$default_freq"
            fi
        else
            target="$item"
            freq="$default_freq"
        fi

        [[ -z "$target" ]] && continue

        freq=$(parse_sync_interval "$freq")
        SYNC_TARGET_LIST+=("$target")
        SYNC_TARGET_FREQS["$target"]="$freq"
        log "Configured target '$target' with sync interval ${freq}s"
    done
}

# Run rclone sync/copyto from src to dest. Skips when the source does not exist.
# Avoids checksum/hash comparison because it is expensive over network storage.
# Directory targets use 'sync'; file targets use 'copyto' so rclone treats the
# destination as an exact file path instead of a directory.
rclone_run_sync() {
    local src="$1"
    local dest="$2"
    local is_dir="${3:-0}"

    log "Rclone sync: $src -> $dest (is_dir=$is_dir)"
    # Check that the source exists before asking rclone to sync it. This avoids
    # failures on the first run, when the remote path may not have been created yet.
    # lsjson --stat works for both files and directories and does not list contents.
    if ! rclone lsjson --stat "$src" >/dev/null 2>&1; then
        log "Source does not exist yet, skipping sync: $src"
        return 0
    fi

    # --checkers/--transfers can be tuned via RCLONE_CHECKERS/RCLONE_TRANSFERS.
    # We intentionally do NOT use --checksum because computing hashes over many
    # small files on EFS/NFS is slow and expensive; rclone defaults to comparing
    # size and modification time, which is much cheaper.
    local transfers="${RCLONE_TRANSFERS:-32}"
    local checkers="${RCLONE_CHECKERS:-64}"

    # Validate numeric values, falling back to defaults on bad input.
    if ! [[ "$transfers" =~ ^[0-9]+$ ]] || [[ "$transfers" -lt 1 ]]; then
        log "Warning: invalid RCLONE_TRANSFERS value '$transfers', using default 32"
        transfers=32
    fi
    if ! [[ "$checkers" =~ ^[0-9]+$ ]] || [[ "$checkers" -lt 1 ]]; then
        log "Warning: invalid RCLONE_CHECKERS value '$checkers', using default 64"
        checkers=64
    fi

    local rclone_cmd=(rclone)
    if [[ "$is_dir" -eq 1 ]]; then
        rclone_cmd+=(sync "$src" "$dest")
    else
        rclone_cmd+=(copyto "$src" "$dest")
    fi

    if "${rclone_cmd[@]}" \
        --transfers "$transfers" \
        --checkers "$checkers" \
        --stats-one-line \
        --stats 0 \
        --log-level INFO; then
        :
    else
        log "Warning: rclone sync failed: $src -> $dest"
    fi
}

# chown the parent directory of a synced target. This ensures Hermes can create
# additional files in the same directory even when the target itself is a file.
chown_dest_parent() {
    local dest_base="$1"
    local target_name="$2"

    [[ "$(id -u)" -eq 0 ]] || return 0

    # Map the logical destination (local /opt/data path or rclone alias) back to
    # the physical filesystem path that we need to chown.
    local physical_path=""
    if [[ "$dest_base" == /opt/data* ]]; then
        physical_path="$(dirname "${dest_base%/}/${target_name}")"
    elif [[ "$dest_base" == persistent:* ]]; then
        physical_path="$(dirname "${PERSISTENT_DATA_HOME%/}/${target_name}")"
    else
        return 0
    fi

    # Never chown the filesystem root.
    [[ "$physical_path" == "/" ]] && return 0
    # Make sure Hermes can create new files next to a file target.
    chown_target "$physical_path"
}

# chown a destination path after syncing. When the destination is the rclone
# alias remote, the equivalent physical path under $PERSISTENT_DATA_HOME is
# chowned instead.
chown_dest() {
    local dest_base="$1"
    local target_name="$2"
    local is_dir="${3:-0}"

    [[ "$(id -u)" -eq 0 ]] || return 0

    # Resolve the physical path from either a local destination or the alias
    # remote so we can chown the actual file/directory on disk.
    local physical_path=""
    if [[ "$dest_base" == /opt/data* ]]; then
        physical_path="${dest_base%/}/${target_name}"
    elif [[ "$dest_base" == persistent:* ]]; then
        physical_path="${PERSISTENT_DATA_HOME%/}/${target_name}"
    else
        return 0
    fi

    # Directories are recursively chowned because rclone may have copied many
    # files into them; files only need their own ownership fixed.
    if [[ "$is_dir" -eq 1 ]]; then
        chown_target "$physical_path" 1
    else
        chown_target "$physical_path"
    fi
}

# Sync a single target. A trailing slash means the target is a directory.
# .db files are followed by their SQLite -shm and -wal companions.
sync_target() {
    local src_base="$1"
    local dest_base="$2"
    local target="$3"

    # A trailing slash in the target name means we should treat it as a
    # directory and sync its contents, not a single file.
    local is_dir=0
    [[ "$target" == */ ]] && is_dir=1
    local target_name="${target%/}"

    local src="${src_base%/}/${target_name}"
    local dest="${dest_base%/}/${target_name}"

    # Sync the main target and make sure the runtime user owns both the target
    # and its parent directory on the destination side.
    rclone_run_sync "$src" "$dest" "$is_dir"
    chown_dest "$dest_base" "$target_name" "$is_dir"
    chown_dest_parent "$dest_base" "$target_name"

    # SQLite WAL mode keeps two companion files next to the main .db file.
    # Sync them explicitly so the database is not left in an inconsistent state.
    if [[ "$is_dir" -eq 0 && "$target_name" == *.db ]]; then
        local db_base_src="${src%.db}"
        local db_base_dest="${dest%.db}"

        rclone_run_sync "${db_base_src}.db-shm" "${db_base_dest}.db-shm" 0
        chown_dest "$dest_base" "${target_name%.db}.db-shm" 0
        chown_dest_parent "$dest_base" "${target_name%.db}.db-shm"

        rclone_run_sync "${db_base_src}.db-wal" "${db_base_dest}.db-wal" 0
        chown_dest "$dest_base" "${target_name%.db}.db-wal" 0
        chown_dest_parent "$dest_base" "${target_name%.db}.db-wal"
    fi
}

# (Kept for compatibility; new code uses SYNC_TARGET_LIST directly.)
sync_all_targets() {
    local src_base="$1"
    local dest_base="$2"
    local targets="$3"

    # Nothing to do when no targets are configured.
    [[ -z "$targets" ]] && return 0

    # Split the comma-separated list and allow whitespace around commas.
    local IFS=','
    local target_list
    read -ra target_list <<< "$targets"

    for raw_target in "${target_list[@]}"; do
        local target
        target=$(printf '%s' "$raw_target" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -z "$target" ]] && continue
        sync_target "$src_base" "$dest_base" "$target"
    done
}

# Sync a single target from remote to local, including all configured profiles.
sync_target_from_remote() {
    local target="$1"

    sync_target "persistent:" "/opt/data" "$target"

    if [[ -n "${ADDITIONAL_PROFILES:-}" ]]; then
        ensure_dir_owned "/opt/data/profiles"
        ensure_dir_owned "${PERSISTENT_DATA_HOME}/profiles"

        local IFS=','
        local profile_list
        read -ra profile_list <<< "$ADDITIONAL_PROFILES"

        for raw_profile in "${profile_list[@]}"; do
            local profile
            profile=$(printf '%s' "$raw_profile" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            [[ -z "$profile" ]] && continue
            sync_target \
                "persistent:profiles/${profile}" \
                "/opt/data/profiles/${profile}" \
                "$target"
        done
    fi
}

# Sync a single target from local to remote, including all configured profiles.
sync_target_to_remote() {
    local target="$1"

    sync_target "/opt/data" "persistent:" "$target"

    if [[ -n "${ADDITIONAL_PROFILES:-}" ]]; then
        ensure_dir_owned "/opt/data/profiles"
        ensure_dir_owned "${PERSISTENT_DATA_HOME}/profiles"

        local IFS=','
        local profile_list
        read -ra profile_list <<< "$ADDITIONAL_PROFILES"

        for raw_profile in "${profile_list[@]}"; do
            local profile
            profile=$(printf '%s' "$raw_profile" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            [[ -z "$profile" ]] && continue
            sync_target \
                "/opt/data/profiles/${profile}" \
                "persistent:profiles/${profile}" \
                "$target"
        done
    fi
}

# Initial download: remote -> local.
sync_all_from_remote() {
    log "Starting initial sync: remote -> local"
    for target in "${SYNC_TARGET_LIST[@]}"; do
        log "Syncing target '$target' from persistent: to /opt/data"
        sync_target_from_remote "$target"
    done
    log "Initial sync finished"
}

# Periodic/final upload: local -> remote.
sync_all_to_remote() {
    log "Starting sync: local -> remote"
    for target in "${SYNC_TARGET_LIST[@]}"; do
        log "Syncing target '$target' from /opt/data to persistent:"
        sync_target_to_remote "$target"
    done
    log "Sync to remote finished"
}


########################################################################################


# Parsed list of targets that should be symlinked directly to the persistent
# volume instead of copied via rclone. Populated by load_link_targets().
declare -a LINK_TARGET_LIST

# Parse a simple comma-separated list of targets for symlinking. Trailing
# slashes are preserved so callers can detect directory targets.
load_link_targets() {
    local targets="$1"

    LINK_TARGET_LIST=()

    [[ -z "$targets" ]] && return 0

    local IFS=','
    local raw_list
    read -ra raw_list <<< "$targets"

    for raw_target in "${raw_list[@]}"; do
        local target
        target=$(printf '%s' "$raw_target" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -z "$target" ]] && continue

        LINK_TARGET_LIST+=("$target")
        log "Configured link target '$target'"
    done
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

# Symlink a single target from $source_base to $dest_base.
# Directory targets use ensure_dir_owned on the source side; file targets only
# ensure their parent directory exists.
setup_persistent_links() {
    local source_base="$1"
    local dest_base="$2"
    local target="$3"

    # A trailing slash in the target name means we should treat it as a
    # directory and link its contents, not a single file.
    local is_dir=0
    [[ "$target" == */ ]] && is_dir=1
    local target_name="${target%/}"

    local src="${source_base%/}/${target_name}"
    local dest="${dest_base%/}/${target_name}"

    # Ensure the source root exists and is writable by the runtime user.
    if [[ ! -e "$source_base" ]]; then
        mkdir -p "$source_base"
    fi
    chown_target "$source_base"

    if [[ "$is_dir" -eq 1 ]]; then
        # Ensure the source directory exists on the persistent volume and is
        # owned by the runtime user, then link it into the container.
        ensure_dir_owned "$src"
        chown_target "$src" 1
        ensure_symlink "$src" "$dest" || return 0
    else
        # Ensure the source file's parent directory exists and is writable by
        # the runtime user. The file itself will be created by the application
        # later if it does not exist yet.
        ensure_dir_owned "$(dirname "$src")"
        if [[ -e "$src" ]]; then
            chown_target "$src"
        fi
        ensure_symlink "$src" "$dest" || return 0
    fi
}

# Symlink one target for the default profile and all configured profiles.
link_target_all_profiles() {
    local target="$1"

    setup_persistent_links "$PERSISTENT_DATA_HOME" "/opt/data" "$target"

    if [[ -n "${ADDITIONAL_PROFILES:-}" ]]; then
        ensure_dir_owned "${PERSISTENT_DATA_HOME}/profiles"
        ensure_dir_owned "/opt/data/profiles"

        local IFS=','
        local profile_list
        read -ra profile_list <<< "$ADDITIONAL_PROFILES"

        for raw_profile in "${profile_list[@]}"; do
            local profile
            profile=$(printf '%s' "$raw_profile" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            [[ -z "$profile" ]] && continue
            setup_persistent_links \
                "${PERSISTENT_DATA_HOME}/profiles/${profile}" \
                "/opt/data/profiles/${profile}" \
                "$target"
        done
    fi
}

# Set up symlinks for all targets configured in PERSISTENT_TARGETS_LINK.
link_all_targets() {
    log "Setting up persistent symlinks"
    for target in "${LINK_TARGET_LIST[@]}"; do
        log "Linking target '$target' into /opt/data from $PERSISTENT_DATA_HOME"
        link_target_all_profiles "$target"
    done
    log "Persistent symlinks finished"
}

# If a target appears in both the sync and link lists, prefer the link and
# remove it from the sync list. This avoids rclone writing through a symlink.
dedupe_sync_and_link_targets() {
    if [[ ${#LINK_TARGET_LIST[@]} -eq 0 ]]; then
        return 0
    fi

    local deduped=()
    for sync_target in "${SYNC_TARGET_LIST[@]}"; do
        local found=0
        for link_target in "${LINK_TARGET_LIST[@]}"; do
            if [[ "$sync_target" == "$link_target" ]]; then
                log "Target '$sync_target' is configured for both sync and link; using link only"
                found=1
                break
            fi
        done
        if [[ "$found" -eq 0 ]]; then
            deduped+=("$sync_target")
        fi
    done
    SYNC_TARGET_LIST=("${deduped[@]}")
}
