#!/command/with-contenv bash
# persistent-sync.sh
# s6-overlay longrun service script for the Hermes persistent-data sync.
# Can also be invoked with the "once" argument for one-shot syncs (used by the
# service finish script).
set -euo pipefail

# Use a distinct log prefix so service logs are easy to identify.
LOG_PREFIX="[persistent-sync]"
# shellcheck source=./persistent-sync-lib.sh
source /usr/local/bin/persistent-sync-lib.sh

main() {
    local mode="${1:-loop}"

    set_target_uid_gid
    setup_rclone_remote || exit 1

    local default_freq
    default_freq=$(parse_sync_interval "${PERSISTENT_DATA_SYNC_FREQ:-3600}")
    load_targets "$PERSISTENT_TARGETS" "$default_freq"

    case "$mode" in
        loop)
            log "Starting per-target periodic sync loop"

            # Exit cleanly when s6 sends SIGTERM to this service.
            trap 'log "Received SIGTERM, exiting periodic sync loop"; exit 0' TERM

            # Track the next scheduled sync time for each target.
            declare -A next_sync
            local now
            now=$(date +%s)
            for target in "${TARGET_LIST[@]}"; do
                next_sync["$target"]=$now
            done

            while true; do
                now=$(date +%s)

                # Find the nearest target that is due to sync.
                local nearest_target=""
                local nearest_time=""
                for target in "${TARGET_LIST[@]}"; do
                    local t="${next_sync["$target"]}"
                    if [[ -z "$nearest_time" || "$t" -lt "$nearest_time" ]]; then
                        nearest_time="$t"
                        nearest_target="$target"
                    fi
                done

                # Sleep until the next target is due. Run sleep in the background
                # and wait for it; bash's wait is interrupted immediately by
                # SIGTERM, so shutdown is fast even when the next sync is far away.
                if [[ "$nearest_time" -gt "$now" ]]; then
                    local sleep_seconds=$((nearest_time - now))
                    log "Sleeping ${sleep_seconds}s until target '$nearest_target' is due"
                    local sleep_pid
                    sleep "$sleep_seconds" &
                    sleep_pid=$!
                    wait "$sleep_pid"
                    now=$(date +%s)
                fi

                # Sync every target whose deadline has passed (handles ties).
                for target in "${TARGET_LIST[@]}"; do
                    if [[ "${next_sync["$target"]}" -le "$now" ]]; then
                        log "Target '$target' is due for sync to remote"
                        sync_target_to_remote "$target"
                        next_sync["$target"]=$((now + TARGET_FREQS["$target"]))
                    fi
                done
            done
            ;;
        once)
            log "Running one-shot sync to remote"
            sync_all_to_remote
            ;;
        *)
            log "Usage: $0 {loop|once}"
            exit 1
            ;;
    esac
}

main "$@"
