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

# Claude Code, through Anthropic's native installer rather than the devcontainer
# feature or `npm install -g`. The npm route cannot auto-update in this container, and
# fails three ways in turn: NPM_CONFIG_MIN_RELEASE_AGE (docker-compose.yml) refuses
# every release -- Claude Code ships daily, so `@latest` is never a week old;
# NPM_CONFIG_IGNORE_SCRIPTS skips the postinstall that swaps the shell stub in bin/ for
# the native binary, so an update that got through would leave `claude` unable to
# start; and the feature installs as root, so vscode could not replace the package
# anyway. The native install lives in ~/.local (share/claude/versions/, a bin/claude
# symlink), owned by vscode, and updates in place from downloads.claude.ai, which
# .claude.ai in the allowlist already covers.
#
# ~/.local is a persisted volume (devcontainer.json), so this only downloads once;
# afterwards the auto-updater keeps it current and a rebuild finds it in place.
if [ ! -x "$HOME/.local/bin/claude" ]; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

# Install the Playwright MCP server and its browser; sync-claude-config.sh registers it
# with Claude Code. Not in the Dockerfile: npm exists only after the Node feature installs.
#
# This is the slowest thing a rebuild does -- it is the one step that pulls hundreds of
# megabytes through the proxy. Both caches it needs are persisted volumes
# (devcontainer.json), so on a rebuild the packages resolve from ~/.npm and the browser
# is already in ~/.cache/ms-playwright: no download, no network.

# Pinned: NPM_CONFIG_MIN_RELEASE_AGE (docker-compose.yml) makes `@latest` fail on a
# release younger than a week.
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
