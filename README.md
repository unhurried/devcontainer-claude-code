# devcontainer-claude-code

Devcontainer configuration for Claude Code

## Usage

1. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) for VS Code.
2. Run `Dev Containers: Reopen in Container` from the command palette.

On first creation, the Node.js / Python / Docker-in-Docker / Claude Code features are set up. Egress is restricted at all times: the container sits on an `internal` Docker network with no route to the internet, and the only way out is a squid forward proxy running in a separate container that allows the hostnames listed in `.devcontainer/proxy/allowed-domains.txt`.

- Filtering is by **hostname**, not IP, so CDN address changes cannot break it. A leading dot covers subdomains: `.github.com` matches `github.com`, `api.github.com` and `codeload.github.com`.
- To change what is reachable, edit `.devcontainer/proxy/allowed-domains.txt` and rebuild. The list is baked into the proxy image, which the dev container cannot reach, so a process inside cannot widen its own egress.
- A blocked request gets a squid 403 naming the domain, rather than failing silently.
- Isolation is structural, not a firewall rule: there is no default route out of the dev container, so root and `--privileged` nested containers are equally contained. `.devcontainer/scripts/verify-isolation.sh` asserts this on every container start and fails the start if isolation is genuinely broken; a network that is merely unreachable is reported as a warning and the container still opens.
- Nested containers do not inherit the proxy. Image pulls work because the in-container Docker daemon picks up the proxy variables from its own environment, but a process started by `docker run` gets none of them and will hang until timeout on any network access. Pass them explicitly when you need egress from a nested container: `docker run -e HTTPS_PROXY=http://proxy:3128 -e HTTP_PROXY=http://proxy:3128 ...`.
- `.devcontainer/tests/` holds the proxy ACL and compose topology tests. Both need the in-container Docker daemon; run them with `.devcontainer/tests/test-proxy-acl.sh` and `.devcontainer/tests/test-compose-topology.sh`.

## Browser automation (Playwright MCP)

The [Playwright MCP](https://github.com/microsoft/playwright-mcp) server is registered in `.mcp.json` and enabled for this project, so Claude Code can drive a browser out of the box. Chromium and its OS dependencies are installed automatically — the shared libraries at image build time (`Dockerfile`), the browser binary on container creation (`post-create.sh`).

- The browser runs headless with `--no-sandbox`. The `dev` service is `privileged: true`, so Chromium's own sandbox would in fact start, but it adds nothing here — the container is already the boundary, and it has no route off the isolated network. `shm_size: 1gb` is set on the `dev` service in `.devcontainer/docker-compose.yml` because Chromium crashes with Docker's default 64 MB `/dev/shm`.
- The MCP server version is pinned as `MCP_VERSION` in `.devcontainer/scripts/post-create.sh`; the matching Playwright version is derived from it. Pinning is required because `.npmrc` sets `min-release-age=7`, which rejects releases published within the last week. Bump `MCP_VERSION` and rebuild to upgrade.
- **General web browsing does not work.** Only the hostnames in `.devcontainer/proxy/allowed-domains.txt` are reachable, so any site you want to visit has to be added there followed by a rebuild. Chromium does not read `HTTPS_PROXY`, so `.mcp.json` passes `--proxy-server=http://proxy:3128` explicitly.
