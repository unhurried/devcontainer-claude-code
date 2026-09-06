# Design: Route-level egress isolation for the devcontainer

Date: 2026-09-05
Status: Implemented on branch `egress-isolation-proxy`. Corrections from the final
whole-branch review folded in 2026-09-06; those are marked inline.

## Problem

Egress control today is an **IP snapshot**. `init-firewall.sh` resolves every entry in
`allowed-domains.txt` with `dig` at container start, puts the answers in an ipset, and
lets iptables allow those addresses. This is unstable in practice:

- `registry.npmjs.org`, `claude.ai`, `sentry.io`, `storage.googleapis.com` and the rest
  sit behind CDNs and anycast. The handful of A records captured at startup go stale
  within minutes to hours, and requests then fail intermittently for no visible reason.
- Shared IP space makes the allowlist simultaneously too narrow and too wide. Allowing
  `storage.googleapis.com`'s current addresses admits every other bucket and Google
  service answering on them.
- UDP 53 is open to everything, so DNS itself remains an unrestricted path out.
- `dstdomain`-style wildcards cannot be expressed; every subdomain needs its own line.

Claude Code's own sandbox does not cover this. It applies to the Bash tool only, so MCP
servers, editor extensions, and any process an agent spawns are outside it. Sandbox
runtime is still a Research Preview.

## Goals

- Egress decisions keyed on **hostname**, not IP, so CDN rotation cannot break them.
- Isolation that holds regardless of what runs inside the container, including root and
  nested Docker containers.
- Less total configuration than today, not more.

## Non-goals

- Restricting the **image build**. `docker build` runs on the normal build network, as it
  does today. Only runtime egress is controlled.
- TLS interception. Traffic stays inside CONNECT tunnels; no CA certificate is injected.
- Ingress filtering. This is about outbound traffic.

## Verified findings

Measured in this repo's devcontainer via DinD on 2026-09-05. Test containers, networks,
and images were removed afterwards.

| Check | Result |
| --- | --- |
| Default route on an `internal: true` network | None. `ip route` shows only the on-link subnet. |
| External DNS on an `internal: true` network | `SERVFAIL`. Names do not resolve. |
| Container-name resolution within the network | Works. |
| Egress from a dual-homed proxy container | Works. |
| squid `.github.com` vs. apex / `api.` / `codeload.` | All allowed. |
| squid exact entry `registry.npmjs.org` | Allowed. |
| `example.com`, `raw.githubusercontent.com` (unlisted) | 403 `TCP_DENIED`. |
| IP-literal CONNECT (`140.82.121.6`) | 403 `TCP_DENIED`. |
| Direct connection with the proxy bypassed | Fails; name does not resolve. |

Two constraints surfaced that the implementation must respect:

- squid drops privileges to the `squid` user and then **cannot open the container's
  stdout pipe**. `access_log stdio:/dev/stdout` makes it exit with
  `FATAL: Cannot open '/dev/stdout' for writing`. It must log to a file that root tails.
- busybox `wget` does not issue `CONNECT`; it sends an absolute-URI `GET` that squid
  cannot serve for `https://`. Not a problem for curl, git, npm, pip, or Node, but test
  scripts must not use busybox wget.

## Architecture

```
                     +--------------+
   egress (bridge)---+ proxy        |  alpine + squid, :3128
        |            | (dual-homed) |
   Internet          +------+-------+
                            |
   +------ isolated (internal: true) ------+
   |                                       |
   |   dev  -- DinD daemon -- nested ctrs  |
   |   no default route / no external DNS  |
   +---------------------------------------+
```

The only path out of `dev` is a CONNECT tunnel through squid. Because `isolated` carries
no default route and Docker installs host-side rules dropping traffic that leaves that
bridge, root inside the container and `--privileged` nested containers are equally
contained. The outer Docker socket is deliberately not mounted (this is
docker-in-docker, not docker-outside-of-docker), so nothing inside can reconfigure the
host's networks.

## Components

### `.devcontainer/docker-compose.yml` (new)

