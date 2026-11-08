# devcontainer-claude-code

Devcontainer configuration for Claude Code and Codex.

## Usage

1. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) for VS Code.
2. Run `Dev Containers: Reopen in Container` from the command palette.

The first build sets up mise (with Node.js and Python), Docker-in-Docker, Claude Code and Codex. Sign in to Codex with `codex login` in the VS Code terminal (VS Code forwards its `localhost:1455` callback to the host browser) or `codex login --device-auth`.

## Network isolation

The dev container sits on an `internal` Docker network with no route to the internet. The only way out is a squid proxy in a separate container, which allows the hostnames listed in `.devcontainer/proxy/allowed-domains.txt`.

- **Two modes, used in turn:** install tools and dependencies with `PROXY_MODE=open`, then switch back to the allowlist before letting an agent run unattended. Set it in `.devcontainer/.env` (copy `.env.example`; gitignored) and rebuild. In `open` any hostname is allowed (raw IPs are still refused); the network isolation itself is unchanged.
- **The allowlist holds only hosts that serve their operator's own content.** Hosts that deliver third-party uploads — GitHub (`github.com`, `githubusercontent.com`, `github.io`), npm, PyPI, crates.io, Maven Central, the Gradle plugin portal, Docker Hub, ghcr.io, the VS Code Marketplace, `storage.googleapis.com`, Read the Docs — are absent, so under the allowlist `git fetch`/`push`, package installs, image pulls and plugin or extension updates fail. Keep it that way: such a host is both a prompt-injection source and an exfiltration channel.
- **Change what is reachable:** edit `allowed-domains.txt` and rebuild. A leading dot covers subdomains (`.claude.ai` matches `downloads.claude.ai`). A blocked request gets a squid 403 naming the domain.
- **Nested containers** do not inherit the proxy and cannot resolve `proxy` by name. Pass it by address:
  ```sh
  P=http://$(getent hosts proxy | awk '{print $1}'):3128
  docker run -e HTTPS_PROXY=$P -e HTTP_PROXY=$P ...
  docker build --build-arg http_proxy=$P --build-arg https_proxy=$P ...
  ```
- **Remaining channels:** `.claude.ai` and `.claude.com` stay because Claude Code needs them, and claude.ai also serves user-published artifacts. Likewise `chatgpt.com` stays for Codex's ChatGPT sign-in and serves shared conversations; it is listed without a leading dot, as are the other OpenAI hosts. `PROXY_MODE=open` removes the barrier entirely, so do not leave an agent running unattended in it.
- `.devcontainer/scripts/verify-isolation.sh` checks the isolation on every container start and fails the start if it is broken.
- Tests (need the in-container Docker daemon): `.devcontainer/tests/test-proxy-acl.sh`, `.devcontainer/tests/test-compose-topology.sh`.

Design notes:

- Filtering is by hostname, so CDN IP changes cannot break it. The list is baked into the proxy image, which the dev container cannot reach, so a process inside cannot widen its own egress.
- Isolation is structural (no default route), so root and `--privileged` nested containers are equally contained.
- Claude Code's Sentry and Statsig telemetry are off (`DISABLE_ERROR_REPORTING`, `DISABLE_TELEMETRY` in `docker-compose.yml`); the auto-updater stays on and fetches from `downloads.claude.ai`. Codex's Statsig metrics and `/feedback` uploads are off (`analytics`, `feedback` in `.devcontainer/codex/config.toml`); it updates from `releases.openai.com`.
- `NO_PROXY` covers localhost and the private ranges, so nested containers are reachable by address.
- The proxy container drops every capability squid does not need and runs with `no-new-privileges`. Plain-HTTP requests leave without `Via` or `X-Forwarded-For`.

## Working on other repositories

Clone them under `repos/`. It is created on container start, visible to the host, and gitignored here, so nested repositories never show up in this repo's `git status`.

