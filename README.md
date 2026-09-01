# hermes-docker

This compose setup builds a custom `hermes-agent` image from the local `Dockerfile` rather than using a published image directly.

## Why this custom image exists

The local Dockerfile is used to install additional dependencies and package extensions required by your Hermes deployment.

This custom image:

- builds from the upstream `nousresearch/hermes-agent` base image
- installs browser, PowerPoint, and document-processing libraries

Use this custom image when your Hermes setup requires the extra packages and runtime configuration that are not included in the upstream base image.

## Persistent data and the custom entrypoint

Hermes performs a lot of read/write activity in its home folder. At times, it can generate a great amount of bloat during its operation. In cloud environments that use network-backed storage such as **Amazon EFS**, this can become expensive because every I/O operation is charged and adds latency. To reduce that cost, this image uses a custom [`entrypoint.sh`](entrypoint.sh) that symlinks only the important persistent files and folders to network storage, while letting Hermes keep its volatile, non-critical data on the container's faster local disk.

The wrapper runs **as root** before the original Hermes entrypoint. It creates the requested directories on the persistent volume, adjusts their ownership so the runtime `hermes` user can write to them, and then hands off to the original entrypoint. The original entrypoint is responsible for dropping privileges to the `hermes` user. Everything else that Hermes writes remains on the local filesystem and is discarded with the container.

### Environment variables

| Variable | Required | Description |
| --- | --- | --- |
| `PERSISTENT_DATA_HOME` | Yes | Root directory on the host (or network volume) where persistent data lives, e.g. `/efs/hermes-data`. |
| `PERSISTENT_TARGETS` | Yes | Comma-separated list of files and/or folders inside `/opt/data` that should be symlinked to `$PERSISTENT_DATA_HOME`. Append `/` to a name to treat it as a directory. |
| `ADDITIONAL_PROFILES` | No | Comma-separated list of extra Hermes profile names. For each profile `<name>`, targets are also symlinked between `$PERSISTENT_DATA_HOME/profiles/<name>` and `/opt/data/profiles/<name>`. |

### Permissions

- **Do not** set `USER hermes` in the Dockerfile and **do not** start the container with `--user`. The Hermes base image is designed to start as root and drop to the `hermes` user internally.
- The wrapper creates missing directories under `$PERSISTENT_DATA_HOME` and `chown`s them to the user the Hermes runtime will run as.
- If you remap the `hermes` user with `HERMES_UID`/`HERMES_GID` (or the `PUID`/`PGID` aliases), the wrapper uses the same UID/GID for the persistent volume so ownership stays consistent.
- On EFS and similar network filesystems, the container root must be allowed to create directories and change ownership. If your filesystem is configured with root squashing, either disable it for the mount or set the directory owner on the host to the expected UID/GID before starting the container.

### How it works

1. The entrypoint reads `PERSISTENT_DATA_HOME` and `PERSISTENT_TARGETS`.
2. For every target it creates a symlink:
   - `$PERSISTENT_DATA_HOME/<target>` → `/opt/data/<target>`
   - A trailing `/` in the target name means the target is a directory; otherwise it is treated as a file.
   - When the target is a `.db` file, the SQLite companion files (`.db-shm` and `.db-wal`) are linked as well.
3. If `ADDITIONAL_PROFILES` is set, the same targets are linked for each profile:
   - `$PERSISTENT_DATA_HOME/profiles/<profile>/<target>` → `/opt/data/profiles/<profile>/<target>`
4. The wrapper then `exec`s the original Hermes entrypoint `/opt/hermes/docker/entrypoint-dispatch.sh`.

### Example

```yaml
services:
  hermes:
    build: .
    environment:
      PERSISTENT_DATA_HOME: /opt/data/efs
      PERSISTENT_TARGETS: "config.yaml,state.db,logs/,memories/"
      ADDITIONAL_PROFILES: "work,home"
    volumes:
      - hermes-network-storage:/opt/data/efs
```

In this example:

- `config.yaml` and `state.db` (plus `state.db-shm` and `state.db-wal`) are stored on the network disk and symlinked into `/opt/data`.
- `logs/` and `memories/` are stored on the network disk as directories and symlinked into `/opt/data`.
- The same targets are also linked for the `work` and `home` profiles under `/opt/data/profiles/work` and `/opt/data/profiles/home`.
- All other Hermes read/write traffic uses the container's local disk.
