# v0.2.1
FROM ghcr.io/julientant/blogwatcher-cli@sha256:e7a5d0cb2dcb94602ea89623236331219755bc4ff97ea4d3a9a7ae8a2ca7d36e AS blogwatcher-cli

# v0.13.0
FROM ghcr.io/perber/leafwiki@sha256:c40904dafd9db81ca2c9334e8c67fb168d175876111fc1fd9a00e3715b66775b as leafwiki

# v2026.9.24
FROM nousresearch/hermes-agent@sha256:fca358f12efd65bfaaca05884166f15c0e2788375ca30d77061ac1ebc96452b7

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm install -g \
    # Local browser mode for the agent
    # https://hermes-agent.nousresearch.com/docs/user-guide/features/browser#local-browser-mode
    agent-browser@">=0.31.1" \
    # Create and manipulate PowerPoint presentations
    # https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/productivity/productivity-powerpoint#creating-from-scratch
    pptxgenjs@">=4.0.1" \
    # https://hermes-agent.nousresearch.com/docs/user-guide/security#tirith-pre-exec-security-scanning
    tirith@">=0.4.2"

RUN \
    # Remove the .python-version file to avoid mismatch with the Python version used in 
    # .venv folder, which could cause uv to download a different Python, thus breaking 
    # the virtual environment.
    rm /opt/hermes/.python-version && \
    # Install additional packages to the existing .venv
    uv add --no-cache --no-python-downloads \
    # General tools to extract text from various document formats
    # https://github.com/microsoft/markitdown#optional-dependencies
    "markitdown[pptx,docx,xlsx,xls,pdf,audio-transcription,youtube-transcription]==0.1.6" \
    # Lightweight PDF and document processing
    # https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/productivity/productivity-pdf
    pdfplumber>=0.11.10 \
    reportlab>=5.0.1 \
    pypdf>=6.18.1 \
    pymupdf>=1.28.2 \
    pymupdf4llm>=1.28.2 \
    # https://hermes-agent.nousresearch.com/docs/user-guide/features/browser#firecrawl-cloud-mode
    firecrawl-py>=4.17.0 \
    # https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/media/media-youtube-content#setup
    youtube-transcript-api>=1.2.4 \
    # https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/productivity/productivity-docx#prerequisites
    python-docx>=1.2.0 \
    # https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/productivity/productivity-powerpoint#prerequisites
    python-pptx>=1.0.2 \
    # https://hermes-agent.nousresearch.com/docs/user-guide/features/browser#browser-use-mode-default
    browser-use>=0.11.13

# Monitor blogs and RSS/Atom feeds via blogwatcher-cli tool.
# https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/research/research-blogwatcher
COPY --from=blogwatcher-cli /blogwatcher-cli /usr/local/bin/blogwatcher-cli

# Manage and edit local wiki via leafwiki tool.
# https://github.com/perber/leafwiki
COPY --from=leafwiki /app/leafwiki /usr/local/bin/leafwiki

# Set up GitHub CLI repository and keyring for installation.
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && out=$(mktemp) && curl -fsSL -o$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && cat $out | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && mkdir -p -m 755 /etc/apt/sources.list.d \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # GitHub CLI tool for interacting with GitHub from the command line.
    gh \
    # Vim text editor for editing files within the container.
    vim \
    # Install rclone for syncing important persistent data between the container's
    # fast local disk and the remote/network-backed persistent volume.
    rclone \
    # LibreOffice core components without GUI for document processing.
    libreoffice-core-nogui \
    # Poppler utilities for PDF processing.
    poppler-utils && \
    # Clean up the apt cache to reduce the image size.
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
