FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

SHELL ["bash", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

# bubblewrap builds the namespace for Claude Code's sandbox, socat proxies its
# network out. Without either, Claude Code runs commands unsandboxed.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bubblewrap \
        socat \
        build-essential \
        file \
        sed \
        iproute2 \
        jq \
        ca-certificates \
        gnupg2 \
        less \
        nano \
        vim-tiny \
        unzip \
        zip \
        bzip2 \
        xz-utils \
        tree \
        man-db \
        bash-completion \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Chromium runtime deps for the Playwright MCP server (see .mcp.json). From apt rather
# than `playwright install --with-deps`, since Playwright isn't installed until the Node
# feature runs after this build. Mirrors Playwright's Ubuntu 24.04 list (`t64` = noble).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
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

RUN echo 'PS1="\[\033[01;34m\]\W\[\033[00m\] $ "' >> /home/vscode/.bashrc

RUN mkdir -p /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R vscode:vscode /commandhistory \
    && echo "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" >> /home/vscode/.bashrc

# Seed ~/.claude as vscode so the config volume (devcontainer.json) isn't
# auto-created root-owned.
RUN mkdir -p /home/vscode/.claude \
    && chown -R vscode:vscode /home/vscode/.claude

# Help Claude Code orient that it's running in a devcontainer
ENV DEVCONTAINER=true
