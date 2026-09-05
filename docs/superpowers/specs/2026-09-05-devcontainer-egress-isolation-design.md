# Design: Route-level egress isolation for the devcontainer

Date: 2026-09-05
Status: Approved, ready for an implementation plan

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
- `dev` mounts the workspace bind mount plus the two named volumes that
  `devcontainer.json` declares today.

Two things move here because compose-based devcontainers ignore them elsewhere:

- `runArgs` is not supported, so `--shm-size=1g` becomes `shm_size: 1gb`. The
  `--cap-add=NET_ADMIN` / `--cap-add=NET_RAW` entries are dropped entirely.
- `containerEnv` is not applied to compose services, so all environment variables go in
  the service's `environment:` block.

The docker-in-docker feature normally requests `privileged` through its feature
metadata, which the CLI applies only to image- and Dockerfile-based containers. With
compose, `privileged: true` must be set on the `dev` service explicitly. This does not
weaken the isolation: privileged grants capabilities inside the container's own network
namespace, which still has no route out.

### `.devcontainer/proxy/` (new)

`Dockerfile` — `alpine:3.20`, `apk add --no-cache squid`, copy the config, allowlist, and
entrypoint.

`squid.conf` — exactly the configuration validated above:

```
http_port 3128

acl allowed_domains dstdomain "/etc/squid/allowed-domains.txt"
acl ip_literal      dstdom_regex ^([0-9]{1,3}\.){3}[0-9]{1,3}$
acl SSL_ports       port 443
acl CONNECT         method CONNECT

http_access deny  ip_literal
http_access deny  CONNECT !SSL_ports
http_access allow allowed_domains
http_access deny  all

cache deny all
access_log stdio:/var/log/squid/access.log
```

The `ip_literal` rule matters: without it a client could bypass name-based filtering by
connecting to a raw address. With it, the destination is always a name that squid itself
resolves, so a client cannot pair an allowed hostname with an attacker-chosen address.

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
.sentry.io
.statsig.com
.statsig.anthropic.com
marketplace.visualstudio.com
vscode.blob.core.windows.net
update.code.visualstudio.com
.docker.io
production.cloudflare.docker.com
cdn.playwright.dev
playwright.download.prss.microsoft.com
storage.googleapis.com
```

`.github.com` and `.githubusercontent.com` replace the entire `api.github.com/meta`
fetch-and-aggregate step, along with its CIDR validation and its failure modes.

### `.devcontainer/scripts/verify-isolation.sh` (new)

Runs as `postStartCommand` and asserts three properties, failing the command if any does
not hold:

1. An allowed host returns 200 through the proxy.
2. An unlisted host returns 403 through the proxy.
3. A direct connection with the proxy bypassed fails.

Uses curl, not busybox wget, for the reason recorded above.

Note the lifecycle order: `postCreateCommand` runs before `postStartCommand`, so on first
creation a misconfigured proxy shows up as a `post-create.sh` network failure before this
script ever runs. `waitFor` stays at `postStartCommand` so the editor does not attach
until the assertions have passed.

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
`shutdownAction: stopCompose`, and drops `build`, `runArgs`, `mounts`, and
`containerEnv`. `features`, `remoteUser`, `postCreateCommand`, and `customizations` are
unchanged. `postStartCommand` becomes `verify-isolation.sh`.

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
- Nested containers need `proxies.default` in `~/.docker/config.json` to have the
  variables injected into `docker run`.
- Anything that ignores the variables fails closed with a connection error rather than
  silently escaping.

## Error handling

There is no fail-open code path to defend, which is why the current `trap`-based
fallback disappears.

- A denied request gets a squid 403 whose body names the rejected domain. The current
  setup rejects silently at the IP layer with no indication of which host was blocked.
- If `proxy` is down, `dev` gets connection refused and still has no route out.
- The allowlist lives in the proxy image. `dev` cannot reach the outer Docker daemon, so
  it cannot rebuild or edit that image. This preserves the current "a process in the
  container cannot widen its own allowlist" property by construction rather than by
  file placement.

## Testing

`verify-isolation.sh` runs on every container start and covers the three assertions
above. The fuller matrix from the Verified findings table is reproducible by hand and
should be re-run once after implementation against the real compose stack.

## Risks and items to confirm during implementation

1. **`${devcontainerId}` inside a compose file.** Needed to keep the existing
   `claude-code-config-*` and `claude-code-bashhistory-*` volumes attached. The
   devcontainer spec documents it for this exact purpose, but it is unverified here. If
   substitution does not happen, fall back to plain names and let compose's project
   scoping provide uniqueness; that orphans the current volumes and forces one re-login.
2. **Claude Code's Bash sandbox proxy.** The sandbox sets its own `*_PROXY` pointing at
   `localhost:3128` and a host proxy port. Its interaction with a container-level
   `HTTPS_PROXY=http://proxy:3128` is untested; confirm sandboxed Bash can still reach
   allowed hosts, and adjust `NO_PROXY` or the sandbox configuration if not.
3. **VS Code server and extension installation.** Confirm these complete through the
   proxy; `marketplace.visualstudio.com`, `vscode.blob.core.windows.net`, and
   `update.code.visualstudio.com` are allowlisted, but the download path may need more.
4. **`postCreateCommand` reachability.** `post-create.sh` does `npm view`, a global
   `npm install`, and `playwright install chromium`. All must succeed through the proxy
   with the allowlist above.
5. **Allowlist completeness.** Moving from IP ranges to names will surface hosts the
   GitHub ranges silently covered. Expect one or two additions after the first real run.
