# devcontainer-claude-code

Devcontainer configuration for Claude Code

## Usage

1. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) for VS Code.
2. Run `Dev Containers: Reopen in Container` from the command palette.

On first creation, the Node.js / Python / Docker-in-Docker / Claude Code features are set up. Egress is restricted at all times: the container sits on an `internal` Docker network with no route to the internet, and the only way out is a squid forward proxy running in a separate container that allows the hostnames listed in `.devcontainer/proxy/allowed-domains.txt`.

- Filtering is by **hostname**, not IP, so CDN address changes cannot break it. A leading dot covers subdomains: `.github.com` matches `github.com`, `api.github.com` and `codeload.github.com`.
- To change what is reachable, edit `.devcontainer/proxy/allowed-domains.txt` and rebuild. The list is baked into the proxy image, which the dev container cannot reach, so a process inside cannot widen its own egress.
- A blocked request gets a squid 403 naming the domain, rather than failing silently.
- The domain allowlist itself can be switched off without touching the network topology: copy `.devcontainer/.env.example` to `.devcontainer/.env`, set `PROXY_MODE=open` there and rebuild (default is `allowlist`). `.env` is gitignored, so it is yours to edit without it showing up in a commit; the template is the file to change when the default should move for everyone. squid then allows any hostname (raw IP addresses stay refused), but the dev container still has no route out except through squid — this loosens *which domains* are reachable, not the structural isolation below. `verify-isolation.sh` reads the same variable so it doesn't flag an unlisted host answering as a failure while `open` is set.
- Isolation is structural, not a firewall rule: there is no default route out of the dev container, so root and `--privileged` nested containers are equally contained. `.devcontainer/scripts/verify-isolation.sh` asserts this on every container start and fails the start if isolation is genuinely broken; a network that is merely unreachable is reported as a warning and the container still opens.
- Nested containers do not inherit the proxy. Image pulls work because the in-container Docker daemon picks up the proxy variables from its own environment, but a process started by `docker run` gets none of them and will hang until timeout on any network access. Pass them explicitly when you need egress from a nested container, **by address, not name**: a nested container's DNS goes to public resolvers it cannot reach, so `proxy` does not resolve there. `docker run -e HTTPS_PROXY=http://$(getent hosts proxy | awk '{print $1}'):3128 -e HTTP_PROXY=http://$(getent hosts proxy | awk '{print $1}'):3128 ...`. `docker build` needs the same as `--build-arg http_proxy=... --build-arg https_proxy=...` for its `RUN` steps.
- The proxy container runs with every capability dropped except the five squid needs to set up its log and drop to its own user (`cap_drop`/`cap_add` in `docker-compose.yml`), plus `no-new-privileges`. Plain-HTTP requests leave without `Via` or `X-Forwarded-For`, so the dev container's address stays inside.
- What the allowlist is not: an exfiltration barrier. `.github.com`, `.githubusercontent.com`, `.github.io` and `storage.googleapis.com` all accept or serve user-supplied content, so a process holding credentials can still move data out through them. The list stops accidental and unlisted access; it does not contain a hostile agent with a token.
- Claude Code's Sentry error reports and Statsig telemetry are switched off with `DISABLE_ERROR_REPORTING` and `DISABLE_TELEMETRY` in `docker-compose.yml`, so neither host is in the allowlist. Not the broader `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`: that would also stop the auto-updater that `settings.json` enables.
- `NO_PROXY` covers the private ranges as well as localhost, so a container started by the in-container Docker daemon is reachable by its address without squid being asked to dial it.
- `.devcontainer/tests/` holds the proxy ACL and compose topology tests. Both need the in-container Docker daemon; run them with `.devcontainer/tests/test-proxy-acl.sh` and `.devcontainer/tests/test-compose-topology.sh`.

## Working on other repositories

