FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

SHELL ["bash", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bubblewrap \
        build-essential \
        file \
        sed \
        curl \
        iptables \
        ipset \
        iproute2 \
        dnsutils \
        aggregate \
        jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Shorten the shell prompt to just the current directory name (was user@host:/full/path)
RUN echo 'PS1="\[\033[01;34m\]\W\[\033[00m\] $ "' >> /home/vscode/.bashrc

# Firewall script restricting outbound traffic to an allowlist of domains (see devcontainer.json postStartCommand)
COPY .devcontainer/init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh \
    && echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/vscode-firewall \
    && chmod 0440 /etc/sudoers.d/vscode-firewall
