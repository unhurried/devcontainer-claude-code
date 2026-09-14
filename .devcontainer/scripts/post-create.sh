#!/usr/bin/env bash
set -euo pipefail

# Move a pre-CLAUDE_CONFIG_DIR ~/.claude.json into the persisted volume.
# Never overwrite the volume's copy.
LEGACY_CONFIG="$HOME/.claude.json"
PERSISTED_CONFIG="$HOME/.claude/.claude.json"
if [ -f "$LEGACY_CONFIG" ] && [ ! -f "$PERSISTED_CONFIG" ]; then
  echo "Migrating $LEGACY_CONFIG into the persisted config volume"
  mv "$LEGACY_CONFIG" "$PERSISTED_CONFIG"
fi

# Claude Code via the native installer, not npm or the devcontainer feature: those
# cannot auto-update here (NPM_CONFIG_MIN_RELEASE_AGE rejects every daily release,
# NPM_CONFIG_IGNORE_SCRIPTS skips the postinstall, and the feature installs as root).
# ~/.local is a persisted volume, so this downloads once; the auto-updater keeps it current.
if [ ! -x "$HOME/.local/bin/claude" ]; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

# Playwright MCP server and browser; sync-claude-config.sh registers it with Claude Code.
# Not in the Dockerfile: npm arrives with the Node feature. ~/.npm and
# ~/.cache/ms-playwright are persisted volumes, so a rebuild downloads nothing.

# Pinned: NPM_CONFIG_MIN_RELEASE_AGE rejects `@latest` when it is under a week old.
MCP_VERSION=0.0.79

# Global so the MCP server starts without a network fetch (no npx).
npm install -g --prefer-offline "@playwright/mcp@${MCP_VERSION}"

# Derived from the MCP package so the browser revision cannot drift from it.
PW_VERSION="$(node -p "require('$(npm root -g)/@playwright/mcp/package.json').dependencies.playwright")"
npm install -g --prefer-offline "playwright@${PW_VERSION}"

# Browser only: OS deps come from the Dockerfile.
playwright install chromium
