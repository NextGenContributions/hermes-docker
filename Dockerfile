# v0.2.1
FROM ghcr.io/julientant/blogwatcher-cli@sha256:e7a5d0cb2dcb94602ea89623236331219755bc4ff97ea4d3a9a7ae8a2ca7d36e AS blogwatcher-cli

# v0.12.1
FROM ghcr.io/perber/leafwiki@sha256:2e70745f69a43eb32a74d7962c1334c57ea56f2487fb3a1b8d4c0d0fa6185209 as leafwiki

# v2026.9.7
FROM nousresearch/hermes-agent@sha256:63bfb6d732f49a55d453e801057273785cc61e0f6ee43db3fa2f2a79846301b7

RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm install -g \
    # Local browser mode for the agent
    # https://hermes-agent.nousresearch.com/docs/user-guide/features/browser#local-browser-mode
    agent-browser@0.31.1 \
    # Create and manipulate PowerPoint presentations
    # https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/productivity/productivity-powerpoint#creating-from-scratch
    pptxgenjs@4.0.1

RUN \
    # Remove the .python-version file to avoid mismatch with the Python version used in 
    # .venv folder, which could cause uv to download a different Python, thus breaking 
    # the virtual environment.
    rm /opt/hermes/.python-version && \
    # Install additional packages to the existing .venv
    uv add --no-cache --no-python-downloads \
    # General tools to extract text from various document formats
    # https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/productivity/productivity-powerpoint#dependencies
    # https://github.com/microsoft/markitdown#optional-dependencies
    "markitdown[pptx,docx,xlsx,xls,pdf,audio-transcription,youtube-transcription]==0.1.6" \
    # Lightweight PDF and document processing
    # https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/productivity/productivity-ocr-and-documents#pymupdf-lightweight
    pymupdf==1.28.0 \
    pymupdf4llm==1.28.0 \
    # https://hermes-agent.nousresearch.com/docs/user-guide/features/browser#firecrawl-cloud-mode
    firecrawl-py==4.17.0

# Monitor blogs and RSS/Atom feeds via blogwatcher-cli tool.
# https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/research/research-blogwatcher
COPY --from=blogwatcher-cli /blogwatcher-cli /usr/local/bin/blogwatcher-cli

# Manage and edit local wiki via leafwiki tool.
# https://github.com/perber/leafwiki
COPY --from=leafwiki /app/leafwiki /usr/local/bin/leafwiki

# Install rclone for syncing important persistent data between the container's
# fast local disk and the remote/network-backed persistent volume.
RUN apt-get update && \
    apt-get install -y --no-install-recommends rclone && \
    rm -rf /var/lib/apt/lists/*

# Wrap the original entrypoint to manage rclone sync before/after Hermes runs.
# Keep the container starting as root here; the original Hermes entrypoint handles
# its own privilege drop to the hermes user. This lets us create and chown the
# persistent-data directories before the agent starts.
COPY persistent-sync-lib.sh /usr/local/bin/persistent-sync-lib.sh
COPY persistent-sync.sh /usr/local/bin/persistent-sync.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x \
    /usr/local/bin/persistent-sync-lib.sh \
    /usr/local/bin/persistent-sync.sh \
    /usr/local/bin/entrypoint.sh

# Register the persistent-sync service with the base image's s6-overlay setup.
# The service periodically uploads local targets to the persistent volume and
# performs a final upload when the container shuts down.
COPY s6-overlay/s6-rc.d /etc/s6-overlay/s6-rc.d
RUN chmod +x \
    /etc/s6-overlay/s6-rc.d/persistent-sync/run \
    /etc/s6-overlay/s6-rc.d/persistent-sync/finish \
    /etc/s6-overlay/s6-rc.d/leafwiki/run \
    /etc/s6-overlay/s6-rc.d/leafwiki/finish \
    /etc/s6-overlay/s6-rc.d/leafwiki-resync/run \
    /etc/s6-overlay/s6-rc.d/leafwiki-resync/finish

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
