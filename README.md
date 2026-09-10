# devcontainer-claude-code

Devcontainer configuration for Claude Code

## Usage

1. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) for VS Code.
2. Run `Dev Containers: Reopen in Container` from the command palette.

On first creation, the Node.js / Python / Docker-in-Docker / Claude Code features are set up. Egress is restricted at all times: the container sits on an `internal` Docker network with no route to the internet, and the only way out is a squid forward proxy running in a separate container that allows the hostnames listed in `.devcontainer/proxy/allowed-domains.txt`.

- Filtering is by **hostname**, not IP, so CDN address changes cannot break it. A leading dot covers subdomains: `.github.com` matches `github.com`, `api.github.com` and `codeload.github.com`.
- To change what is reachable, edit `.devcontainer/proxy/allowed-domains.txt` and rebuild. The list is baked into the proxy image, which the dev container cannot reach, so a process inside cannot widen its own egress.
- A blocked request gets a squid 403 naming the domain, rather than failing silently.
- The domain allowlist itself can be switched off without touching the network topology: copy `.devcontainer/.env.example` to `.devcontainer/.env`, set `PROXY_MODE=open` there and rebuild (default is `allowlist`). `.env` is gitignored, so it is yours to edit without it showing up in a commit; the template is the file to change when the default should move for everyone. squid then allows any destination, but the dev container still has no route out except through squid — this loosens *which domains* are reachable, not the structural isolation below. `verify-isolation.sh` reads the same variable so it doesn't flag an unlisted host answering as a failure while `open` is set.
- Isolation is structural, not a firewall rule: there is no default route out of the dev container, so root and `--privileged` nested containers are equally contained. `.devcontainer/scripts/verify-isolation.sh` asserts this on every container start and fails the start if isolation is genuinely broken; a network that is merely unreachable is reported as a warning and the container still opens.
- Nested containers do not inherit the proxy. Image pulls work because the in-container Docker daemon picks up the proxy variables from its own environment, but a process started by `docker run` gets none of them and will hang until timeout on any network access. Pass them explicitly when you need egress from a nested container: `docker run -e HTTPS_PROXY=http://proxy:3128 -e HTTP_PROXY=http://proxy:3128 ...`.
- `.devcontainer/tests/` holds the proxy ACL and compose topology tests. Both need the in-container Docker daemon; run them with `.devcontainer/tests/test-proxy-acl.sh` and `.devcontainer/tests/test-compose-topology.sh`.

## Rebuilds

The image build talks to the internet directly — it runs on the host's Docker daemon, not on the isolated network — so it is not what makes a rebuild slow. Everything after it is: `postCreateCommand` and the VS Code server install go through squid, and between them they would fetch several hundred megabytes on every rebuild.

- Five named volumes in `.devcontainer/devcontainer.json` stop that repeating: `~/.claude` and `/commandhistory` hold state, and `~/.cache/ms-playwright` (~650MB of browsers), `~/.npm` and `~/.vscode-server` hold caches that are otherwise re-downloaded in full. Their names carry `${devcontainerId}`, so they belong to this workspace and survive any number of rebuilds. `docker volume ls | grep claude-code-` finds them; remove one to force that part to be fetched again.
- The mount points are created in the `Dockerfile` before the volumes cover them. That is not cosmetic: a named volume inherits the ownership of the image directory underneath it, and a mount point Docker has to create itself is root-owned — which `npm` and `playwright`, running as `vscode`, cannot write to.
- The Node and Python versions are pinned in `devcontainer.json` instead of tracking `latest`, so a rebuild reproduces the toolchain it replaced rather than picking up whatever is newest that day. Both upstreams keep old releases, so a stale pin still builds; bump it deliberately. Docker-in-Docker is deliberately left on `latest`, because moby comes from an apt repo that drops old versions.

## Browser automation (Playwright MCP)

The [Playwright MCP](https://github.com/microsoft/playwright-mcp) server is registered in `.mcp.json` and enabled for this project, so Claude Code can drive a browser out of the box. Chromium and its OS dependencies are installed automatically — the shared libraries at image build time (`Dockerfile`), the browser binary on container creation (`post-create.sh`). The browser lives in a persisted volume, so only the first creation downloads it.

- The browser runs headless with `--no-sandbox`. The `dev` service is `privileged: true`, so Chromium's own sandbox would in fact start, but it adds nothing here — the container is already the boundary, and it has no route off the isolated network. `shm_size: 1gb` is set on the `dev` service in `.devcontainer/docker-compose.yml` because Chromium crashes with Docker's default 64 MB `/dev/shm`.
- The MCP server version is pinned as `MCP_VERSION` in `.devcontainer/scripts/post-create.sh`; the matching Playwright version is derived from it. Pinning is required because `.npmrc` sets `min-release-age=7`, which rejects releases published within the last week. Bump `MCP_VERSION` and rebuild to upgrade.
- **General web browsing does not work.** Only the hostnames in `.devcontainer/proxy/allowed-domains.txt` are reachable, so any site you want to visit has to be added there followed by a rebuild. Chromium does not read `HTTPS_PROXY`, so `.mcp.json` passes `--proxy-server=http://proxy:3128` explicitly.

## Voice input (`/voice`)

Claude Code records through SoX's `rec`, which needs a PulseAudio server. VS Code forwards X11 and Wayland into a devcontainer but never audio, so the host's socket has to be bind-mounted — and only the host knows whether one exists. `.devcontainer/scripts/detect-audio.sh` runs there as `initializeCommand` and writes `.devcontainer/docker-compose.audio.yml`, a second compose file layered over the first:

- On **WSL2**, WSLg's `/mnt/wslg/PulseServer` is found and mounted, and `PULSE_SERVER` is set. `/voice` works.
- On **any other host**, the override is an empty `services: {dev: {}}`. The container builds and runs exactly as before; only `/voice` reports no recorder.
- To point it at a socket the probe does not know, export `VOICE_PULSE_SOCKET=/path/to/socket` on the host before opening the container. A path that is not a socket warns and is ignored rather than failing the build.

The generated file is gitignored and rewritten on every start, so a host that gains or loses its socket is picked up on the next rebuild. If you drive compose by hand rather than through VS Code, pass both files (`-f docker-compose.yml -f docker-compose.audio.yml`) or run the script first — the base file alone is valid and simply has no audio.

`initializeCommand` needs a POSIX shell **on the host**: open the workspace from inside WSL, not from Windows. SoX and its pulse backend are installed in the image (`Dockerfile`).

Troubleshooting on WSL2:

- Confirm the host side first — `/mnt/wslg/PulseServer` must exist in the WSL distro and `rec` must record there. Windows' own microphone privacy settings apply.
- Inside the container, `rec --version` must exit 0. That exact probe is what voice mode uses to decide a recorder exists, which is why a missing server surfaces as "could not find a working audio recorder" even with SoX installed. Then `rec -q -t wav /tmp/t.wav trim 0 3 && play /tmp/t.wav`.
- With Docker Desktop the bind source is resolved inside the `docker-desktop` distro, where the socket may not be visible. If the script reports a mount but `/mnt/wslg/PulseServer` is absent in the container, that is why; a daemon running natively in the WSL distro does not have this problem.
- Routing PulseAudio over TCP instead is not an option here: the `dev` service has no route to the host, so the Unix socket is the only path.
