# hermes-docker

This compose setup builds a custom `hermes-agent` image from the local `Dockerfile` rather than using a published image directly.

## Why this custom image exists

The local Dockerfile is used to install additional dependencies and package extensions required by your Hermes deployment.

This custom image:

- builds from the upstream `nousresearch/hermes-agent` base image
- installs browser, PowerPoint, and document-processing libraries

Use this custom image when your Hermes setup requires the extra packages and runtime configuration that are not included in the upstream base image.

## Persistent data and the custom entrypoint

Hermes performs a lot of read/write activity in its home folder. At times, it can generate a great amount of bloat during its operation. In cloud environments that use network-backed storage such as **Amazon EFS**, this can become expensive because every I/O operation is charged and adds latency.

To reduce that cost, this image uses [`rclone`](https://rclone.org/) inside a custom [`entrypoint.sh`](entrypoint.sh). Important persistent files and folders can either be copied between the network volume and the container's fast local disk, or symlinked directly to the network volume. Synced targets are cached locally while Hermes runs; a background job copies them back to the network volume, and a final copy runs on SIGTERM. Linked targets are read and written straight on the network volume and are not synced by the background job. Volatile, non-critical data never leaves the local disk and is discarded with the container.

### Environment variables

| Variable | Required | Description |
| --- | --- | --- |
| `PERSISTENT_DATA_HOME` | Yes | Root directory on the host (or network volume) where persistent data lives, e.g. `/efs/hermes-data`. |
| `PERSISTENT_TARGETS_SYNC` | No* | Comma-separated list of files and/or folders inside `/opt/data` that should be kept in `$PERSISTENT_DATA_HOME`. Append `/` to a name to treat it as a directory. Entries may also specify a custom sync interval using the format `(target \| freq)`, e.g. `(wiki/ \| 60)`. `freq` follows the same format as `PERSISTENT_TARGETS_SYNC_FREQ` and overrides the default for that target. Spaces around the target, `\|`, and frequency are allowed. |
| `PERSISTENT_TARGETS_SYNC_FREQ` | No | Default interval between background syncs from local disk back to `$PERSISTENT_DATA_HOME`. Plain seconds or a suffix of `s`, `m`, `h`, `d`. Defaults to `3600` (1 hour). |
| `PERSISTENT_TARGETS_LINK` | No* | Comma-separated list of files and/or folders inside `/opt/data` that should be **symlinked** directly into `$PERSISTENT_DATA_HOME`. Append `/` to a name to treat it as a directory. Linked targets are not copied by rclone and are not synced by the background service; Hermes reads and writes them straight on the network volume. |
| `ADDITIONAL_PROFILES` | No | Comma-separated list of extra Hermes profile names. For each profile `<name>`, targets are also synced or symlinked between `$PERSISTENT_DATA_HOME/profiles/<name>` and `/opt/data/profiles/<name>`. |
| `RCLONE_TRANSFERS` | No | Number of file transfers to run in parallel. Passed to rclone as `--transfers`. Defaults to `32`. |
| `RCLONE_CHECKERS` | No | Number of checkers to run in parallel. Passed to rclone as `--checkers`. Defaults to `64`. |

*At least one of `PERSISTENT_TARGETS_SYNC` or `PERSISTENT_TARGETS_LINK` must be set for the wrapper to do anything with persistent data.


### Permissions

- **Do not** set `USER hermes` in the Dockerfile and **do not** start the container with `--user`. The Hermes base image is designed to start as root and drop to the `hermes` user internally.
- The wrapper runs **as root** so it can configure rclone, create directories, and `chown` the synced data to the user the Hermes runtime will run as.
- If you remap the `hermes` user with `HERMES_UID`/`HERMES_GID` (or the `PUID`/`PGID` aliases), the wrapper uses the same UID/GID for the persistent volume so ownership stays consistent.
- On EFS and similar network filesystems, the container root must be allowed to create directories and change ownership. If your filesystem is configured with root squashing, either disable it for the mount or set the directory owner on the host to the expected UID/GID before starting the container.

### How it works

At startup the entrypoint reads `PERSISTENT_DATA_HOME`, `PERSISTENT_TARGETS_SYNC`, `PERSISTENT_TARGETS_LINK`, and `PERSISTENT_TARGETS_SYNC_FREQ`. It then prepares persistent data in two independent ways: **link** targets are symlinked straight to the network volume, and **sync** targets are copied between the network volume and the container's local disk.

If a target is listed in both variables, the link takes precedence and rclone ignores it.

#### Persistent link (`PERSISTENT_TARGETS_LINK`)

These targets are symlinked from `$PERSISTENT_DATA_HOME` into `/opt/data` before Hermes starts.

- A trailing `/` means the target is a directory.
- Source files that do not exist yet get an empty placeholder on the persistent volume so the symlink is not dangling.
- When the target ends with `.db`, any SQLite companion files (`.db-shm` and `.db-wal`) created at runtime are written next to the **real** database on the persistent volume.
- The same targets are linked for each profile in `ADDITIONAL_PROFILES` to `/opt/data/profiles/<profile>`.
- Hermes reads and writes these targets directly on the network volume. They are not copied by the background service.

#### Persistent sync (`PERSISTENT_TARGETS_SYNC`)

The entrypoint configures an rclone `persistent:` alias remote that points to `$PERSISTENT_DATA_HOME`, then copies the remaining sync targets from the persistent volume to `/opt/data` before Hermes starts.

- A trailing `/` means the target is a directory.
- When the target ends with `.db`, the SQLite companion files (`.db-shm` and `.db-wal`) are synced as well.
- The same targets are synced for each profile in `ADDITIONAL_PROFILES` to `/opt/data/profiles/<profile>`.
- Hermes runs with these files on local disk, so runtime I/O for them is local.

#### Background sync and shutdown

After the startup setup, the original Hermes entrypoint `/opt/hermes/docker/entrypoint-dispatch.sh` starts.

- A background service schedules each sync target independently and copies it from `/opt/data` back to `persistent:` when its own interval elapses. Targets without a custom interval use `PERSISTENT_TARGETS_SYNC_FREQ`.
- Link targets are never synced by this service.
- When the container receives `SIGTERM`, the background service stops and one final sync to `persistent:` runs before exit. The service has unlimited finish timeout and `docker-compose.yml` uses a longer `stop_grace_period` so the final upload is not killed before it completes.
- Checksum/hash comparisons are not used because they are expensive over network storage such as EFS; rclone compares by size and modification time instead.

### Example

```yaml
services:
  hermes:
    build: .
    environment:
      PERSISTENT_DATA_HOME: /opt/data/efs
      PERSISTENT_TARGETS_SYNC: "config.yaml,(state.db| 5m),logs/,(memories/| 10m)"
      PERSISTENT_TARGETS_LINK: "SOUL.md, projects.db, wiki/"
      ADDITIONAL_PROFILES: "work,home"
      PERSISTENT_TARGETS_SYNC_FREQ: 1h
    volumes:
      - hermes-network-storage:/opt/data/efs
```

In this example:

- `SOUL.md`, `projects.db`, and `wiki/` are symlinked straight to the network disk. They are read and written directly on `$PERSISTENT_DATA_HOME` and are not handled by the background sync service.
- `config.yaml` and `logs/` are copied from the network disk to `/opt/data` at startup and synced back every hour.
- `state.db` (plus `state.db-shm` and `state.db-wal`) is synced back every 5 minutes.
- `memories/` is copied from the network disk to `/opt/data` as a directory at startup and synced back every 10 minutes.
- The same targets are also synced or linked for the `work` and `home` profiles under `/opt/data/profiles/work` and `/opt/data/profiles/home`.
- All other Hermes read/write traffic uses the container's local disk.
