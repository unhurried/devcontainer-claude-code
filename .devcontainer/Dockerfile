FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG DEBIAN_FRONTEND=noninteractive

# Only what the base image (common-utils: git, curl, jq, less, nano, unzip, tree, ...)
# does not already ship.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        # bubblewrap and socat are required by Claude Code's sandbox.
        bubblewrap \
        socat \
        build-essential \
        file \
        # SoX `rec` with the pulse backend, for Claude Code's /voice.
        sox \
        libsox-fmt-pulse \
        # Chromium runtime deps for the Playwright MCP server. Installed here because
        # Playwright itself only arrives after the Node feature runs.
        libnss3 \
        libnspr4 \
        libdbus-1-3 \
        libatk1.0-0t64 \
        libatk-bridge2.0-0t64 \
        libatspi2.0-0t64 \
        libglib2.0-0t64 \
        libcups2t64 \
        libdrm2 \
        libgbm1 \
        libasound2t64 \
        libx11-6 \
        libxcb1 \
        libxcomposite1 \
        libxdamage1 \
        libxext6 \
        libxfixes3 \
        libxrandr2 \
        libxkbcommon0 \
        libpango-1.0-0 \
        libcairo2 \
        fonts-liberation \
        fonts-noto-color-emoji \
        fonts-noto-cjk \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Prompt, and a persisted bash history (/commandhistory is a volume).
RUN printf '%s\n' \
        'PS1="\[\033[01;34m\]\W\[\033[00m\] $ "' \
        "export PROMPT_COMMAND='history -a' HISTFILE=/commandhistory/.bash_history" \
        >> /home/vscode/.bashrc \
    && mkdir -p /commandhistory \
    && touch /commandhistory/.bash_history

# Create the volume mount points as vscode; ones docker creates itself are root-owned.
RUN mkdir -p /home/vscode/.claude \
             /home/vscode/.cache/ms-playwright \
             /home/vscode/.npm \
             /home/vscode/.vscode-server \
             /home/vscode/.local/bin \
    && chown -R vscode:vscode /home/vscode /commandhistory

# The native installer puts `claude` here (post-create.sh).
ENV PATH=/home/vscode/.local/bin:$PATH

# Help Claude Code orient that it's running in a devcontainer
ENV DEVCONTAINER=true