- Start Claude Code **inside the repository**, or in `repos/` to work across several. Do not start it at this repo's root: the ignore entry hides `repos/` from its search, and git features would target this repo.
- The gitignore entry is a plain `repos/` on purpose: a `repos/*` + `!repos/.gitkeep` pair makes ripgrep (and Claude Code's search) skip the repositories.
- VS Code's Source Control view finds them because `git.repositoryScanMaxDepth` is 2 in `devcontainer.json`.

## Host directories

Directories on the host (WSL side, including `/mnt/c/...`) are bind-mounted at `/workspaces/mnt/<basename>` from `HOST_MOUNTS` in `.devcontainer/.env`, then rebuild:

```sh
HOST_MOUNTS="/mnt/c/Users/me/Documents/notes:ro;/home/me/scratch"
```

- Entries are separated by `;` (paths may contain spaces). `:ro` mounts one read-only; the rest are read-write, so an agent can change and delete their files. Prefer `:ro` for anything it only needs to read.
- `initializeCommand` runs `.devcontainer/scripts/generate-host-mounts.sh` on the host before every start. It writes the mounts to `.devcontainer/docker-compose.mounts.yml` (gitignored, never edit), which `devcontainer.json` lists after `docker-compose.yml`. An entry that is not an absolute path to an existing directory, a duplicate basename, or a basename starting with `.` fails the start with a message in the Dev Containers log. Mounts are created with `create_host_path: false`, so a path that vanishes later fails too instead of leaving an empty root-owned directory on the host.
- They live outside this repo on purpose: under it, they would show up in its `git status`, or, gitignored, be hidden from ripgrep (and Claude Code's search) when it is started inside them, and `git clean -x` here would delete the host files.
- Start Claude Code or Codex **inside** a mounted directory; their user-scope settings apply there as under `repos/`. In VS Code, add it with `File: Add Folder to Workspace`.
- `/mnt/c` goes through WSL's 9p file system: expect slow searches on large trees, and no file-change events for edits made on the Windows side (VS Code's explorer may need a refresh). Files in a cloud-synced folder are uploaded as an agent writes them.
- Docker Desktop resolves the bind source inside its own distro, where a path the script found may not exist; a daemon running natively in the WSL distro does not have this problem.
- Test: `.devcontainer/tests/test-host-mounts.sh` (needs only the `docker compose` CLI).

## Agent settings

Settings, skills, global instructions and the Playwright MCP server are installed at **user scope** (`~/.claude`, `~/.codex`, persisted volumes), so they apply under `repos/` too — project scope only applies to the directory an agent is started in.

- Shared by both agents: `.devcontainer/agents/skills/<name>/` (linked into `~/.claude/skills` and `~/.agents/skills`), `.devcontainer/agents/AGENTS.md` (linked as `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`), and the MCP server definition in `.devcontainer/scripts/sync-agent-config.sh`.
- Claude Code only: `.devcontainer/claude/settings.json`. Codex only: `.devcontainer/codex/config.toml`.
- `.devcontainer/scripts/sync-agent-config.sh` runs on every container start: merges the Claude template into `~/.claude/settings.json` (template keys win, keys Claude Code writes itself survive), symlinks the skills and instructions, registers the MCP server with both agents. Edit and restart, or run the script by hand — no rebuild. A real file or directory already at a link target is left alone, with a warning.
- A key *removed* from the Claude template stays in `~/.claude/settings.json` until removed there by hand.
- The Codex template needs no merge: the `Dockerfile` symlinks it to `/etc/codex/managed_config.toml`, which Codex layers above `~/.codex/config.toml`, so its keys win and edits are live. Codex keeps writing its own keys (trusted projects, MCP servers) to `~/.codex/config.toml`.
- Codex runs `workspace-write` with network access: commands write only to the workspace and `~/.gradle`, and squid filters their egress. Unlike Claude Code's `sandbox.credentials`, it cannot deny reads of `~/.ssh` and the like.
- The templates are ordinary tracked files, so neither sandbox protects them. Review changes to them like changes to the proxy allowlist.
- **Unix sockets:** `post-create.sh` installs `@anthropic-ai/sandbox-runtime`, whose prebuilt `apply-seccomp` filter makes sandboxed commands fail `socket(AF_UNIX)`. Without it they could reach `/var/run/docker.sock` and, via `docker run --privileged`, the host, which has direct internet. `docker` therefore fails inside the sandbox; Claude Code retries it unsandboxed, and the `Bash(dangerouslyDisableSandbox:true)` ask rule makes that retry need your approval even in `auto` mode. Hooks, MCP servers and file tools run outside the sandbox and are not covered.
- `sandbox.failIfUnavailable` stops Claude Code running unsandboxed when bubblewrap or socat is missing. `/sandbox` lists a Dependencies tab if the seccomp filter is not found. The template has no `Bash(...)` allow rules: inside the sandbox commands run without a prompt, and an allow rule would also approve the unsandboxed retry of that command.

## Rebuilds

The image build itself is fast (it runs on the host's Docker daemon with direct internet). Everything after it goes through squid, so the large downloads are kept in named volumes: `~/.claude`, `~/.codex`, `/commandhistory`, `~/.cache/ms-playwright`, `~/.npm`, `~/.vscode-server/extensions`, `~/.local`.

- `docker volume ls | grep claude-code-` lists them; remove one to force that part to be fetched again.
- The mount points are created in the `Dockerfile` so the volumes are owned by `vscode`, not root.
- Only `extensions/` of `~/.vscode-server` is persisted. VS Code writes `data/Machine/settings.json` from `customizations.vscode.settings` only when the file is absent, so persisting `data/` would pin those settings to whatever the first create wrote. `bin/` needs no volume — it is symlinks into the `vscode` volume Dev Containers manages itself — and `extensionsCache/` only duplicates `extensions/`. The cost is that `data/User/globalStorage` (per-extension state) resets on rebuild; Claude Code and Codex are unaffected, their state is in `~/.claude` and `~/.codex`.
- That volume was renamed when it was narrowed, so existing setups keep an orphaned `claude-code-vscode-server-*`. Remove it; the next rebuild refetches the extensions once (~500 MB through squid).
- Docker-in-Docker tracks `latest` because moby's apt repo drops old versions.

## Tool versions (mise)

[mise](https://mise.jdx.dev) provides Node and Python. Its shims are on `PATH`, so non-interactive shells (Claude Code's Bash tool, `postCreateCommand`) see the same versions as the terminal.

- Global versions are pinned in `.devcontainer/mise/config.toml` (`MISE_GLOBAL_CONFIG_FILE`), mise itself in the `Dockerfile`; bump deliberately. Edit the file and run `mise install` — no rebuild. `mise use -g` writes to the same tracked file.
- Per repository: a `mise.toml` or `.tool-versions` in a repo under `repos/` overrides them there. mise ignores it until you run `mise trust` in that repo.
- Installed tools live in `~/.local/share/mise`, inside the `~/.local` volume, so a rebuild downloads nothing. Downloads come from GitHub, nodejs.org and `mise-versions.jdx.dev`, so run `mise install` under `PROXY_MODE=open`.
- Gradle ignores `HTTP(S)_PROXY`, so `.devcontainer/gradle/proxy.init.gradle` (symlinked into `~/.gradle/init.d` by the `Dockerfile`) maps `HTTP(S)_PROXY` and `NO_PROXY` to JVM proxy properties on every build. It reads them at build time, not from a fixed `GRADLE_OPTS`, because Claude Code's sandbox swaps in its own proxy (`localhost`, with credentials) and `proxy` does not resolve inside it. It applies to every repo under `repos/`; outside this container the repo's own builds are unaffected. Dependencies come from Maven Central and the plugin portal, which only `PROXY_MODE=open` reaches; resolve them there (e.g. `./gradlew build --refresh-dependencies` once), after which builds under the allowlist use the `~/.gradle` cache (add `--offline` if Gradle still tries the network). Inside Claude Code's sandbox those hosts must also be in `sandbox.network.allowedDomains` of `.devcontainer/claude/settings.json`, which also grants the sandbox write access to `~/.gradle`.
- Rust has no global version: a repository opts in with its own `mise.toml`, either `rust = "<version>"` or `idiomatic_version_file_enable_tools = ["rust"]` under `[settings]` to follow its `rust-toolchain.toml` (components included). mise installs it through rustup, and `CARGO_HOME` / `RUSTUP_HOME` (`docker-compose.yml`) keep rustup, the toolchains and cargo's crates in the `~/.local` volume. Toolchains come from `static.rust-lang.org`, which the allowlist has. The first rustup install (`sh.rustup.rs`) and crates.io (third-party uploads) need `PROXY_MODE=open`: run `mise install` and `cargo fetch --locked` there, and the first build too if a build script downloads something. After that, builds under the allowlist need no network. Inside Claude Code's sandbox, cargo writes to `CARGO_HOME` on every build (package cache lock, usage tracking), so `.devcontainer/claude/settings.json` grants it, and `post-create.sh` creates the directory up front because the sandbox only grants paths that exist when Claude Code starts. Its `allowedDomains` lists the Rust hosts, as it does Gradle's.
- `NPM_CONFIG_PREFIX` puts `npm install -g` into `~/.local`, so global packages (such as the Playwright MCP server) survive a Node version change.

## Package installs

Two npm guardrails are set container-wide in `docker-compose.yml`:

- `NPM_CONFIG_IGNORE_SCRIPTS=true` — install-time lifecycle scripts do not run. Use `npm rebuild <pkg>` for native addons that need them.
- `NPM_CONFIG_MIN_RELEASE_AGE=7` — versions published within the last week are refused, which is why `post-create.sh` pins versions (Playwright MCP, the sandbox runtime) instead of `@latest`.

Neither touches Claude Code: it is installed by Anthropic's native installer into `~/.local` (a persisted volume), not by npm, so the auto-updater is not subject to them. Under npm it could never update — Claude Code releases daily, and `NPM_CONFIG_IGNORE_SCRIPTS` would skip the postinstall that puts the real binary in place. `claude doctor` shows the install method; `~/.claude/.last-update-result.json` the last update attempt. Codex is likewise installed by OpenAI's native installer: `~/.local/bin/codex` links into `~/.codex/packages`, which is why `~/.codex` is a volume.

## Browser automation (Playwright MCP)

The [Playwright MCP](https://github.com/microsoft/playwright-mcp) server is registered at user scope. Chromium and its OS dependencies are installed automatically (`Dockerfile`, `post-create.sh`) and the browser is kept in a volume.

- **Only allowlisted hosts are reachable** (any host under `PROXY_MODE=open`). Add a site to `allowed-domains.txt` and rebuild; keep out sites that serve third-party uploads. Chromium ignores `HTTPS_PROXY`, so it is passed explicitly as `--proxy-server`.
- Upgrade: bump `MCP_VERSION` in `.devcontainer/scripts/post-create.sh` and rebuild. The browser is installed by the package's own Playwright, so it cannot drift.
- Runs headless with `--no-sandbox`. `shm_size: 1gb` is set because Chromium crashes on Docker's default 64 MB `/dev/shm`.

## GUI apps (Xvfb)

Xvfb, xdotool and ImageMagick run GUI apps without a display and drive them. The image also has the X11 libraries that winit loads at run time, and DejaVu Sans, the fallback font of cosmic-text (iced), without which Latin text renders blank. CJK text uses Noto Sans CJK.

```sh
Xvfb :99 -screen 0 1280x800x24 &
export DISPLAY=:99 LANG=C.UTF-8
<app> &
xdotool search --onlyvisible --name '<window title>' windowfocus --sync
xdotool key Tab && xdotool type 'テキスト'
import -window root shot.png
```

- Start `Xvfb` itself, not `xvfb-run`, when other commands drive the app: `xvfb-run` protects its display with a private auth file, so `xdotool` and `import` cannot connect.
- There is no window manager: focus the window with `xdotool windowfocus` before sending keys.
- `xdotool type` needs a UTF-8 locale (`LANG=C.UTF-8`) for non-ASCII text.
- X11 clients connect through a Unix socket under `/tmp/.X11-unix`, which Claude Code's sandbox may not allow; Claude then asks to run the command outside the sandbox. Do not set `sandbox.network.allowAllUnixSockets` for it: that also opens the Docker daemon's socket.

## Voice input (`/voice`)

Claude Code records with SoX's `rec`, which needs a PulseAudio socket that VS Code does not forward. Set `VOICE_PULSE_SOCKET` in `.devcontainer/.env` to the host socket (WSL2: `/mnt/wslg/PulseServer`, see `.env.example`) and rebuild. Left unset, `/dev/null` is mounted instead and only `/voice` is unavailable.

Troubleshooting on WSL2:

- Host side: `/mnt/wslg/PulseServer` must exist in the WSL distro and `rec` must work there. Windows' microphone privacy settings apply.
- Container side: `rec --version` must exit 0 — that is voice mode's probe. Then `rec -q -t wav /tmp/t.wav trim 0 3 && play /tmp/t.wav`.
- Docker Desktop resolves the bind source inside the `docker-desktop` distro, where the socket may not be visible. A daemon running natively in the WSL distro does not have this problem.
- PulseAudio over TCP is not an option: the container has no route to the host.