Clone the repositories you actually work on under `repos/`. It is created on container start, sits inside the bind-mounted workspace so the host sees it too, and is gitignored here, so a repository nested in it is invisible to this repo's `git status` and cannot be swallowed by a stray `git add .`.

- The gitignore entry is a plain `repos/`, deliberately without a tracked `.gitkeep`: the negation that would need (`repos/*` + `!repos/.gitkeep`) makes ripgrep — and with it Claude Code's search — skip the repositories even when started from inside `repos/`.
- Start Claude Code **inside the repository** for repository-scoped work (commits, worktrees, `/code-review`), and in `repos/` to work across several at once. Both places see the guardrails below because they live at user scope. Do not start it at this repo's root to work on `repos/`: the ignore entry hides everything under it from Claude Code's search there, and the git-integrated features would target this repo instead.
- The VS Code Source Control view picks the repositories up because `git.repositoryScanMaxDepth` is raised to 2 in `devcontainer.json`.

## Claude Code settings

The permission mode, allow/ask lists, sandbox, notification hooks, skills and the Playwright MCP server are installed at **user scope** (`~/.claude`, a persisted volume), not as project settings of this repo. Project settings and skills are read only from the directory Claude Code is started in (only `CLAUDE.md` is looked up in parent directories), so they would not apply in `repos/` or in a repository cloned there — which is where the work happens.

- `.devcontainer/claude/settings.json` is the tracked source. `.devcontainer/scripts/sync-claude-config.sh` merges it into `~/.claude/settings.json` on every container start (`postStartCommand`): every key the template defines wins, arrays included, and keys Claude Code writes there itself (model, theme, voice, ...) survive. Edit the template and restart the container, or run the script by hand — no rebuild. A key *removed* from the template lingers in `~/.claude/settings.json` until removed there by hand.
- Skills live in `.devcontainer/claude/skills/<name>/` and are symlinked into `~/.claude/skills/` by the same script, so an edit is live immediately. They apply in every repository; a repository with conventions of its own states them in its `CLAUDE.md` or `.claude/skills/`, which Claude Code reads alongside. A real directory already present under `~/.claude/skills/` with the same name is left alone with a warning.
- The same script registers the Playwright MCP server at user scope (`claude mcp add -s user`), replacing the entry only when its command line differs from the one in the script.
- Claude Code's sandbox refuses writes to the live `~/.claude/settings.json`, but not to the template — it is an ordinary tracked file, like the rest of `.devcontainer/`. Review changes to it the same way you would review a change to the proxy allowlist.

## Rebuilds

The image build talks to the internet directly — it runs on the host's Docker daemon, not on the isolated network — so it is not what makes a rebuild slow. Everything after it is: `postCreateCommand` and the VS Code server install go through squid, and between them they would fetch several hundred megabytes on every rebuild.

- Five named volumes in `.devcontainer/devcontainer.json` stop that repeating: `~/.claude` and `/commandhistory` hold state, and `~/.cache/ms-playwright` (~650MB of browsers), `~/.npm` and `~/.vscode-server` hold caches that are otherwise re-downloaded in full. Their names carry `${devcontainerId}`, so they belong to this workspace and survive any number of rebuilds. `docker volume ls | grep claude-code-` finds them; remove one to force that part to be fetched again.
- The mount points are created in the `Dockerfile` before the volumes cover them. That is not cosmetic: a named volume inherits the ownership of the image directory underneath it, and a mount point Docker has to create itself is root-owned — which `npm` and `playwright`, running as `vscode`, cannot write to.
- The Node and Python versions are pinned in `devcontainer.json` instead of tracking `latest`, so a rebuild reproduces the toolchain it replaced rather than picking up whatever is newest that day. Both upstreams keep old releases, so a stale pin still builds; bump it deliberately. Docker-in-Docker is deliberately left on `latest`, because moby comes from an apt repo that drops old versions.

## Package installs

