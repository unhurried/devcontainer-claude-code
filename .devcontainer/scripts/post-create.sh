#!/usr/bin/env bash
set -euo pipefail

# Install the Playwright MCP server and its browser (see .mcp.json). This runs
# here rather than in the Dockerfile because npm only exists after the Node
# devcontainer feature installs, which happens once the image is already built.

# Pinned deliberately: .npmrc sets min-release-age=7, so `@latest` fails
# whenever the newest release is less than a week old.
MCP_VERSION=0.0.79

# @playwright/mcp needs one exact playwright build — browser downloads are keyed
# by revision, so a mismatch surfaces at run time as "browser not found". Derive
# the version instead of keeping a second pin that can silently drift.
PW_VERSION="$(npm view "@playwright/mcp@${MCP_VERSION}" dependencies.playwright)"

# Installed globally so starting the MCP server needs no network (no npx fetch).
npm install -g "@playwright/mcp@${MCP_VERSION}" "playwright@${PW_VERSION}"

# Browser binary only: the OS dependencies come from the Dockerfile, and
# `--with-deps` would need root that the vscode user doesn't have.
playwright install chromium
