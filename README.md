# devcontainer-claude-code

Devcontainer configuration for Claude Code.

## Usage

1. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) for VS Code.
2. Run `Dev Containers: Reopen in Container` from the command palette.

The first build sets up Node.js, Python, Docker-in-Docker and Claude Code.

## Network isolation

The dev container sits on an `internal` Docker network with no route to the internet. The only way out is a squid proxy in a separate container, which allows the hostnames listed in `.devcontainer/proxy/allowed-domains.txt`.

- **Change what is reachable:** edit `allowed-domains.txt` and rebuild. A leading dot covers subdomains (`.github.com` matches `api.github.com`). A blocked request gets a squid 403 naming the domain.
- **Switch the allowlist off:** copy `.devcontainer/.env.example` to `.devcontainer/.env`, set `PROXY_MODE=open`, rebuild. Any hostname is then allowed (raw IPs are still refused); the network isolation itself is unchanged. `.env` is gitignored.
- **Nested containers** do not inherit the proxy and cannot resolve `proxy` by name. Pass it by address:
  ```sh
  P=http://$(getent hosts proxy | awk '{print $1}'):3128
  docker run -e HTTPS_PROXY=$P -e HTTP_PROXY=$P ...
  docker build --build-arg http_proxy=$P --build-arg https_proxy=$P ...
  ```
- **Not an exfiltration barrier:** `.github.com`, `.githubusercontent.com`, `.github.io` and `storage.googleapis.com` accept user-supplied content. The list stops accidental access, not a hostile agent holding a token.
- `.devcontainer/scripts/verify-isolation.sh` checks the isolation on every container start and fails the start if it is broken.
- Tests (need the in-container Docker daemon): `.devcontainer/tests/test-proxy-acl.sh`, `.devcontainer/tests/test-compose-topology.sh`.

Design notes:

- Filtering is by hostname, so CDN IP changes cannot break it. The list is baked into the proxy image, which the dev container cannot reach, so a process inside cannot widen its own egress.
- Isolation is structural (no default route), so root and `--privileged` nested containers are equally contained.
- Claude Code's Sentry and Statsig telemetry are off (`DISABLE_ERROR_REPORTING`, `DISABLE_TELEMETRY` in `docker-compose.yml`); the auto-updater stays on.
- `NO_PROXY` covers localhost and the private ranges, so nested containers are reachable by address.
- The proxy container drops every capability squid does not need and runs with `no-new-privileges`. Plain-HTTP requests leave without `Via` or `X-Forwarded-For`.

## Working on other repositories

Clone them under `repos/`. It is created on container start, visible to the host, and gitignored here, so nested repositories never show up in this repo's `git status`.

- Start Claude Code **inside the repository**, or in `repos/` to work across several. Do not start it at this repo's root: the ignore entry hides `repos/` from its search, and git features would target this repo.
- The gitignore entry is a plain `repos/` on purpose: a `repos/*` + `!repos/.gitkeep` pair makes ripgrep (and Claude Code's search) skip the repositories.
- VS Code's Source Control view finds them because `git.repositoryScanMaxDepth` is 2 in `devcontainer.json`.

## Claude Code settings

Settings, skills and the Playwright MCP server are installed at **user scope** (`~/.claude`, a persisted volume), so they apply under `repos/` too — project scope only applies to the directory Claude Code is started in.

- Source of truth: `.devcontainer/claude/settings.json` and `.devcontainer/claude/skills/<name>/`.
- `.devcontainer/scripts/sync-claude-config.sh` runs on every container start: merges the template into `~/.claude/settings.json` (template keys win, keys Claude Code writes itself survive), symlinks the skills, registers the MCP server. Edit and restart, or run the script by hand — no rebuild.
- A key *removed* from the template stays in `~/.claude/settings.json` until removed there by hand.
- The template is an ordinary tracked file, so the sandbox does not protect it. Review changes to it like changes to the proxy allowlist.

## Rebuilds

The image build itself is fast (it runs on the host's Docker daemon with direct internet). Everything after it goes through squid, so the large downloads are kept in named volumes: `~/.claude`, `/commandhistory`, `~/.cache/ms-playwright`, `~/.npm`, `~/.vscode-server`.

- `docker volume ls | grep claude-code-` lists them; remove one to force that part to be fetched again.
- The mount points are created in the `Dockerfile` so the volumes are owned by `vscode`, not root.
- Node and Python are pinned in `devcontainer.json`; bump deliberately. Docker-in-Docker tracks `latest` because moby's apt repo drops old versions.

## Package installs

Two npm guardrails are set container-wide in `docker-compose.yml`:

- `NPM_CONFIG_IGNORE_SCRIPTS=true` — install-time lifecycle scripts do not run. Use `npm rebuild <pkg>` for native addons that need them.
- `NPM_CONFIG_MIN_RELEASE_AGE=7` — versions published within the last week are refused, which is why `post-create.sh` pins versions instead of `@latest`.

## Browser automation (Playwright MCP)

The [Playwright MCP](https://github.com/microsoft/playwright-mcp) server is registered at user scope. Chromium and its OS dependencies are installed automatically (`Dockerfile`, `post-create.sh`) and the browser is kept in a volume.

- **Only allowlisted hosts are reachable.** Add a site to `allowed-domains.txt` and rebuild. Chromium ignores `HTTPS_PROXY`, so `--proxy-server=http://proxy:3128` is passed explicitly.
- Upgrade: bump `MCP_VERSION` in `.devcontainer/scripts/post-create.sh` and rebuild. The Playwright version is derived from it.
- Runs headless with `--no-sandbox`. `shm_size: 1gb` is set because Chromium crashes on Docker's default 64 MB `/dev/shm`.

## Voice input (`/voice`)

Claude Code records with SoX's `rec`, which needs a PulseAudio socket that VS Code does not forward. Set `VOICE_PULSE_SOCKET` in `.devcontainer/.env` to the host socket (WSL2: `/mnt/wslg/PulseServer`, see `.env.example`) and rebuild. Left unset, `/dev/null` is mounted instead and only `/voice` is unavailable.

Troubleshooting on WSL2:

- Host side: `/mnt/wslg/PulseServer` must exist in the WSL distro and `rec` must work there. Windows' microphone privacy settings apply.
- Container side: `rec --version` must exit 0 — that is voice mode's probe. Then `rec -q -t wav /tmp/t.wav trim 0 3 && play /tmp/t.wav`.
- Docker Desktop resolves the bind source inside the `docker-desktop` distro, where the socket may not be visible. A daemon running natively in the WSL distro does not have this problem.
- PulseAudio over TCP is not an option: the container has no route to the host.
