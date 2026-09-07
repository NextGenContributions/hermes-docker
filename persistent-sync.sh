#!/command/with-contenv bash
# persistent-sync.sh
# s6-overlay longrun service script for the Hermes persistent-data sync.
# Can also be invoked with the "final" argument for final one-shot sync (used by the
# service finish script).
set -euo pipefail

# Use a distinct log prefix so service logs are easy to identify.
LOG_PREFIX="[persistent-sync]"
# shellcheck source=./persistent-sync-lib.sh
source /usr/local/bin/persistent-sync-lib.sh

do_setup() {
    log "Performing one-time setup for persistent sync"
    set_target_uid_gid
    setup_rclone_remote || return 1

    local default_freq
    default_freq=$(parse_sync_interval "${PERSISTENT_DATA_SYNC_FREQ:-3600}")
    load_targets "$PERSISTENT_TARGETS_SYNC" "$default_freq"
}

run_loop() {
    log "Starting per-target periodic sync loop"

    # On SIGTERM, run one final sync before exiting. The signal handler
    # interrupts the background sleep via wait, so shutdown is immediate.
    trap 'log "Received SIGTERM, exiting periodic sync loop"; exit 0' TERM

    # Track the next scheduled sync time for each target.
    declare -A next_sync
    local now
    now=$(date +%s)
    for target in "${TARGET_LIST[@]}"; do
        next_sync["$target"]=$((now + TARGET_FREQS["$target"]))
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

        # Sleep until the next target is due. Run sleep in the background and
        # wait for it; bash's wait is interrupted immediately by SIGTERM, so
        # shutdown is fast even when the next sync is far away.
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
}

main() {
    local mode="${1:-loop}"

    case "$mode" in
        loop)
            do_setup
            run_loop
            ;;
        final)
            # Suppress output from setup since it is already done by the run script
            do_setup >/dev/null 2>&1
            log "Running final sync to remote"
            sync_all_to_remote
            ;;
        *)
            log "Usage: $0 {loop|final}"
            exit 1
            ;;
    esac
}

main "$@"