Two networks and two services.

- `isolated`: `internal: true`. Holds `dev`.
- `egress`: default bridge settings. Holds `proxy` only.
- `proxy`: built from `./proxy`, joined to both networks with the network alias `proxy`,
  `restart: unless-stopped`, and a healthcheck on port 3128.
- `dev`: built from `./Dockerfile`, joined to `isolated` only, `depends_on: proxy`
  (`condition: service_healthy`), `shm_size: 1gb`, `command: sleep infinity`.
- `dev` mounts the workspace bind mount. The two persisted named volumes stay in
  `devcontainer.json` as `mounts`; see risk item 1.

**Corrected 2026-09-06.** `runArgs` is the *only* devcontainer.json key a compose-based
devcontainer genuinely ignores, so `--shm-size=1g` becomes `shm_size: 1gb` and the
`--cap-add=NET_ADMIN` / `--cap-add=NET_RAW` entries are dropped entirely. Everything
else this design once described as ignored is in fact applied. For a compose service the
CLI merges `containerEnv` into `environment:`, merges `mounts` into `volumes:`, and
applies feature-metadata `privileged`, `init`, `cap_add`, `security_opt` and `user`.

Two consequences:

- The environment variables could equally be declared as `containerEnv`. They live in
  the compose file's `environment:` block because keeping them in one place is clearer,
  not because devcontainer.json would fail to deliver them.
- The docker-in-docker feature's `privileged` request does reach the `dev` service on
  its own, as do its `init: true` and its `/var/lib/docker` volume — none of these needs
  restating by hand. `privileged: true` is nevertheless written out on `dev`
  deliberately, as a statement of intent: the container is useless without it and the
  file should say so. This does not weaken the isolation: privileged grants capabilities
  inside the container's own network namespace, which still has no route out.

### `.devcontainer/proxy/` (new)

`Dockerfile` — `alpine:3.20`, `apk add --no-cache squid`, copy the config, allowlist, and
entrypoint.

`squid.conf` — the configuration validated above, plus the `Safe_ports` gate added on
2026-09-06 (see below):

```
http_port 3128

acl allowed_domains dstdomain "/etc/squid/allowed-domains.txt"
acl ip_literal      dstdom_regex ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ^[0-9a-fA-F:]*:[0-9a-fA-F:.]*$
acl Safe_ports      port 80 443
acl SSL_ports       port 443
acl CONNECT         method CONNECT

http_access deny  ip_literal
http_access deny  !Safe_ports
http_access deny  CONNECT !SSL_ports
http_access allow allowed_domains
http_access deny  all

cache deny all
access_log stdio:/var/log/squid/access.log
```

**`Safe_ports`, added 2026-09-06.** This file replaces the distribution default
wholesale, which takes squid's stock `Safe_ports` ACL with it. `deny CONNECT !SSL_ports`
covers CONNECT only, so a plain `GET http://<allowlisted-host>:22/` was accepted and
squid dialled port 22 — a port-reach primitive against every allowlisted domain.
`deny !Safe_ports`, placed before any allow, closes it. Measured after the change:
`GET http://api.github.com:22/` logs `TCP_DENIED/403`, while `https://api.github.com/zen`
still tunnels and `GET http://api.github.com/` still returns.

**The `ip_literal` rule, mechanism corrected 2026-09-06.** The original reasoning —
"without it a client could bypass name-based filtering by connecting to a raw address" —
described the wrong mechanism, and would let a future reader conclude the rule is
redundant. Squid does not skip the allowlist for an IP-based URL; it falls back to a PTR
lookup. `140.82.121.6` reverse-resolves to `lb-140-82-121-6-fra.github.com`, which
matches the `.github.com` entry, so removing this rule makes `https://140.82.121.6/`
**allowed**, not merely unfiltered. Measured both ways: with the rule removed squid logs
`TCP_TUNNEL/200 CONNECT 140.82.121.6:443`; with it present, `TCP_DENIED/403`. What the
rule buys is that every destination is a name squid resolves forward itself, so a client
cannot pair an allowed hostname with an address of its choosing.

