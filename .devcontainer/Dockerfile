FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

SHELL ["bash", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

# bubblewrap: used by Claude Code's own sandboxing.
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
        man-db \
        bash-completion \
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

# The claude-code feature installs its own init-firewall.sh after this Dockerfile builds, so
# we can't COPY our version here without it being overwritten. Instead, onCreateCommand in
# devcontainer.json replaces the script's contents post-install. This RUN just narrows sudo
# access to that one script, revoking the base image's default passwordless-sudo-for-everything.
RUN rm -f /etc/sudoers.d/vscode \
    && echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/vscode-firewall \
    && chmod 0440 /etc/sudoers.d/vscode-firewall
