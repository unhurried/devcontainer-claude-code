#!/usr/bin/env bash
# Install the Claude Code and Codex config at user scope so it applies inside repos/
# too. Runs on every container start, so edits need no rebuild.
#
# Sources (tracked)                     Destination (persisted volume)
#   .devcontainer/claude/settings.json    ~/.claude/settings.json      merged in
#   .devcontainer/agents/skills/<name>/   ~/.claude/skills/<name>      symlinked
#                                         ~/.agents/skills/<name>      symlinked (Codex)
#   .devcontainer/agents/AGENTS.md        ~/.claude/CLAUDE.md          symlinked
#                                         ~/.codex/AGENTS.md           symlinked
#   the MCP definition below              ~/.claude/.claude.json       via claude mcp
#                                         ~/.codex/config.toml         via codex mcp
#   .devcontainer/codex/config.toml       /etc/codex/managed_config.toml (Dockerfile)
set -euo pipefail

WORKSPACE="${1:?usage: sync-agent-config.sh <workspace folder>}"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
AGENTS_SRC="$WORKSPACE/.devcontainer/agents"
TEMPLATE="$WORKSPACE/.devcontainer/claude/settings.json"
SETTINGS="$CONFIG_DIR/settings.json"

# Not a tracked .gitkeep: the .gitignore negation that needs would hide the
# repositories from ripgrep (see README).
mkdir -p "$WORKSPACE/repos"

# --- settings.json ------------------------------------------------------------------
# Merged, not copied: Claude Code writes its own keys here. Template keys win; a key
# dropped from the template lingers.
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

# --- skills and global instructions -------------------------------------------------
# Symlinked so edits are live. A real file or directory of the same name is someone's
# own and is left alone.
link() {
  local src="$1" dst="$2"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    echo "WARN  - $dst exists and is not a symlink; not replacing it with $src" >&2
    return
  fi
  if [ "$(readlink "$dst" 2>/dev/null)" != "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    ln -sfn "$src" "$dst"
    echo "Linked $dst -> $src"
  fi
}

for src in "$AGENTS_SRC"/skills/*/; do
  [ -d "$src" ] || continue
  src="${src%/}"
  name="$(basename "$src")"
  link "$src" "$CONFIG_DIR/skills/$name"
  link "$src" "$HOME/.agents/skills/$name"
done

link "$AGENTS_SRC/AGENTS.md" "$CONFIG_DIR/CLAUDE.md"
link "$AGENTS_SRC/AGENTS.md" "$CODEX_DIR/AGENTS.md"

# --- MCP servers --------------------------------------------------------------------
# One definition, registered with both agents. Chromium ignores HTTPS_PROXY, so the
# proxy is passed explicitly.
MCP_NAME=playwright
MCP_COMMAND=playwright-mcp
MCP_ARGS=(--browser chromium --headless --no-sandbox "--proxy-server=${HTTPS_PROXY:?}")
want_args="$(jq -nc '$ARGS.positional' --args -- "${MCP_ARGS[@]}")"

# Neither `mcp add` overwrites, so replace only on change.
if ! jq -e --arg name "$MCP_NAME" --arg cmd "$MCP_COMMAND" --argjson args "$want_args" \
     '.mcpServers[$name] | .command == $cmd and .args == $args' \
     "$CONFIG_DIR/.claude.json" >/dev/null 2>&1; then
  claude mcp remove -s user "$MCP_NAME" >/dev/null 2>&1 || true
  claude mcp add -s user "$MCP_NAME" -- "$MCP_COMMAND" "${MCP_ARGS[@]}"
fi

if command -v codex >/dev/null 2>&1; then
  if ! codex mcp get "$MCP_NAME" --json 2>/dev/null \
       | jq -e --arg cmd "$MCP_COMMAND" --argjson args "$want_args" \
           '.transport | .command == $cmd and .args == $args' >/dev/null 2>&1; then
    codex mcp remove "$MCP_NAME" >/dev/null 2>&1 || true
    codex mcp add "$MCP_NAME" -- "$MCP_COMMAND" "${MCP_ARGS[@]}"
  fi
else
  echo "WARN  - codex not found; skipping its MCP registration" >&2
fi
