FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash-completion \
        build-essential \
        ca-certificates \
        curl \
        file \
        git \
        gnupg \
        iproute2 \
        jq \
        less \
        lsb-release \
        procps \
        sed \
        unzip \
        xz-utils \
        zip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
