#!/usr/bin/env bash
# Install the Claude Code guardrails at user scope. Runs as postStartCommand so an edit
# to the tracked sources below takes effect on the next container start, no rebuild.
#
# Why user scope: project-scope settings (.claude/settings.json, .mcp.json) are read
# from the directory Claude Code is started in, and nothing else. Started in repos/ or
# inside one of the repositories cloned there, this repo's project settings would not
# apply -- so the sandbox, permission mode, hooks and MCP server that make this a safe
# environment live in ~/.claude instead, which every start location sees.
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

# Where repositories to work on are cloned. Gitignored, and created here rather than
# tracked with a .gitkeep: the negation that would need (`repos/*` + `!repos/.gitkeep`)
# makes ripgrep -- and with it Claude Code's search -- skip the repositories even when
# started from inside repos/. A plain `repos/` only hides them from a search started at
# this repo's root.
mkdir -p "$WORKSPACE/repos"

# --- settings.json ------------------------------------------------------------------
# Merged, not copied: Claude Code writes its own keys here (model, theme, voice, ...)
# and those must survive. The template wins for every key it defines -- arrays included,
# so the permission lists are exactly the tracked ones -- and everything else is kept.
# Consequence: a key *removed* from the template lingers in ~/.claude/settings.json
# until removed there by hand.
existing='{}'
if [ -s "$SETTINGS" ]; then
  if ! existing="$(jq -c . "$SETTINGS" 2>/dev/null)"; then
    backup="$SETTINGS.invalid-$(date +%Y%m%d%H%M%S)"
    echo "WARN  - $SETTINGS is not valid JSON; moved to $backup" >&2
    mv "$SETTINGS" "$backup"
    existing='{}'
  fi
fi
merged="$(jq -S --argjson existing "$existing" '$existing * .' "$TEMPLATE")"
if [ "$(jq -S . <<<"$existing")" != "$merged" ]; then
  tmp="$(mktemp "$CONFIG_DIR/.settings.json.XXXXXX")"
  printf '%s\n' "$merged" > "$tmp"
  mv "$tmp" "$SETTINGS"
  echo "Updated $SETTINGS from $TEMPLATE"
fi

# --- skills -------------------------------------------------------------------------
# Symlinked, not copied: Claude Code only reads skills, so an edit to the tracked source
# is live at once. An existing real directory of the same name is someone's own skill
# and is left alone (with a warning) rather than replaced.
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
# Playwright, as .mcp.json used to define it. Chromium does not read HTTPS_PROXY, so the
# proxy is passed explicitly. The server binary is installed by post-create.sh.
MCP_NAME=playwright
MCP_COMMAND=playwright-mcp
MCP_ARGS=(--browser chromium --headless --no-sandbox --proxy-server=http://proxy:3128)

# `claude mcp add` refuses to touch an existing entry, so compare first and replace only
# on a real change; that keeps a routine start from rewriting .claude.json.
want_args="$(printf '%s\n' "${MCP_ARGS[@]}" | jq -R . | jq -sc .)"
if ! jq -e --arg name "$MCP_NAME" --arg cmd "$MCP_COMMAND" --argjson args "$want_args" \
     '.mcpServers[$name] | .command == $cmd and .args == $args' \
     "$CONFIG_DIR/.claude.json" >/dev/null 2>&1; then
  claude mcp remove -s user "$MCP_NAME" >/dev/null 2>&1 || true
  claude mcp add -s user "$MCP_NAME" -- "$MCP_COMMAND" "${MCP_ARGS[@]}"
fi