Two npm guardrails are set as environment variables in `docker-compose.yml`, so they apply to every `npm` invocation in the container -- a project `.npmrc` is read only inside its own tree and never in global mode, so it would cover neither `npm install -g` in `post-create.sh` nor a repository under `repos/` that has a `package.json` of its own.

- `NPM_CONFIG_IGNORE_SCRIPTS=true`: install-time lifecycle scripts do not run. A package with a native addon that relies on them needs `npm rebuild <pkg>` (or `npm ci --ignore-scripts=false` when you have reviewed what runs) after install.
- `NPM_CONFIG_MIN_RELEASE_AGE=7`: a version published within the last week is refused, which is why the versions in `post-create.sh` are pinned rather than `@latest`.

## Browser automation (Playwright MCP)

The [Playwright MCP](https://github.com/microsoft/playwright-mcp) server is registered at user scope by `.devcontainer/scripts/sync-claude-config.sh` (see [Claude Code settings](#claude-code-settings)), so Claude Code can drive a browser out of the box wherever it is started. Chromium and its OS dependencies are installed automatically — the shared libraries at image build time (`Dockerfile`), the browser binary on container creation (`post-create.sh`). The browser lives in a persisted volume, so only the first creation downloads it.

- The browser runs headless with `--no-sandbox`. The `dev` service is `privileged: true`, so Chromium's own sandbox would in fact start, but it adds nothing here — the container is already the boundary, and it has no route off the isolated network. `shm_size: 1gb` is set on the `dev` service in `.devcontainer/docker-compose.yml` because Chromium crashes with Docker's default 64 MB `/dev/shm`.
- The MCP server version is pinned as `MCP_VERSION` in `.devcontainer/scripts/post-create.sh`; the matching Playwright version is derived from it. Pinning is required because `NPM_CONFIG_MIN_RELEASE_AGE=7` (see [Package installs](#package-installs)) rejects releases published within the last week. Bump `MCP_VERSION` and rebuild to upgrade.
- **General web browsing does not work.** Only the hostnames in `.devcontainer/proxy/allowed-domains.txt` are reachable, so any site you want to visit has to be added there followed by a rebuild. Chromium does not read `HTTPS_PROXY`, so the MCP definition in `sync-claude-config.sh` passes `--proxy-server=http://proxy:3128` explicitly.

## Voice input (`/voice`)

Claude Code records through SoX's `rec`, which needs a PulseAudio server. VS Code forwards X11 and Wayland into a devcontainer but never audio, so the host's socket has to be bind-mounted. `docker-compose.yml` mounts `${VOICE_PULSE_SOCKET:-/dev/null}` at `/mnt/wslg/PulseServer` and points `PULSE_SERVER` there:

- Set `VOICE_PULSE_SOCKET` in `.devcontainer/.env` to the host socket and rebuild. On **WSL2** that is WSLg's `/mnt/wslg/PulseServer`; `.env.example` has the line to uncomment. `/voice` works.
- Leave it unset and `/dev/null` is mounted instead, so the bind source always exists and the container starts on any host; only `/voice` reports no recorder.

SoX and its pulse backend are installed in the image (`Dockerfile`).

Troubleshooting on WSL2:

- Confirm the host side first — `/mnt/wslg/PulseServer` must exist in the WSL distro and `rec` must record there. Windows' own microphone privacy settings apply.
- Inside the container, `rec --version` must exit 0. That exact probe is what voice mode uses to decide a recorder exists, which is why a missing server surfaces as "could not find a working audio recorder" even with SoX installed. Then `rec -q -t wav /tmp/t.wav trim 0 3 && play /tmp/t.wav`.
- With Docker Desktop the bind source is resolved inside the `docker-desktop` distro, where the socket may not be visible. If `/mnt/wslg/PulseServer` inside the container is not a socket even though `VOICE_PULSE_SOCKET` is set, that is why; a daemon running natively in the WSL distro does not have this problem.
- Routing PulseAudio over TCP instead is not an option here: the `dev` service has no route to the host, so the Unix socket is the only path.
