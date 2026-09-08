#!/usr/bin/env bash
# entrypoint.sh
# Wraps the Hermes agent entrypoint and uses rclone and/or symlinks to keep
# important persistent files/folders on a remote/network volume. Synced targets
# are cached on the container's fast local disk, while linked targets are read
# and written directly on the persistent volume.
#
# Flow:
#   1. Symlink $PERSISTENT_TARGETS_LINK directly from $PERSISTENT_DATA_HOME
#      into /opt/data (and profiles).
#   2. Configure an rclone alias remote pointing to $PERSISTENT_DATA_HOME.
#   3. Sync $PERSISTENT_TARGETS_SYNC from remote -> /opt/data (and profiles).
#   4. Hand over to the original Hermes entrypoint as PID 1.
#   5. The s6-overlay persistent-sync service handles periodic local -> remote
#      syncs and a final sync on container shutdown.
set -euo pipefail

# Use the entrypoint log prefix; the shared library will pick this up.
LOG_PREFIX="[entrypoint]"
# shellcheck source=./persistent-sync-lib.sh
source /usr/local/bin/persistent-sync-lib.sh

main() {
    log "Hermes persistent-data wrapper starting"

    # The wrapper is optional when no persistent targets are configured; in that
    # case fall through to the original entrypoint unchanged.
    if [[ -z "${PERSISTENT_DATA_HOME:-}" ]]; then
        log "PERSISTENT_DATA_HOME is not set; running original entrypoint without sync/link"
        exec "$ORIGINAL_ENTRYPOINT" "$@"
    fi

    if [[ -z "${PERSISTENT_TARGETS_SYNC:-}" && -z "${PERSISTENT_TARGETS_LINK:-}" ]]; then
        log "No persistent targets configured; running original entrypoint without sync/link"
        exec "$ORIGINAL_ENTRYPOINT" "$@"
    fi

    log "PERSISTENT_DATA_HOME=$PERSISTENT_DATA_HOME"
    log "PERSISTENT_TARGETS_SYNC=${PERSISTENT_TARGETS_SYNC:-<none>}"
    log "PERSISTENT_TARGETS_LINK=${PERSISTENT_TARGETS_LINK:-<none>}"
    log "ADDITIONAL_PROFILES=${ADDITIONAL_PROFILES:-<none>}"
    log "PERSISTENT_TARGETS_SYNC_FREQ=${PERSISTENT_TARGETS_SYNC_FREQ:-3600}"

    # This wrapper must run as root so it can configure rclone, create dirs,
    # and chown data before the original Hermes entrypoint drops privileges.
    set_target_uid_gid

    # Leafwiki is only enabled when its data directory is explicitly configured.
    # When a persistent wiki home is also set, link leafwiki's root there so the
    # wiki files are read/written directly on the persistent volume.
    if [[ -n "${LEAFWIKI_DATA_DIR:-}" && -n "${PERSISTENT_WIKI_HOME:-}" ]]; then
        log "LEAFWIKI_DATA_DIR=$LEAFWIKI_DATA_DIR"
        log "PERSISTENT_WIKI_HOME=$PERSISTENT_WIKI_HOME"
        log "Linking leafwiki root to persistent wiki home"
        # Link them so leafwiki can read/write wiki directly on persistent volume
        ensure_symlink "$PERSISTENT_WIKI_HOME" "$LEAFWIKI_DATA_DIR/root"
    fi

    # Ensure both the remote mount point and the local Hermes data directory
    # exist and are writable by the runtime user.
    ensure_dir_owned "$PERSISTENT_DATA_HOME"
    ensure_dir_owned "/opt/data"

    # Set up rclone only when sync targets are requested.
    local has_sync=0
    if [[ -n "${PERSISTENT_TARGETS_SYNC:-}" ]]; then
        if setup_rclone_remote; then
            has_sync=1
        else
            log "Rclone setup failed; sync targets will be ignored"
            has_sync=0
        fi
    fi

    local default_freq
    default_freq=$(parse_sync_interval "${PERSISTENT_TARGETS_SYNC_FREQ:-3600}")

    # Parse link targets first; if a target is configured for both sync and
    # link, the link takes precedence.
    if [[ -n "${PERSISTENT_TARGETS_LINK:-}" ]]; then
        load_link_targets "$PERSISTENT_TARGETS_LINK"
    fi

    if [[ "$has_sync" -eq 1 ]]; then
        load_sync_targets "$PERSISTENT_TARGETS_SYNC" "$default_freq"
    fi

    dedupe_sync_and_link_targets

    # Create symlinks for any targets that should be wired directly into the
    # persistent volume.
    if [[ ${#LINK_TARGET_LIST[@]} -gt 0 ]]; then
        link_all_targets
    fi

    # Copy remaining sync targets from the persistent volume to local disk.
    if [[ ${#SYNC_TARGET_LIST[@]} -gt 0 ]]; then
        sync_all_from_remote
    fi

    # Exec the original entrypoint so it becomes PID 1 and s6-overlay can run
    # its full supervision tree (including the persistent-sync service).
    log "Handing over to original Hermes entrypoint as PID 1"
    exec "$ORIGINAL_ENTRYPOINT" "$@"
}

main "$@"