The IPv6 half of the `ip_literal` pattern is hardening only. Neither compose network
enables IPv6, so squid has no IPv6 path out and the pattern cannot currently be
exercised; it costs nothing, since a colon is not legal in a hostname.

`entrypoint.sh` — creates `/var/log/squid/access.log` owned by `squid`, backgrounds
`tail -F` on it so entries reach `docker logs`, then `exec squid -N -f
/etc/squid/squid.conf`. This exists solely to work around the stdout constraint recorded
above.

`allowed-domains.txt` — moved from `.devcontainer/scripts/`, rewritten in `dstdomain`
form. Leading-dot entries cover a domain and all its subdomains:

```
.github.com
.githubusercontent.com
registry.npmjs.org
pypi.org
files.pythonhosted.org
.claude.ai
api.anthropic.com
console.anthropic.com
.sentry.io
.statsig.com
.statsig.anthropic.com
marketplace.visualstudio.com
.vsassets.io
vscode.blob.core.windows.net
update.code.visualstudio.com
vscode.download.prss.microsoft.com
.docker.io
production.cloudflare.docker.com
cdn.playwright.dev
playwright.download.prss.microsoft.com
storage.googleapis.com
```

`.github.com` and `.githubusercontent.com` replace the entire `api.github.com/meta`
fetch-and-aggregate step, along with its CIDR validation and its failure modes.

Three entries were added on 2026-09-06, ahead of the first interactive rebuild, to close
gaps that would each have cost a rebuild round: `vscode.download.prss.microsoft.com`
(today's VS Code server payload host — without it a rebuild stalls at "Installing VS Code
Server"), `.vsassets.io` (marketplace VSIX bytes come from `*.gallerycdn.vsassets.io`,
not from `marketplace.visualstudio.com`), and `console.anthropic.com` (the Claude Code
OAuth token exchange). Entries stay explicit rather than broadening to
`.anthropic.com`; a tight allowlist is the point.

### `.devcontainer/scripts/verify-isolation.sh` (new)

Runs as `postStartCommand` and asserts four properties:

1. An allowed host returns 200 through the proxy (`https://registry.npmjs.org/`).
2. An unlisted host is refused by the proxy (`response 403` on the CONNECT).
3. A hostname is unreachable with the proxy bypassed.
4. A literal address (`https://140.82.121.6/`) is unreachable with the proxy bypassed.

Uses curl, not busybox wget, for the reason recorded above.

**Revised 2026-09-06 — not every failure is fatal.** With `waitFor: postStartCommand` a
non-zero exit blocks the container from opening, and the first version failed the start
on any upstream outage: with the proxy merely unreachable, checks 1 and 2 failed and the
container refused to open with a message that read like a security breach. The split is
now:

- **Fatal** — check 3 or 4 reaching the host with the proxy bypassed (egress exists where
  none should), and check 2 finding the unlisted host actually *reachable* (the proxy is
  not filtering).
- **Warning, non-fatal** — check 1 failing, and check 2 failing because the proxy could
  not be reached at all. These print as warnings and the container starts anyway.

Check 2 tells its two failure modes apart by what curl reports: `response 403` from the
CONNECT is the proxy filtering correctly, a proxy-resolution or connection error is a
connectivity failure, and curl exiting 0 means the unlisted host answered.

Check 1 deliberately avoids `https://api.github.com/zen`: that is GitHub's rate-limited
core API (60/hr unauthenticated per source IP), and a rate-limited 403 would have blocked
the start. `registry.npmjs.org` is on the same allowlist and is not rate limited.

Check 4 exists because check 3 alone cannot tell "no route" from "no DNS" — it probes a
hostname, so it passes whenever the name merely fails to resolve. A network that regained
a route while DNS still did not forward would have reported `ok`. Probing a literal
address needs no DNS and so can only fail on routing. The address is GitHub's and is used
purely as a routable literal.

