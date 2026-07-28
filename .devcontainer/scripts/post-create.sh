#!/usr/bin/env bash
set -euo pipefail

workspace_dir="${1:-/workspaces/devcontainer-claude-code}"
template_dir="${workspace_dir}/.devcontainer"
claude_home="${HOME}/.claude"

install -d -m 0755 "${claude_home}"
install -m 0644 "${template_dir}/claude/settings.json" "${claude_home}/settings.json"
install -m 0644 "${template_dir}/claude/claude.json" "${HOME}/.claude.json"
install -m 0644 "${template_dir}/.npmrc" "${HOME}/.npmrc"
