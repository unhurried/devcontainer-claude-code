FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

SHELL ["bash", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bubblewrap \
        build-essential \
        file \
        sed \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Shorten the shell prompt to just the current directory name (was user@host:/full/path)
RUN echo 'PS1="\[\033[01;34m\]\W\[\033[00m\] $ "' >> /home/vscode/.bashrc
