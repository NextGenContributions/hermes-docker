#!/usr/bin/env bash
# entrypoint.nonroot.sh
#
# Entrypoint for the non-root Hermes image flavor. Used instead of the base
# image's s6-overlay dispatch, because s6's /init requires root and because
# sandbox runtimes (OpenShell, Fly, --init) own PID 1 themselves.
#
# What it does, in order:
#   1. Make sure the writable Hermes paths exist (created at build time; this
#      is only a safety net for bind-mounted volumes).
#   2. Run the base image's stage2 bootstrap (config seeding, skills sync).
#      It tolerates running unprivileged; failures are logged, not fatal, so a
#      read-only home never stops the agent from starting.
#   3. Start the optional background services that s6 would normally supervise
#      (persistent-sync, leafwiki + its resync ticker) — only when the
#      corresponding env config is present.
#   4. Hand over to the base image's main-wrapper, which routes CMD -> hermes
#      and skips the setuidgid drop because we are already non-root.
set -euo pipefail

LOG_PREFIX="[entrypoint-nonroot]"
# Under `set -e` a failed command substitution exits silently; make the line
# number visible so a broken host (e.g. a base image without arm64 Chromium)
# is diagnosable from the container log alone.
trap 'rc=$?; log "ERROR: aborted at line $LINENO (exit $rc)"' ERR
# shellcheck source=./persistent-sync-lib.sh
source /usr/local/bin/persistent-sync-lib.sh

: "${HERMES_HOME:=/opt/data}"
export HOME="${HOME:-$HERMES_HOME}"
export HERMES_HOME
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$HERMES_HOME/.runtime}"

ensure_writable_dirs() {
    local dir
    for dir in "$HERMES_HOME" "$HERMES_HOME/.cache" "$HERMES_HOME/.config" \
               "$HERMES_HOME/.local/share" "$HERMES_HOME/.local/state" \
               "$XDG_RUNTIME_DIR"; do
        mkdir -p "$dir" 2>/dev/null || log "Warning: cannot create $dir"
    done
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
    # s6's /init collects env from here; stage2 writes the pinned browser path
    # into it. /run is a tmpfs on some runtimes, so recreate it every start.
    mkdir -p /run/s6/container_environment 2>/dev/null || \
        log "Note: /run/s6 is not writable; exporting browser path directly instead"
    # rclone keeps its generated config in /tmp; make sure that is writable.
    : >"$RCLONE_CONFIG_FILE" 2>/dev/null || log "Warning: $RCLONE_CONFIG_FILE is not writable"
    rm -f "$RCLONE_CONFIG_FILE" 2>/dev/null || true
}

# Without s6's with-contenv there is no container_environment propagation, so
# publish the pinned Chromium path the same way the base image's stage2 does.
export_browser_path() {
    local browser_bin
    # amd64 builds unpack to chrome-linux64/, arm64 builds to chrome-linux/.
    browser_bin="$(ls -d /opt/hermes/tools/chromium-*/chrome-linux*/chrome 2>/dev/null | head -n1 || true)"
    if [[ -z "$browser_bin" ]]; then
        log "No pinned Chromium found under /opt/hermes/tools; leaving AGENT_BROWSER_EXECUTABLE_PATH unset"
    fi
    if [[ -n "$browser_bin" && -x "$browser_bin" ]]; then
        export AGENT_BROWSER_EXECUTABLE_PATH="$browser_bin"
        log "AGENT_BROWSER_EXECUTABLE_PATH=$AGENT_BROWSER_EXECUTABLE_PATH"
    fi
}

bootstrap() {
    if [[ -x /opt/hermes/docker/stage2-hook.sh ]]; then
        log "Running stage2 bootstrap as uid $(id -u)"
        /opt/hermes/docker/stage2-hook.sh || \
            log "Warning: stage2 bootstrap reported a failure; continuing"
    else
        log "No stage2 bootstrap found; skipping"
    fi
}

