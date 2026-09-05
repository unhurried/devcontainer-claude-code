FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

SHELL ["bash", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

# bubblewrap and socat: both required by Claude Code's own sandboxing. bubblewrap
# builds the namespace, socat proxies the sandboxed process's network out through it.
# Without socat, Claude Code reports "sandbox is enabled but dependencies are missing"
# and falls back to running commands unsandboxed.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bubblewrap \
        socat \
        build-essential \
        file \
        sed \
        iptables \
        ipset \
        iproute2 \
        dnsutils \
        aggregate \
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

# Chromium runtime dependencies, for the Playwright MCP server (see .mcp.json).
# Installed from apt here rather than via `playwright install --with-deps`
# because the vscode user has no general passwordless sudo (see below). The list
# mirrors Playwright's Ubuntu 24.04 dependency set; note the `t64` suffixes
# noble introduced. fonts-noto-cjk keeps Japanese pages from rendering as tofu.
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

# Pre-create and chown ~/.claude so the config volume mount (devcontainer.json)
# is seeded with vscode ownership instead of being auto-created root-owned.
RUN mkdir -p /home/vscode/.claude \
    && chown -R vscode:vscode /home/vscode/.claude

# Help Claude Code orient that it's running in a devcontainer
ENV DEVCONTAINER=true

# Egress firewall, baked into the image rather than installed at container creation.
#
# The claude-code feature installs its own /usr/local/bin/init-firewall.sh after this
# Dockerfile builds, so that path can't hold our version. Rather than overwriting it
# afterwards -- which the vscode user has no sudo rights to do anyway -- we install ours
# under a distinct name and simply leave the feature's copy unused and unreachable.
#
# Baking it in also keeps the trust boundary intact: both files live outside the workspace
# bind mount, so a process in the container can't widen its own egress allowlist. Editing
# either one requires a rebuild.
COPY scripts/init-firewall.sh /usr/local/bin/devcontainer-init-firewall.sh
COPY scripts/allowed-domains.txt /usr/local/etc/allowed-domains.txt
RUN chmod 0755 /usr/local/bin/devcontainer-init-firewall.sh \
    && chmod 0644 /usr/local/etc/allowed-domains.txt

# Narrow sudo to just that script, revoking the base image's default
# passwordless-sudo-for-everything. Note this deliberately does NOT grant the feature's
# init-firewall.sh, whose allowlist is narrower and which drops the Docker DNS rules.
RUN rm -f /etc/sudoers.d/vscode \
    && echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/devcontainer-init-firewall.sh" > /etc/sudoers.d/vscode-firewall \
    && chmod 0440 /etc/sudoers.d/vscode-firewall
