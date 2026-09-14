#!/usr/bin/env bash
# Install the Claude Code config at user scope (~/.claude), so it applies wherever
# Claude Code is started -- including inside repos/. Runs on every container start,
# so edits need no rebuild.
#
# Sources (tracked)                     Destination (persisted volume)
#   .devcontainer/claude/settings.json    ~/.claude/settings.json      merged in
#   .devcontainer/claude/skills/<name>/   ~/.claude/skills/<name>      symlinked
#   the MCP definition below              ~/.claude/.claude.json       via claude mcp
set -euo pipefail

WORKSPACE="${1:?usage: sync-claude-config.sh <workspace folder>}"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TEMPLATE="$WORKSPACE/.devcontainer/claude/settings.json"
SETTINGS="$CONFIG_DIR/settings.json"

# Where repositories to work on are cloned. Created here rather than tracked with a
# .gitkeep: the .gitignore negation that needs would make ripgrep (and Claude Code's
# search) skip the repositories.
mkdir -p "$WORKSPACE/repos"

# --- settings.json ------------------------------------------------------------------
# Merged, not copied: Claude Code writes its own keys (model, theme, ...) here.
# Template keys win. A key removed from the template lingers until removed by hand.
existing='{}'
if [ -s "$SETTINGS" ]; then
  if ! existing="$(jq -S . "$SETTINGS" 2>/dev/null)"; then
    backup="$SETTINGS.invalid-$(date +%Y%m%d%H%M%S)"
    echo "WARN  - $SETTINGS is not valid JSON; moved to $backup" >&2
    mv "$SETTINGS" "$backup"
    existing='{}'
  fi
fi
merged="$(jq -S --argjson existing "$existing" '$existing * .' "$TEMPLATE")"
if [ "$existing" != "$merged" ]; then
  tmp="$(mktemp "$CONFIG_DIR/.settings.json.XXXXXX")"
  printf '%s\n' "$merged" > "$tmp"
  mv "$tmp" "$SETTINGS"
  echo "Updated $SETTINGS from $TEMPLATE"
fi

# --- skills -------------------------------------------------------------------------
# Symlinked so edits to the source are live. A real directory of the same name is
# someone's own skill and is left alone.
mkdir -p "$CONFIG_DIR/skills"
for src in "$WORKSPACE"/.devcontainer/claude/skills/*/; do
  [ -d "$src" ] || continue
  src="${src%/}"
  dst="$CONFIG_DIR/skills/$(basename "$src")"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    echo "WARN  - $dst exists and is not a symlink; not replacing it with $src" >&2
    continue
  fi
  if [ "$(readlink "$dst" 2>/dev/null)" != "$src" ]; then
    ln -sfn "$src" "$dst"
    echo "Linked $dst -> $src"
  fi
done

# --- MCP servers --------------------------------------------------------------------
# Playwright. Chromium ignores HTTPS_PROXY, so the proxy (set in docker-compose.yml)
# is passed explicitly.
MCP_NAME=playwright
MCP_COMMAND=playwright-mcp
MCP_ARGS=(--browser chromium --headless --no-sandbox "--proxy-server=${HTTPS_PROXY:?}")

# `claude mcp add` refuses to overwrite, so compare first and replace only on change.
want_args="$(jq -nc '$ARGS.positional' --args -- "${MCP_ARGS[@]}")"
if ! jq -e --arg name "$MCP_NAME" --arg cmd "$MCP_COMMAND" --argjson args "$want_args" \
     '.mcpServers[$name] | .command == $cmd and .args == $args' \
     "$CONFIG_DIR/.claude.json" >/dev/null 2>&1; then
  claude mcp remove -s user "$MCP_NAME" >/dev/null 2>&1 || true
  claude mcp add -s user "$MCP_NAME" -- "$MCP_COMMAND" "${MCP_ARGS[@]}"
fi
