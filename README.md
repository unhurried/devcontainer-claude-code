# devcontainer-claude-code

Devcontainer configuration for Claude Code

## Usage

1. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) for VS Code.
2. Run `Dev Containers: Reopen in Container` from the command palette.

On first creation, the Node.js / Python / Docker-in-Docker / Claude Code features are set up. The egress firewall, which only allows traffic to GitHub's published IP ranges plus the domains listed in `.devcontainer/scripts/allowed-domains.txt`, is disabled by default.

- To enable the firewall, set `INIT_FIREWALL=true` on the host before opening/rebuilding the container. Once enabled, it is (re-)applied on every container start.
- To add or change allowed domains, edit `.devcontainer/scripts/allowed-domains.txt` and rebuild the container. Changes only take effect after a rebuild, since the file is installed outside the workspace by `onCreateCommand`.
