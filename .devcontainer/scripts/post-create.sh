#!/usr/bin/env bash
set -euo pipefail

workspace_dir="${1:-/workspaces/devcontainer-claude-code}"
template_dir="${workspace_dir}/.devcontainer"
claude_home="${HOME}/.claude"

# Native install (not the devcontainer feature) so Claude Code's built-in auto-update works.
curl -fsSL https://claude.ai/install.sh | bash

install -d -m 0755 "${claude_home}"
install -m 0644 "${template_dir}/claude/claude.json" "${HOME}/.claude.json"
install -m 0644 "${template_dir}/.npmrc" "${HOME}/.npmrc"
