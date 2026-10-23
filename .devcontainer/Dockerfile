FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG DEBIAN_FRONTEND=noninteractive

# Only what the base image does not already ship (git, curl, jq, ...).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        # Claude Code's sandbox.
        bubblewrap \
        socat \
        build-essential \
        file \
        git-lfs \
        # SoX `rec` with the pulse backend, for /voice.
        sox \
        libsox-fmt-pulse \
        # Running GUI apps headless and driving them (Xvfb, xdotool, ImageMagick's
        # import), X11 libraries that winit loads at run time, and DejaVu Sans, the
        # fallback font of cosmic-text (iced): without it Latin text renders blank.
        xvfb \
        xdotool \
        imagemagick \
        libxkbcommon-x11-0 \
        libxcursor1 \
        libxi6 \
        libx11-xcb1 \
        fonts-dejavu-core \
        # Chromium runtime deps for the Playwright MCP server (post-create.sh installs
        # the browser; `playwright install-deps` needs npm, which arrives later).
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
    && rm -rf /var/lib/apt/lists/* \
    # The package does not register the LFS filters itself.
    && git lfs install --system

# Not in ~/.local: that volume would pin the binary to the first create.
ARG MISE_VERSION=v2026.9.12
RUN curl -fsSL https://mise.run \
    | MISE_VERSION=${MISE_VERSION} MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && mise --version

# Prompt, and a persisted bash history (/commandhistory is a volume).
RUN printf '%s\n' \
        'PS1="\[\033[01;34m\]\W\[\033[00m\] $ "' \
        "export PROMPT_COMMAND='history -a' HISTFILE=/commandhistory/.bash_history" \
        >> /home/vscode/.bashrc \
    && mkdir -p /commandhistory \
    && touch /commandhistory/.bash_history

# Gradle's proxy init script, symlinked so edits are live. This also creates
# ~/.gradle: the Claude Code sandbox can grant write access to it (where Gradle
# extracts its native libraries) only if it already exists.
RUN mkdir -p /home/vscode/.gradle/init.d \
    && ln -s /workspaces/devcontainer-claude-code/.devcontainer/gradle/proxy.init.gradle \
             /home/vscode/.gradle/init.d/proxy.init.gradle

# Volume mount points; ones docker creates itself are root-owned.
RUN mkdir -p /home/vscode/.claude \
             /home/vscode/.cache/ms-playwright \
             /home/vscode/.npm \
             /home/vscode/.vscode-server/extensions \
             /home/vscode/.local/bin \
    && chown -R vscode:vscode /home/vscode /commandhistory

# post-create.sh installs `claude` here. Shims, not `mise activate`: see README.
ENV PATH=/home/vscode/.local/share/mise/shims:/home/vscode/.local/bin:$PATH

# Lets Claude Code detect the devcontainer.
ENV DEVCONTAINER=true