Note the lifecycle order: `postCreateCommand` runs before `postStartCommand`, so on first
creation a misconfigured proxy shows up as a `post-create.sh` network failure before this
script ever runs. `waitFor` stays at `postStartCommand` so the editor does not attach
until the fatal assertions have passed.

### `.devcontainer/scripts/init-firewall.sh` (deleted)

Roughly 150 lines go away: the fail-closed `trap`, the Docker DNS rule save/restore, host
network detection, GitHub range fetching and CIDR validation, ipset population, and the
verification curls (which move to `verify-isolation.sh`).

### `.devcontainer/Dockerfile` (edited)

- Drop `iptables`, `ipset`, `dnsutils`, `aggregate` from the apt list.
- Drop the `COPY` of `init-firewall.sh` and `allowed-domains.txt`.
- Drop the sudoers block. It removed the base image's blanket passwordless sudo and
  granted only the firewall script; that narrowing existed to protect the firewall, and
  egress control now lives outside the container. The base image default is restored, so
  `apt install` works during development again.
- Keep `bubblewrap` and `socat`: Claude Code's Bash sandbox still uses them, and it
  remains useful as a second, process-level layer.

### `.devcontainer/devcontainer.json` (edited)

Switches to `dockerComposeFile` / `service: dev` / `workspaceFolder`, adds
`shutdownAction: stopCompose`, and drops `build`, `runArgs`, and `containerEnv`.
`mounts` **stays** — see risk item 1; it was briefly removed on the mistaken belief that
compose services ignore it. `features`, `remoteUser`, `postCreateCommand`, and
`customizations` are unchanged. `postStartCommand` becomes `verify-isolation.sh`.

The `INIT_FIREWALL` toggle is removed. Isolation is always on. The toggle existed because
the IP-snapshot firewall was too unreliable to leave enabled; removing that unreliability
is the point of this change, and a compose network's `internal` flag is not a clean thing
to switch at runtime.

### `.mcp.json` (edited)

Chromium does not read `HTTPS_PROXY`. Add `--proxy-server=http://proxy:3128` to the
Playwright MCP server's arguments.

## Proxy wiring

Set on the `dev` service:

```
HTTP_PROXY / HTTPS_PROXY / http_proxy / https_proxy = http://proxy:3128
NO_PROXY / no_proxy = localhost,127.0.0.1,::1
```

- curl, git, npm, pip, and Node (so Claude Code itself) honour these directly.
- The DinD daemon inherits them from the container environment, so image pulls work.
- Nested containers do **not** get the variables. `proxies.default` in
  `~/.docker/config.json` would inject them into `docker run`, but that file is
  deliberately not written: whether a nested container can resolve `proxy` through the
  inner daemon's DNS is unverified, and shipping an unverified config would trade a
  visible failure for a silent one. The limitation is documented in `README.md` instead —
  pass the variables explicitly (`docker run -e HTTPS_PROXY=http://proxy:3128 ...`) when
  a nested container needs egress, or it will hang until timeout.
- Anything that ignores the variables fails closed with a connection error rather than
  silently escaping.

## Error handling

There is no fail-open code path to defend, which is why the current `trap`-based
fallback disappears.

- A denied request gets a squid 403 whose body names the rejected domain. The current
  setup rejects silently at the IP layer with no indication of which host was blocked.
- If `proxy` is down, `dev` cannot resolve or connect to it and still has no route out.
  `verify-isolation.sh` reports that as a warning rather than failing the container
  start, since it is a connectivity problem and not a loss of isolation.
- The allowlist lives in the proxy image. `dev` cannot reach the outer Docker daemon, so
  it cannot rebuild or edit that image. This preserves the current "a process in the
  container cannot widen its own allowlist" property by construction rather than by
  file placement.

## Testing

`verify-isolation.sh` runs on every container start and covers the four assertions
above.

Two scripts under `.devcontainer/tests/` cover the rest, both requiring the in-container
Docker daemon:

