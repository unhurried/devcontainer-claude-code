#!/usr/bin/env bash
set -euo pipefail

# Native installer, not npm or the devcontainer feature: only it can auto-update here
# (see README, Package installs). ~/.local is a volume, so this downloads once.
if [ ! -x "$HOME/.local/bin/claude" ]; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

# Versions: mise/config.toml.
mise install --yes

# Playwright MCP server and browser (sync-claude-config.sh registers it). ~/.npm and
# ~/.cache/ms-playwright are volumes, so a rebuild downloads nothing.

# Pinned: NPM_CONFIG_MIN_RELEASE_AGE rejects `@latest` when it is under a week old.
MCP_VERSION=0.0.79

# Global so the MCP server starts without a network fetch (no npx).
npm install -g --prefer-offline "@playwright/mcp@${MCP_VERSION}"

# OS deps are in the Dockerfile. The package's own playwright, so the browser
# revision matches it.
"$(npm root -g)/@playwright/mcp/node_modules/.bin/playwright" install chromium
