#!/usr/bin/env bash
set -euo pipefail

# Fold a stray ~/.claude.json (only containers predating CLAUDE_CONFIG_DIR have one)
# into the persisted volume. The volume's copy is the live state -- never clobber it.
LEGACY_CONFIG="$HOME/.claude.json"
PERSISTED_CONFIG="$HOME/.claude/.claude.json"
if [ -f "$LEGACY_CONFIG" ] && [ ! -f "$PERSISTED_CONFIG" ]; then
  echo "Migrating $LEGACY_CONFIG into the persisted config volume"
  mv "$LEGACY_CONFIG" "$PERSISTED_CONFIG"
fi

# Install the Playwright MCP server and its browser (see .mcp.json). Not in the
# Dockerfile: npm exists only after the Node feature installs.

# Pinned: .npmrc sets min-release-age=7, so `@latest` fails on fresh releases.
MCP_VERSION=0.0.79

# Derived, not a second pin that could drift: browser downloads are keyed by revision,
# so a mismatch surfaces at run time as "browser not found".
PW_VERSION="$(npm view "@playwright/mcp@${MCP_VERSION}" dependencies.playwright)"

# Global so starting the MCP server needs no network (no npx fetch).
npm install -g "@playwright/mcp@${MCP_VERSION}" "playwright@${PW_VERSION}"

# Browser binary only: OS deps come from the Dockerfile, and `--with-deps` needs root.
playwright install chromium
