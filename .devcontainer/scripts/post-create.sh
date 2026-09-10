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

# Install the Playwright MCP server and its browser; sync-claude-config.sh registers it
# with Claude Code. Not in the Dockerfile: npm exists only after the Node feature installs.
#
# This is the slowest thing a rebuild does -- it is the one step that pulls hundreds of
# megabytes through the proxy. Both caches it needs are persisted volumes
# (devcontainer.json), so on a rebuild the packages resolve from ~/.npm and the browser
# is already in ~/.cache/ms-playwright: no download, no network.

# Pinned: .npmrc sets min-release-age=7, so `@latest` fails on fresh releases.
MCP_VERSION=0.0.79

# Global so starting the MCP server needs no network (no npx fetch). --prefer-offline
# takes what the cache has without revalidating it against the registry; a version the
# cache is missing is still fetched.
npm install -g --prefer-offline "@playwright/mcp@${MCP_VERSION}"

# Derived, not a second pin that could drift: browser downloads are keyed by revision,
# so a mismatch surfaces at run time as "browser not found". Read off the package just
# installed rather than with `npm view`, which always goes to the registry.
PW_VERSION="$(node -p "require('$(npm root -g)/@playwright/mcp/package.json').dependencies.playwright")"
npm install -g --prefer-offline "playwright@${PW_VERSION}"

# Browser binary only: OS deps come from the Dockerfile, and `--with-deps` needs root.
# A no-op once the persisted volume holds this revision.
playwright install chromium