- `test-proxy-acl.sh` exercises the allowlist against a live squid on a throwaway pair of
  networks mirroring this compose file — leading-dot coverage, exact entries, unlisted
  names, the IP literal, and direct egress with no proxy.
- `test-compose-topology.sh` asserts the shape compose actually builds: the isolated
  network's `internal` flag, `privileged`, which service is on which network, that the
  persisted volumes are declared where `${devcontainerId}` can resolve, that the dev
  network has no default route, and that the proxy is reachable by alias and has egress.
  It runs under its own compose project name (`-p topotest`) so that its `down` can never
  touch the real devcontainer, and it tears down the image it builds.

## Risks and items to confirm during implementation

1. **`${devcontainerId}` inside a compose file — resolved 2026-09-06: it does not
   belong in one at all.** The volumes are declared in `devcontainer.json` as `mounts`,
   and the CLI merges them into the `dev` service's `volumes:`:

   ```jsonc
   "mounts": [
     "source=claude-code-config-${devcontainerId},target=/home/vscode/.claude,type=volume",
     "source=claude-code-bashhistory-${devcontainerId},target=/commandhistory,type=volume"
   ],
   ```

   **The earlier conclusion recorded here was wrong**, and is kept below so the record is
   honest about the correction. It went: `${devcontainerId}` cannot be a top-level
   `volumes:` key, because compose validates key names against `^[a-zA-Z0-9._-]+$` before
   interpolation and rejects `claude-code-config-${devcontainerId}:` outright with
   `volumes additional properties ... not allowed`. That part is true. The mistake was the
   conclusion drawn from it — that the volume should therefore take a static key and an
   interpolated `name:`:

   ```yaml
   volumes:
     claude-code-config:
       name: claude-code-config-${devcontainerId}      # does NOT work
   ```

   That was validated by exporting `devcontainerId=abc123` in the shell before running
   `docker compose config`, which is not what happens in practice. The devcontainer CLI
   substitutes `${devcontainerId}` only inside `devcontainer.json`; it passes compose
   files through untouched with `-f` and exports no such variable. Caught by running
   `docker compose config` on the committed file with a clean environment: it warns
   `The "devcontainerId" variable is not set` and resolves the names to
   `claude-code-config-` and `claude-code-bashhistory-` with a blank suffix. The failure
   mode was not cosmetic — the next rebuild would silently attach different volumes than
   the ones in use (a fresh Claude Code login, empty shell history), and two clones of
   this repo on one host would share a single config volume.

   The `mounts` form is verified to keep the token literal, and
   `docker compose -f .devcontainer/docker-compose.yml config` now emits no
   `devcontainerId` warning. `test-compose-topology.sh` asserts both properties. What has
   *not* been observed end to end is the CLI's merge itself — no rebuild has run since the
   change — so confirm the actual suffix with `docker volume ls` after the first real
   rebuild.
2. **Claude Code's Bash sandbox proxy.** The sandbox sets its own `*_PROXY` pointing at
   `localhost:3128` and a host proxy port. Its interaction with a container-level
   `HTTPS_PROXY=http://proxy:3128` is untested; confirm sandboxed Bash can still reach
   allowed hosts, and adjust `NO_PROXY` or the sandbox configuration if not.
3. **VS Code server and extension installation.** Confirm these complete through the
   proxy. Partly pre-empted on 2026-09-06: the download path did need more, so
   `vscode.download.prss.microsoft.com` (server payload) and `.vsassets.io` (extension
   VSIX bytes) joined `marketplace.visualstudio.com`,
   `vscode.blob.core.windows.net` and `update.code.visualstudio.com`. Still to be
   confirmed against a real rebuild.
4. **`postCreateCommand` reachability.** `post-create.sh` does `npm view`, a global
   `npm install`, and `playwright install chromium`. All must succeed through the proxy
   with the allowlist above.
5. **Allowlist completeness.** Moving from IP ranges to names will surface hosts the
   GitHub ranges silently covered. Three such additions were made on 2026-09-06 before
   the first interactive rebuild (see the `allowed-domains.txt` section); expect one or
   two more after the first real run.
