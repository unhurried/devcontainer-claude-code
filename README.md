# devcontainer-claude-code

Devcontainer configuration for Claude Code

## Usage

1. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) for VS Code.
2. Run `Dev Containers: Reopen in Container` from the command palette.

On first creation, the Node.js / Python / Docker-in-Docker / Claude Code features are set up. The egress firewall, which only allows traffic to GitHub's published IP ranges plus the domains listed in `.devcontainer/scripts/allowed-domains.txt`, is disabled by default.

- To enable the firewall, set `INIT_FIREWALL=true` on the host before opening/rebuilding the container. Once enabled, it is (re-)applied on every container start.
- To add or change allowed domains, edit `.devcontainer/scripts/allowed-domains.txt` and rebuild the container. Changes only take effect after a rebuild, since the file is installed outside the workspace by `onCreateCommand`.

## Browser automation (Playwright MCP)

The [Playwright MCP](https://github.com/microsoft/playwright-mcp) server is registered in `.mcp.json` and enabled for this project, so Claude Code can drive a browser out of the box. Chromium and its OS dependencies are installed automatically — the shared libraries at image build time (`Dockerfile`), the browser binary on container creation (`post-create.sh`).

- The browser runs headless with `--no-sandbox`, since the container has no display and no `SYS_ADMIN` capability. `--shm-size=1g` is set in `runArgs` because Chromium crashes with Docker's default 64 MB `/dev/shm`.
- The MCP server version is pinned as `MCP_VERSION` in `.devcontainer/scripts/post-create.sh`; the matching Playwright version is derived from it. Pinning is required because `.npmrc` sets `min-release-age=7`, which rejects releases published within the last week. Bump `MCP_VERSION` and rebuild to upgrade.
- **With the firewall enabled, general web browsing does not work.** Only GitHub's ranges and the domains in `.devcontainer/scripts/allowed-domains.txt` are reachable, so any site you want to visit has to be added there followed by a rebuild.
