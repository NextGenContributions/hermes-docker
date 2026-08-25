# v0.2.1
FROM ghcr.io/julientant/blogwatcher-cli@sha256:e7a5d0cb2dcb94602ea89623236331219755bc4ff97ea4d3a9a7ae8a2ca7d36e AS blogwatcher-cli

# v2026.8.19
FROM nousresearch/hermes-agent@sha256:3811ed13da874fba2ac99b6d492db9a203d34cb6dccf90d886948c00d0ccec09

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