# s6-overlay normally runs the dashboard as its own supervised slot whenever
# HERMES_DASHBOARD is truthy, independently of the main command. Recreate that
# here so `hermes gateway run` still serves the web UI.
start_dashboard() {
    case "${HERMES_DASHBOARD:-}" in
        1|true|TRUE|True|yes|YES|Yes) ;;
        *) return 0 ;;
    esac
    # If the main command IS the dashboard, main-wrapper will start it.
    if [[ "${1:-}" == "dashboard" ]]; then
        return 0
    fi
    local dash_host="${HERMES_DASHBOARD_HOST:-0.0.0.0}"
    local dash_port="${HERMES_DASHBOARD_PORT:-9119}"
    log "Starting dashboard on ${dash_host}:${dash_port} in the background"
    (
        cd "$HERMES_HOME" || exit 1
        exec hermes dashboard --host "$dash_host" --port "$dash_port" \
            --no-open --skip-build
    ) &
}

# s6-overlay normally owns these; as non-root we start them ourselves and let
# them die with the container/sandbox.
start_background_services() {
    if [[ -n "${PERSISTENT_DATA_HOME:-}" ]]; then
        log "Starting persistent-sync loop in the background"
        /usr/local/bin/persistent-sync.sh loop &
    else
        log "PERSISTENT_DATA_HOME unset; persistent-sync service disabled"
    fi

    if [[ -n "${LEAFWIKI_DATA_DIR:-}" && -x /usr/local/bin/leafwiki ]]; then
        log "Starting leafwiki in the background"
        /usr/local/bin/leafwiki &
        # LeafWiki does not watch the filesystem; nudge it to resync.
        (
            freq=$(parse_sync_interval "${LEAFWIKI_RESYNC_FREQ:-3600}")
            while sleep "$freq"; do
                pkill -SIGHUP leafwiki 2>/dev/null || true
            done
        ) &
    else
        log "LEAFWIKI_DATA_DIR unset; leafwiki services disabled"
    fi
}

# OpenShell: re-sync provider placeholders into $HERMES_HOME/.env before any service starts.
# OpenShell mints new handles (openshell:resolve:env:<KEY>) per sandbox create. Hermes loads
# .env with override=True, so stale handles there would beat the live environment.
PROVIDER_ENV_KEYS=""
sync_env_placeholders() {
    local envfile="${HERMES_HOME:-/opt/data}/.env"
    if [[ ! -f "$envfile" ]]; then
        echo "[entrypoint-nonroot] sync: $envfile missing; skipping" >&2
        return 0
    fi
    python3 - "$envfile" $PROVIDER_ENV_KEYS <<'PY' || echo "[entrypoint-nonroot] Warning: placeholder sync failed" >&2
import os, re, sys
path, keys = sys.argv[1], sys.argv[2:]
out, done = [], set()
for line in open(path).read().splitlines():
    m = re.match(r"^#?\s*([A-Z0-9_]+)=", line)
    if m and m.group(1) in keys:
        k = m.group(1)
        if k in done:
            continue
        done.add(k)
        val = os.environ.get(k, "")
        if val:
            out.append(f"{k}={val}")
        else:
            print(f"[entrypoint-nonroot] sync: {k} not in environment; line left as-is", file=sys.stderr)
            out.append(line)
    else:
        out.append(line)
for k in keys:
    if k not in done and os.environ.get(k):
        out.append(f"{k}={os.environ[k]}")
        done.add(k)
tmp = path + ".tmp"
open(tmp, "w").write("\n".join(out) + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(f"[entrypoint-nonroot] sync: wrote {len(done)} provider keys to .env", file=sys.stderr)
PY
}

main() {
    log "Starting as uid=$(id -u) gid=$(id -g) HERMES_HOME=$HERMES_HOME"
    ensure_writable_dirs
    sync_env_placeholders
    export_browser_path
    bootstrap
    start_background_services
    start_dashboard "$@"
    log "Handing over to the Hermes main wrapper"
    exec /opt/hermes/docker/main-wrapper.sh "$@"
}

main "$@"
