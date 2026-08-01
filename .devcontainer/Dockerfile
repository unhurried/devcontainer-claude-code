FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

SHELL ["bash", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

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

# Shorten the shell prompt to just the current directory name (was user@host:/full/path)
RUN echo 'PS1="\[\033[01;34m\]\W\[\033[00m\] $ "' >> /home/vscode/.bashrc

# Persist bash history in a volume-backed directory (see devcontainer.json mounts).
RUN mkdir -p /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R vscode:vscode /commandhistory \
    && echo "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" >> /home/vscode/.bashrc

# Install the network firewall script and let vscode run it passwordlessly via
# the devcontainer's postStartCommand, without granting broader sudo access.
COPY .devcontainer/scripts/init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh \
    && echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/vscode-firewall \
    && chmod 0440 /etc/sudoers.d/vscode-firewall
