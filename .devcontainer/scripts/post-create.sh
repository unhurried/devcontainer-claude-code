#!/usr/bin/env bash
set -euo pipefail

# Native installer, not npm or the devcontainer feature: only it can auto-update here
# (see README, Package installs). ~/.local is a volume, so this downloads once.
if [ ! -x "$HOME/.local/bin/claude" ]; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

# Versions: mise/config.toml.
mise install --yes

# Claude Code's sandbox grants write access to CARGO_HOME (claude/settings.json) only
# if it exists when Claude Code starts; rustup would create it only on the first
# `mise install` of a Rust repo.
mkdir -p "${CARGO_HOME:?}"

# Playwright MCP server and browser (sync-claude-config.sh registers it). ~/.npm and
# ~/.cache/ms-playwright are volumes, so a rebuild downloads nothing.

# Pinned: NPM_CONFIG_MIN_RELEASE_AGE rejects `@latest` when it is under a week old.
MCP_VERSION=0.0.83

# Global so the MCP server starts without a network fetch (no npx).
npm install -g --prefer-offline "@playwright/mcp@${MCP_VERSION}"

# OS deps are in the Dockerfile. The package's own playwright, so the browser
# revision matches it.
"$(npm root -g)/@playwright/mcp/node_modules/.bin/playwright" install chromium

# Lets the Claude Code sandbox refuse AF_UNIX sockets (docker.sock, IDE sockets); the
# prebuilt apply-seccomp needs no install script. Pinned for the same reason as above.
SRT_VERSION=0.0.80
npm install -g --prefer-offline "@anthropic-ai/sandbox-runtime@${SRT_VERSION}"
