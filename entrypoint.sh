#!/usr/bin/env bash
# entrypoint.sh
# Wraps the Hermes agent entrypoint and uses rclone to keep only the important
# persistent files/folders on a remote/network volume, while Hermes runs with
# those files cached on the container's fast local disk.
#
# Flow:
#   1. Configure an rclone alias remote pointing to $PERSISTENT_DATA_HOME.
#   2. Sync $PERSISTENT_TARGETS_SYNC from remote -> /opt/data (and profiles).
#   3. Hand over to the original Hermes entrypoint as PID 1.
#   4. The s6-overlay persistent-sync service handles periodic local -> remote
#      syncs and a final sync on container shutdown.
set -euo pipefail

# Use the entrypoint log prefix; the shared library will pick this up.
LOG_PREFIX="[entrypoint]"
# shellcheck source=./persistent-sync-lib.sh
source /usr/local/bin/persistent-sync-lib.sh

main() {
    log "Hermes persistent-data wrapper starting"

    # The sync wrapper is optional only when the required env vars are missing;
    # in that case fall through to the original entrypoint unchanged.
    if [[ -z "${PERSISTENT_DATA_HOME:-}" || -z "${PERSISTENT_TARGETS_SYNC:-}" ]]; then
        log "PERSISTENT_DATA_HOME and/or PERSISTENT_TARGETS_SYNC not set; running original entrypoint without sync"
        exec "$ORIGINAL_ENTRYPOINT" "$@"
    fi

    log "PERSISTENT_DATA_HOME=$PERSISTENT_DATA_HOME"
    log "PERSISTENT_TARGETS_SYNC=$PERSISTENT_TARGETS_SYNC"
    log "ADDITIONAL_PROFILES=${ADDITIONAL_PROFILES:-<none>}"
    log "PERSISTENT_DATA_SYNC_FREQ=${PERSISTENT_DATA_SYNC_FREQ:-3600}"

    # This wrapper must run as root so it can configure rclone, create dirs,
    # and chown data before the original Hermes entrypoint drops privileges.
    set_target_uid_gid

    # Ensure both the remote mount point and the local Hermes data directory
    # exist and are writable by the runtime user.
    ensure_dir_owned "$PERSISTENT_DATA_HOME"
    ensure_dir_owned "/opt/data"

    setup_rclone_remote || {
        # If rclone cannot be configured, start Hermes anyway rather than
        # blocking the container entirely.
        log "Rclone setup failed, continuing without persistent sync"
        exec "$ORIGINAL_ENTRYPOINT" "$@"
    }

    # Parse targets with their per-target sync frequencies before syncing.
    local default_freq
    default_freq=$(parse_sync_interval "${PERSISTENT_DATA_SYNC_FREQ:-3600}")
    load_targets "$PERSISTENT_TARGETS_SYNC" "$default_freq"

    # Copy persistent data from network storage to local disk before Hermes starts.
    sync_all_from_remote

    # Exec the original entrypoint so it becomes PID 1 and s6-overlay can run
    # its full supervision tree (including the persistent-sync service).
    log "Handing over to original Hermes entrypoint as PID 1"
    exec "$ORIGINAL_ENTRYPOINT" "$@"
}

main "$@"
