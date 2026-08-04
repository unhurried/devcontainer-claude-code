# ANTHROPIC OFFICIAL SAMPLE (https://github.com/anthropics/claude-code/blob/main/.devcontainer/Dockerfile):
# FROM node:20
#
# ARG TZ
# ENV TZ="$TZ"
#
# ARG CLAUDE_CODE_VERSION=latest
#
# Project-specific: use the plain Ubuntu 24.04 devcontainer base image instead of the
# Node-specific image. Node.js/Python/Docker are installed via Dev Container Features
# (see devcontainer.json) rather than baked into this Dockerfile, so this image doesn't
# need to start from a Node base — or bundle Python/Docker itself.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

SHELL ["bash", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

# ANTHROPIC OFFICIAL SAMPLE:
# # Install basic development tools and iptables/ipset
# RUN apt-get update && apt-get install -y --no-install-recommends \
#   less \
#   git \
#   procps \
#   sudo \
#   fzf \
#   zsh \
#   man-db \
#   unzip \
#   gnupg2 \
#   gh \
#   iptables \
#   ipset \
#   iproute2 \
#   dnsutils \
#   aggregate \
#   jq \
#   nano \
#   vim \
#   && apt-get clean && rm -rf /var/lib/apt/lists/*
#
# Project-specific: the ubuntu-24.04 base devcontainer image already provides
# git/sudo/procps, and this project uses Bash instead of zsh, so zsh/fzf (and the
# zsh-in-docker theme setup further down) are dropped in favor of a plain, shortened
# Bash prompt. The rest of the list is kept close to the official one, plus a few extra
# general-purpose utilities this project also wants available.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bubblewrap \
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
        htop \
        rsync \
        man-db \
        bash-completion \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ANTHROPIC OFFICIAL SAMPLE:
# # Ensure default node user has access to /usr/local/share
# RUN mkdir -p /usr/local/share/npm-global && \
#   chown -R node:node /usr/local/share
#
# ARG USERNAME=node
#
# Project-specific: not needed — the Node.js Dev Container Feature manages npm's global
# prefix itself, and the ubuntu-24.04 base image's non-root user is "vscode" (used
# directly below instead of a USERNAME arg).

# ANTHROPIC OFFICIAL SAMPLE:
# # Persist bash history.
# RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
#   && mkdir /commandhistory \
#   && touch /commandhistory/.bash_history \
#   && chown -R $USERNAME /commandhistory
#
# Project-specific: same idea, adapted for the "vscode" user, plus shortening the shell
# prompt to just the current directory name (was user@host:/full/path).
RUN echo 'PS1="\[\033[01;34m\]\W\[\033[00m\] $ "' >> /home/vscode/.bashrc

RUN mkdir -p /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R vscode:vscode /commandhistory \
    && echo "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" >> /home/vscode/.bashrc

# ANTHROPIC OFFICIAL SAMPLE (unchanged):
# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# ANTHROPIC OFFICIAL SAMPLE:
# # Create workspace and config directories and set permissions
# RUN mkdir -p /workspace /home/node/.claude && \
#   chown -R node:node /workspace /home/node/.claude
#
# WORKDIR /workspace
#
# Project-specific: not needed — devcontainer.json here doesn't override
# workspaceMount/workspaceFolder, so the workspace is created automatically at the
# default /workspaces/<repo-name>, and ~/.claude is created by the volume mount.

# ANTHROPIC OFFICIAL SAMPLE:
# ARG GIT_DELTA_VERSION=0.18.2
# RUN ARCH=$(dpkg --print-architecture) && \
#   wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
#   sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
#   rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"
#
# Project-specific: git-delta isn't part of this project's toolchain; skipped to keep
# the image lean.

# ANTHROPIC OFFICIAL SAMPLE:
# # Set up non-root user
# USER node
#
# # Install global packages
# ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
# ENV PATH=$PATH:/usr/local/share/npm-global/bin
#
# # Set the default shell to zsh rather than sh
# ENV SHELL=/bin/zsh
#
# # Set the default editor and visual
# ENV EDITOR=nano
# ENV VISUAL=nano
#
# # Default powerline10k theme
# ARG ZSH_IN_DOCKER_VERSION=1.2.0
# RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
#   -p git \
#   -p fzf \
#   -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
#   -a "source /usr/share/doc/fzf/examples/completion.zsh" \
#   -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
#   -x
#
# # Install Claude
# RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
#
# Project-specific: this project stays on Bash (no zsh/powerlevel10k theme, no EDITOR
# override), and installs Node.js and Claude Code via Dev Container Features (see
# devcontainer.json) instead of npm/manual scripts here.

# ANTHROPIC OFFICIAL SAMPLE:
# # Copy and set up firewall script
# COPY init-firewall.sh /usr/local/bin/
# USER root
# RUN chmod +x /usr/local/bin/init-firewall.sh && \
#   echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
#   chmod 0440 /etc/sudoers.d/node-firewall
# USER node
#
# Project-specific: same idea (let the "vscode" user run the firewall script
# passwordlessly via devcontainer.json's postStartCommand, without granting broader
# sudo access), adapted for the "vscode" user and this repo's .devcontainer/scripts/
# layout (hence the ".devcontainer" prefix — the build context is the repo root, see
# devcontainer.json).
COPY .devcontainer/scripts/init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh \
    && echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/vscode-firewall \
    && chmod 0440 /etc/sudoers.d/vscode-firewall
