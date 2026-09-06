# Devcontainer Egress Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the DNS-snapshot iptables firewall with a squid forward proxy on a dual-homed container, reached from a devcontainer that sits on an `internal: true` compose network with no route out.

**Architecture:** Two compose networks. `isolated` (`internal: true`) holds the dev container and has no default route and no external DNS. `egress` holds the proxy container, which is joined to both. Egress decisions are made by squid on hostname (`dstdomain`), never on IP, so CDN address rotation cannot break them.

**Tech Stack:** Docker Compose, squid 6.x on Alpine, the Dev Containers spec, bash.

**Spec:** `docs/superpowers/specs/2026-09-05-devcontainer-egress-isolation-design.md`

## Global Constraints

- Base image for the proxy: `alpine:3.20`. squid comes from `apk add --no-cache squid`.
- The proxy listens on **3128** and is reachable from `isolated` under the network alias **`proxy`**, i.e. `http://proxy:3128`.
- **squid must not log to `/dev/stdout`.** It drops privileges to the `squid` user and then cannot open the container's stdout pipe; `access_log stdio:/dev/stdout` makes it exit with `FATAL: Cannot open '/dev/stdout' for writing`. Log to a file under `/var/log/squid/` and have root `tail -F` it.
- **Never use busybox `wget` to test the proxy.** It sends an absolute-URI `GET` instead of `CONNECT`, which squid cannot serve for `https://`, producing a false failure. Use `curl`.
- `${devcontainerId}` resolves **only inside `devcontainer.json`**, so the persisted volumes are declared there as `mounts` and the CLI merges them into the compose service. **Corrected 2026-09-06, after the final review:** this bullet originally said to use a static compose `volumes:` key with an interpolated `name:` value. That does not work either — the CLI passes compose files through with `-f` without substituting, so `docker compose config` resolves the name to a blank suffix. Task 3 below still shows the superseded form as executed; Task 5 carries the correction. Note also that the resolved id itself changes when a repo switches from a Dockerfile devcontainer to a compose one, because it hashes the container's identifying labels — see Task 6.
- `runArgs` in `devcontainer.json` is the only key genuinely **ignored for compose-based devcontainers**; `--shm-size=1g` becomes `shm_size: 1gb` in the compose file. **Corrected 2026-09-06, after the final review:** this bullet originally also named `containerEnv` as ignored. It isn't — the CLI merges `containerEnv` into the service's `environment:`, and likewise merges `mounts` into `volumes:` and applies feature-metadata `privileged`, `init`, `cap_add`, `security_opt` and `user`. This plan still declares the environment directly in the compose file's `environment:` block, for clarity, not because `containerEnv` would fail to deliver it.
- All `docker` commands in this plan run against the **inner DinD daemon** inside this devcontainer, which is a different daemon from the one hosting the devcontainer itself. Test containers, networks, and images created here cannot collide with the real ones.
- The Claude Code Bash sandbox blocks `/var/run/docker.sock`. Every `docker` invocation in this plan needs the sandbox disabled (`dangerouslyDisableSandbox: true`), which shows up as `permission denied while trying to connect to the docker API`.
- Commit messages: a single imperative line, no body, no trailers (see `.claude/skills/commit-message/SKILL.md`).

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `.devcontainer/proxy/Dockerfile` | Build squid with the config and allowlist baked in |
| `.devcontainer/proxy/squid.conf` | The access policy, and nothing else |
| `.devcontainer/proxy/entrypoint.sh` | Work around squid's stdout constraint; start squid |
| `.devcontainer/proxy/allowed-domains.txt` | The allowlist, in `dstdomain` form |
| `.devcontainer/docker-compose.yml` | Network topology, services, volumes, environment |
| `.devcontainer/scripts/verify-isolation.sh` | Runtime assertions, run at every container start |
| `.devcontainer/tests/test-proxy-acl.sh` | Exercise the allowlist against a live squid |
| `.devcontainer/tests/test-compose-topology.sh` | Assert the network shape compose actually builds |
| `.devcontainer/Dockerfile` | Dev image; loses the firewall tooling and the sudoers block |
| `.devcontainer/devcontainer.json` | Compose wiring |
| `.mcp.json` | Chromium proxy flag |
| `README.md` | Documentation |

Deleted: `.devcontainer/scripts/init-firewall.sh`, `.devcontainer/scripts/allowed-domains.txt`.

Tasks 1–4 change nothing about how the current devcontainer starts, so they are safe to land and test while working inside it. Task 5 is the switch-over, and Task 6 is the rebuild that proves it.

---

### Task 1: Proxy image and access policy

**Files:**
- Create: `.devcontainer/proxy/Dockerfile`
- Create: `.devcontainer/proxy/squid.conf`
- Create: `.devcontainer/proxy/entrypoint.sh`
- Create: `.devcontainer/proxy/allowed-domains.txt`
- Test: `.devcontainer/tests/test-proxy-acl.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: a build context at `.devcontainer/proxy/` yielding an image that listens on 3128 and applies the allowlist. Later tasks refer to it only as the `proxy` compose service.

- [ ] **Step 1: Write the failing test**

Create `.devcontainer/tests/test-proxy-acl.sh`:

```bash
#!/usr/bin/env bash
# Exercise the proxy's allowlist against a live squid, on a throwaway pair of
# networks mirroring docker-compose.yml. Needs a Docker daemon (DinD).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_DIR="$HERE/../proxy"
NET_ISO=acltest-isolated
NET_EGR=acltest-egress
CTR=acltest-proxy
IMG_PROXY=acltest-proxy-img
IMG_CLIENT=acltest-client-img

cleanup() {
    docker rm -f "$CTR" >/dev/null 2>&1 || true
    docker network rm "$NET_ISO" "$NET_EGR" >/dev/null 2>&1 || true
    docker rmi -f "$IMG_PROXY" "$IMG_CLIENT" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker build -q -t "$IMG_PROXY" "$PROXY_DIR" >/dev/null
# busybox wget sends an absolute-URI GET instead of CONNECT, which squid cannot
# serve for https, so the client needs real curl.
printf 'FROM alpine:3.20\nRUN apk add --no-cache curl\n' \
    | docker build -q -t "$IMG_CLIENT" - >/dev/null

docker network create --internal "$NET_ISO" >/dev/null
docker network create "$NET_EGR" >/dev/null
docker run -d --name "$CTR" --network "$NET_ISO" --network-alias proxy "$IMG_PROXY" >/dev/null
docker network connect "$NET_EGR" "$CTR"

for _ in $(seq 30); do
    if docker exec "$CTR" nc -z 127.0.0.1 3128 >/dev/null 2>&1; then break; fi
    sleep 1
done

failures=0

# expect <allow|deny> <url> [extra curl args...]
expect() {
    local want="$1" url="$2"; shift 2
    local got
    if docker run --rm --network "$NET_ISO" -e https_proxy=http://proxy:3128 \
        "$IMG_CLIENT" curl -s -o /dev/null --max-time 20 "$@" "$url" >/dev/null 2>&1
    then got=allow; else got=deny; fi
    if [ "$got" = "$want" ]; then
        printf 'ok   - %-34s %s\n' "$url" "$want"
    else
        printf 'FAIL - %-34s want %s, got %s\n' "$url" "$want" "$got" >&2
        failures=$((failures + 1))
    fi
}

# Leading-dot entries must cover the apex and arbitrary subdomains.
expect allow https://api.github.com/zen
expect allow https://github.com/
expect allow https://codeload.github.com/
expect allow https://raw.githubusercontent.com/
# Exact entries must match.
expect allow https://registry.npmjs.org/
expect allow https://pypi.org/
# Unlisted names must be refused even when they share infrastructure with
# something that is listed (storage.googleapis.com is allowed; this is not).
expect deny https://www.google.com/
expect deny https://example.com/
# A raw address must not bypass name-based filtering.
expect deny https://140.82.121.6/ -k

# With no proxy at all there is no route out of the internal network.
if docker run --rm --network "$NET_ISO" "$IMG_CLIENT" \
    curl -s -o /dev/null --max-time 10 https://api.github.com/zen >/dev/null 2>&1; then
    printf 'FAIL - %-34s reachable with no proxy\n' "direct egress" >&2
    failures=$((failures + 1))
else
    printf 'ok   - %-34s %s\n' "direct egress" "deny"
fi

if [ "$failures" -ne 0 ]; then
    printf '\n%d ACL check(s) failed.\n' "$failures" >&2
    exit 1
fi
printf '\nProxy ACL verified.\n'
```

Then `chmod +x .devcontainer/tests/test-proxy-acl.sh`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `.devcontainer/tests/test-proxy-acl.sh`
Expected: FAIL at the first `docker build`, because `.devcontainer/proxy/` does not exist yet. The error is `unable to prepare context: path ".../.devcontainer/proxy" not found`.

- [ ] **Step 3: Write the allowlist**

Create `.devcontainer/proxy/allowed-domains.txt`:

```
# Outbound allowlist for squid (see squid.conf). One entry per line.
#
# A leading dot matches the domain and every subdomain: `.github.com` covers
# github.com, api.github.com and codeload.github.com. An entry without a leading
# dot matches that exact host only.
#
# Baked into the proxy image by the Dockerfile. The dev container cannot reach the
# outer Docker daemon, so it cannot rebuild this image -- editing this file only
# takes effect after a devcontainer rebuild.

# GitHub. Replaces the old api.github.com/meta IP-range fetch entirely.
.github.com
.githubusercontent.com

# Language package registries
registry.npmjs.org
pypi.org
files.pythonhosted.org

# Anthropic / Claude Code
.claude.ai
api.anthropic.com
.sentry.io
.statsig.com
.statsig.anthropic.com

# VS Code server and extensions
marketplace.visualstudio.com
vscode.blob.core.windows.net
update.code.visualstudio.com

# Docker registry, for image pulls from the in-container daemon
.docker.io
production.cloudflare.docker.com

# Playwright browser downloads (post-create.sh)
cdn.playwright.dev
playwright.download.prss.microsoft.com
storage.googleapis.com
```

- [ ] **Step 4: Write the squid config**

Create `.devcontainer/proxy/squid.conf`:

```
http_port 3128

acl allowed_domains dstdomain "/etc/squid/allowed-domains.txt"
acl ip_literal      dstdom_regex ^([0-9]{1,3}\.){3}[0-9]{1,3}$
acl SSL_ports       port 443
acl CONNECT         method CONNECT

# Deny raw addresses first. Without this a client could pair an allowed hostname
# with an address of its choosing; with it, squid always resolves the name itself.
http_access deny  ip_literal
http_access deny  CONNECT !SSL_ports
http_access allow allowed_domains
http_access deny  all

cache deny all

# NOT /dev/stdout: squid drops to the `squid` user and cannot open the container's
# stdout pipe, and exits with FATAL if told to. entrypoint.sh tails these instead.
access_log stdio:/var/log/squid/access.log
```

- [ ] **Step 5: Write the entrypoint**

Create `.devcontainer/proxy/entrypoint.sh`:

```bash
#!/bin/sh
# squid drops privileges to the `squid` user, which cannot open the container's
# stdout pipe, so it logs to a file and root tails it into `docker logs`.
set -e

install -d -o squid -g squid /var/log/squid
: > /var/log/squid/access.log
chown squid:squid /var/log/squid/access.log
tail -F /var/log/squid/access.log &

exec squid -N -f /etc/squid/squid.conf
```

- [ ] **Step 6: Write the proxy Dockerfile**

Create `.devcontainer/proxy/Dockerfile`:

```dockerfile
FROM alpine:3.20

RUN apk add --no-cache squid

COPY squid.conf /etc/squid/squid.conf
COPY allowed-domains.txt /etc/squid/allowed-domains.txt
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

EXPOSE 3128
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `.devcontainer/tests/test-proxy-acl.sh`
Expected: ten `ok` lines and `Proxy ACL verified.`, exit 0.

If any allow case fails, read `docker logs acltest-proxy` before the trap tears it down — insert a `read -r` or comment out `cleanup` in the trap to inspect. `TCP_DENIED/403` means the ACL rejected it; `TCP_MISS_ABORTED/000` on a `GET https://...` line means the client did not use CONNECT.

- [ ] **Step 8: Commit**

```bash
git add .devcontainer/proxy .devcontainer/tests/test-proxy-acl.sh
git commit -m "Add a hostname-filtering squid proxy image"
```

---

### Task 2: Runtime isolation assertions

**Files:**
- Create: `.devcontainer/scripts/verify-isolation.sh`
- Test: covered by running it against the Task 1 stack (Step 2 below)

**Interfaces:**
- Consumes: `HTTPS_PROXY` / `https_proxy` pointing at `http://proxy:3128`, and `curl` on `PATH`.
- Produces: an executable at `.devcontainer/scripts/verify-isolation.sh` that exits 0 when isolation holds and non-zero otherwise. Task 5 wires it to `postStartCommand`.

- [ ] **Step 1: Write the script**

This task inverts the usual order: the script *is* the test, and Step 2 is the failing run. Create `.devcontainer/scripts/verify-isolation.sh`:

```bash
#!/usr/bin/env bash
# Assert this container's egress isolation is intact. Runs as postStartCommand, so a
# non-zero exit fails container start rather than letting the editor attach to a
# container whose network policy is not what it claims to be.
set -uo pipefail

ALLOWED_URL=https://api.github.com/zen
DENIED_URL=https://example.com/
failures=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; failures=$((failures + 1)); }

# 1. An allowed host answers through the proxy.
if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$ALLOWED_URL")" = 200 ]; then
    pass "allowed host reachable through the proxy ($ALLOWED_URL)"
else
    fail "allowed host NOT reachable through the proxy ($ALLOWED_URL)"
fi

# 2. An unlisted host is refused by the proxy. curl reports the refusal as
#    "CONNECT tunnel failed, response 403"; a timeout or a different code would mean
#    something other than the ACL stopped it.
#
#    The output is captured before being matched, not piped straight into grep: a
#    refused CONNECT also makes curl exit 56, and under `set -o pipefail` that failure
#    becomes the pipeline's status even when grep matched. Piping directly would make
#    this check fail in exactly the case it exists to confirm.
denied_output="$(curl -sS --max-time 20 -o /dev/null "$DENIED_URL" 2>&1)"
if printf '%s\n' "$denied_output" | grep -q 403; then
    pass "unlisted host refused with 403 ($DENIED_URL)"
else
    fail "unlisted host NOT refused with 403 ($DENIED_URL): ${denied_output:-<no output>}"
fi

# 3. With the proxy bypassed there is no route out at all. ALL_PROXY is unset along
#    with the protocol-specific variables: curl honours it as a catch-all, so leaving
#    it set would let this check route through a proxy while reporting that it did
#    not -- the one way this assertion could pass vacuously.
if env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy \
       -u ALL_PROXY -u all_proxy \
    curl -s -o /dev/null --max-time 10 "$ALLOWED_URL"; then
    fail "reached $ALLOWED_URL with the proxy bypassed - this container is NOT isolated"
else
    pass "no egress with the proxy bypassed"
fi

if [ "$failures" -ne 0 ]; then
    printf '\n%d isolation check(s) failed.\n' "$failures" >&2
    exit 1
fi
printf '\nEgress isolation verified.\n'
```

Then `chmod +x .devcontainer/scripts/verify-isolation.sh`.

- [ ] **Step 2: Run it in the current container to verify it fails**

Run: `.devcontainer/scripts/verify-isolation.sh`
Expected: FAIL. The current devcontainer has no proxy and unrestricted egress, so check 1 passes only incidentally, check 2 fails (`example.com` is reachable, no 403) and check 3 fails (`the container is NOT isolated`). Exit code 1. This confirms the assertions are not vacuous.

- [ ] **Step 3: Run it against a genuinely isolated container to verify it passes**

```bash
docker network create --internal vi-iso
docker network create vi-egr
docker build -q -t vi-proxy .devcontainer/proxy
docker run -d --name vi-proxy-c --network vi-iso --network-alias proxy vi-proxy
docker network connect vi-egr vi-proxy-c
printf 'FROM alpine:3.20\nRUN apk add --no-cache curl bash\n' | docker build -q -t vi-client -
sleep 5
docker run --rm --network vi-iso \
    -e HTTPS_PROXY=http://proxy:3128 -e https_proxy=http://proxy:3128 \
    -e HTTP_PROXY=http://proxy:3128 -e http_proxy=http://proxy:3128 \
    -v "$PWD/.devcontainer/scripts/verify-isolation.sh:/verify.sh:ro" \
    vi-client bash /verify.sh
```

Expected: three `ok` lines and `Egress isolation verified.`, exit 0.

- [ ] **Step 4: Tear down the scratch stack**

```bash
docker rm -f vi-proxy-c
docker network rm vi-iso vi-egr
docker rmi -f vi-proxy vi-client
```

- [ ] **Step 5: Commit**

```bash
git add .devcontainer/scripts/verify-isolation.sh
git commit -m "Add runtime egress isolation assertions"
```

---

### Task 3: Compose topology

**Files:**
- Create: `.devcontainer/docker-compose.yml`
- Test: `.devcontainer/tests/test-compose-topology.sh`

**Interfaces:**
- Consumes: the `.devcontainer/proxy/` build context from Task 1; `.devcontainer/Dockerfile` as the `dev` service's build context.
- Produces: services named `proxy` and `dev`, networks `isolated` (internal) and `egress`, volumes keyed `claude-code-config` and `claude-code-bashhistory`. Task 5's `devcontainer.json` refers to the service name `dev` and the workspace path `/workspaces/devcontainer-claude-code`.

- [ ] **Step 1: Write the failing test**

Create `.devcontainer/tests/test-compose-topology.sh`:

```bash
#!/usr/bin/env bash
# Assert the network shape compose actually builds: the dev network has no route
# out, only the proxy bridges to it, and the persisted volumes keep their names.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$HERE/../docker-compose.yml"
export devcontainerId=topotest
ISO_NET=devcontainer-claude-code_isolated

cleanup() {
    docker compose -f "$COMPOSE" down --remove-orphans >/dev/null 2>&1 || true
    docker volume rm -f claude-code-config-topotest claude-code-bashhistory-topotest \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

failures=0
check() {
    local label="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        printf 'ok   - %s\n' "$label"
    else
        printf 'FAIL - %s (want %s, got %s)\n' "$label" "$want" "$got" >&2
        failures=$((failures + 1))
    fi
}

resolved="$(docker compose -f "$COMPOSE" config --format json)"
q() { printf '%s' "$resolved" | jq -r "$1"; }

check "isolated network is internal" true "$(q '.networks.isolated.internal')"
check "config volume carries the devcontainerId suffix" \
    claude-code-config-topotest "$(q '.volumes["claude-code-config"].name')"
check "dev service is privileged" true "$(q '.services.dev.privileged')"
check "dev service is on the isolated network only" isolated \
    "$(q '.services.dev.networks | keys | join(",")')"
check "proxy service bridges both networks" egress,isolated \
    "$(q '.services.proxy.networks | keys | sort | join(",")')"

# Bring up only the proxy; building the full dev image here would take minutes and
# proves nothing about the topology.
docker compose -f "$COMPOSE" up -d --build proxy >/dev/null

check "dev network has no default route" "" \
    "$(docker run --rm --network "$ISO_NET" alpine:3.20 ip route 2>/dev/null | grep '^default' || true)"

check "proxy is reachable by alias from the dev network" reached \
    "$(docker run --rm --network "$ISO_NET" alpine:3.20 \
        sh -c 'nc -z proxy 3128 && echo reached' 2>/dev/null || true)"

check "proxy container has egress" ok \
    "$(docker compose -f "$COMPOSE" exec -T proxy \
        sh -c 'nslookup api.github.com >/dev/null 2>&1 && echo ok' 2>/dev/null || true)"

if [ "$failures" -ne 0 ]; then
    printf '\n%d topology check(s) failed.\n' "$failures" >&2
    exit 1
fi
printf '\nCompose topology verified.\n'
```

Then `chmod +x .devcontainer/tests/test-compose-topology.sh`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `.devcontainer/tests/test-compose-topology.sh`
Expected: FAIL — `no configuration file provided` / `stat .../docker-compose.yml: no such file or directory`, because the compose file does not exist yet.

- [ ] **Step 3: Write the compose file**

Create `.devcontainer/docker-compose.yml`:

```yaml
name: devcontainer-claude-code

networks:
  # internal:true means Docker creates no gateway for this network and drops traffic
  # that tries to leave it. That, not iptables inside the container, is the isolation:
  # there is nothing for a root process or a --privileged nested container to undo.
  isolated:
    internal: true
  egress:

volumes:
  # ${devcontainerId} cannot appear in the key -- compose validates key names against
  # ^[a-zA-Z0-9._-]+$ before interpolating -- but it does resolve in `name`.
  claude-code-config:
    name: claude-code-config-${devcontainerId}
  claude-code-bashhistory:
    name: claude-code-bashhistory-${devcontainerId}

services:
  proxy:
    build:
      context: ./proxy
    networks:
      isolated:
        aliases:
          - proxy
      egress:
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "nc", "-z", "127.0.0.1", "3128"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 5s

  dev:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        progress: plain
    # The docker-in-docker feature requests privileged through its feature metadata,
    # which the devcontainer CLI applies only to image/Dockerfile-based containers --
    # a compose service has to ask for it. This does not weaken the isolation:
    # privileged grants capabilities inside this container's own network namespace,
    # and that namespace still has no route out.
    privileged: true
    networks:
      - isolated
    depends_on:
      proxy:
        condition: service_healthy
    # Chromium (Playwright MCP) crashes with the default 64MB /dev/shm.
    shm_size: 1gb
    # devcontainer.json's overrideCommand defaults to false for compose, so the
    # service must stay up on its own.
    command: sleep infinity
    environment:
      # containerEnv in devcontainer.json is ignored for compose services, so every
      # variable the container needs lives here.
      #
      # Claude Code's global config lives at ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json
      # (account binding, trust flags). Pointing it at the mounted ~/.claude keeps it,
      # plus projects/, sessions/ and history, inside the persisted volume.
      CLAUDE_CONFIG_DIR: /home/vscode/.claude
      HTTP_PROXY: http://proxy:3128
      HTTPS_PROXY: http://proxy:3128
      http_proxy: http://proxy:3128
      https_proxy: http://proxy:3128
      NO_PROXY: localhost,127.0.0.1,::1
      no_proxy: localhost,127.0.0.1,::1
    volumes:
      - ..:/workspaces/devcontainer-claude-code:cached
      - claude-code-config:/home/vscode/.claude
      - claude-code-bashhistory:/commandhistory
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `.devcontainer/tests/test-compose-topology.sh`
Expected: eight `ok` lines and `Compose topology verified.`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add .devcontainer/docker-compose.yml .devcontainer/tests/test-compose-topology.sh
git commit -m "Add compose topology isolating the dev service behind the proxy"
```

---

### Task 4: Strip the firewall tooling from the dev image

**Files:**
- Modify: `.devcontainer/Dockerfile`
- Delete: `.devcontainer/scripts/init-firewall.sh`, `.devcontainer/scripts/allowed-domains.txt`

**Interfaces:**
- Consumes: nothing.
- Produces: a dev image with no iptables tooling and the base image's default sudo configuration. Task 5 relies on `.devcontainer/scripts/` containing only `post-create.sh` and `verify-isolation.sh`.

- [ ] **Step 1: Confirm the image builds today, for a baseline**

Run: `docker build -q -t devimg-baseline -f .devcontainer/Dockerfile .devcontainer`
Expected: succeeds. Note the elapsed time; the edited build should be no slower.

- [ ] **Step 2: Remove the firewall packages**

In `.devcontainer/Dockerfile`, delete these four lines from the first `apt-get install` list:

```
        iptables \
        ipset \
        dnsutils \
        aggregate \
```

Nothing else in that list changes. `bubblewrap` and `socat` stay: Claude Code's Bash sandbox still uses them, and it remains useful as a second, process-level layer.

- [ ] **Step 3: Remove the firewall copy and the sudoers block**

Delete these two blocks from the end of `.devcontainer/Dockerfile`, including their comments:

```dockerfile
# Egress firewall, baked into the image. Under a distinct name because the
# claude-code feature later writes its own /usr/local/bin/init-firewall.sh, which
# we leave unused. Living outside the workspace mount also means a process in the
# container can't widen its own allowlist -- edits need a rebuild.
COPY scripts/init-firewall.sh /usr/local/bin/devcontainer-init-firewall.sh
COPY scripts/allowed-domains.txt /usr/local/etc/allowed-domains.txt
RUN chmod 0755 /usr/local/bin/devcontainer-init-firewall.sh \
    && chmod 0644 /usr/local/etc/allowed-domains.txt

# Narrow sudo to just that script, revoking the base image's blanket passwordless
# sudo. The feature's init-firewall.sh is deliberately not granted: narrower
# allowlist, and it drops the Docker DNS rules.
RUN rm -f /etc/sudoers.d/vscode \
    && echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/devcontainer-init-firewall.sh" > /etc/sudoers.d/vscode-firewall \
    && chmod 0440 /etc/sudoers.d/vscode-firewall
```

The sudo narrowing existed to protect the firewall from the container it constrained. Egress control now lives outside the container entirely, so the base image's default passwordless sudo is restored and `apt install` works during development again.

- [ ] **Step 4: Delete the firewall script and its allowlist**

```bash
git rm .devcontainer/scripts/init-firewall.sh .devcontainer/scripts/allowed-domains.txt
```

- [ ] **Step 5: Verify the edited image builds and no longer carries the tooling**

```bash
docker build -q -t devimg-edited -f .devcontainer/Dockerfile .devcontainer
docker run --rm devimg-edited sh -c '
    for b in iptables ipset dig; do
        command -v "$b" >/dev/null && { echo "FAIL - $b still present"; exit 1; }
    done
    test -f /usr/local/bin/devcontainer-init-firewall.sh && { echo "FAIL - firewall script still present"; exit 1; }
    test -f /etc/sudoers.d/vscode || { echo "FAIL - base sudoers not restored"; exit 1; }
    test -f /etc/sudoers.d/vscode-firewall && { echo "FAIL - firewall sudoers still present"; exit 1; }
    command -v bwrap >/dev/null || { echo "FAIL - bubblewrap missing"; exit 1; }
    command -v socat >/dev/null || { echo "FAIL - socat missing"; exit 1; }
    echo "ok - dev image is clean"
'
docker rmi -f devimg-baseline devimg-edited
```

Expected: `ok - dev image is clean`.

- [ ] **Step 6: Commit**

```bash
git add .devcontainer/Dockerfile .devcontainer/scripts
git commit -m "Drop the iptables egress firewall from the dev image"
```

---

### Task 5: Switch the devcontainer to compose

**Files:**
- Modify: `.devcontainer/devcontainer.json` (whole file replaced)
- Modify: `.mcp.json:6-11`

**Interfaces:**
- Consumes: the `dev` service and the `/workspaces/devcontainer-claude-code` mount target from Task 3; `verify-isolation.sh` from Task 2.
- Produces: the switched-over configuration that Task 6 rebuilds against.

This is the point of no return for the running container: after this commit, reopening requires the new stack to work. Task 6 carries the rollback procedure.

- [ ] **Step 1: Write the failing test**

There is no new script here; the check is a shape assertion on the two edited files. Run it now, before editing:

```bash
docker run --rm -v "$PWD:/w:ro" -w /w alpine:3.20 sh -c '
    apk add -q --no-cache jq >/dev/null
    fails=0
    j=.devcontainer/devcontainer.json
    # devcontainer.json permits comments, so strip them before parsing.
    # Strip whole-line // comments only; a blanket s://.*:: would eat URLs.
    cfg=$(sed "s:^[[:space:]]*//.*::" "$j" | jq -c .) || { echo "FAIL - $j is not parseable"; exit 1; }
    for k in dockerComposeFile service workspaceFolder shutdownAction mounts; do
        echo "$cfg" | jq -e "has(\"$k\")" >/dev/null || { echo "FAIL - $j missing $k"; fails=1; }
    done
    # runArgs is the only key a compose devcontainer genuinely ignores, so it and the
    # now-redundant build/containerEnv should be gone from devcontainer.json. mounts
    # stays -- the CLI merges it into the dev service's volumes -- so it belongs in the
    # "must be present" loop above, not here.
    for k in build runArgs containerEnv; do
        echo "$cfg" | jq -e "has(\"$k\")" >/dev/null && { echo "FAIL - $j still has $k"; fails=1; }
    done
    echo "$cfg" | jq -e ".postStartCommand | test(\"verify-isolation\")" >/dev/null \
        || { echo "FAIL - postStartCommand does not run verify-isolation.sh"; fails=1; }
    jq -e ".mcpServers.playwright.args | index(\"--proxy-server=http://proxy:3128\")" .mcp.json >/dev/null \
        || { echo "FAIL - .mcp.json missing the Chromium proxy flag"; fails=1; }
    [ "$fails" = 0 ] && echo "ok - devcontainer wiring is correct"
    exit "$fails"
'
```

Expected: FAIL with `missing dockerComposeFile`, `still has build`, `still has runArgs`, `still has containerEnv`, `postStartCommand does not run verify-isolation.sh`, and `.mcp.json missing the Chromium proxy flag`.

**Corrected 2026-09-06, after the final review:** this snippet originally also asserted `mounts` gone, and expected a matching `still has mounts` failure here. Both were wrong — `mounts` is genuinely merged into the service's `volumes:` by the CLI (only `runArgs` is ignored), and the design deliberately keeps it in `devcontainer.json` (see risk item 1 in the spec). The loop and the expected output above now check for its presence instead of its absence.

- [ ] **Step 2: Replace `.devcontainer/devcontainer.json`**

```jsonc
{
  "name": "devcontainer-claude-code",
  // Compose, not a bare Dockerfile: the dev service sits on an internal network with
  // no route out, and only the proxy service bridges to the internet. See
  // docker-compose.yml. runArgs is the one key compose devcontainers ignore, so its
  // former contents live in the compose file; mounts and containerEnv are merged
  // into the dev service by the CLI and still work from here.
  "dockerComposeFile": "docker-compose.yml",
  "service": "dev",
  "workspaceFolder": "/workspaces/devcontainer-claude-code",
  "shutdownAction": "stopCompose",
  "remoteUser": "vscode",
  "features": {
    "ghcr.io/devcontainers/features/node:2": {
      "version": "latest",
      "nodeGypDependencies": true
    },
    "ghcr.io/devcontainers/features/python:1": {
      "version": "latest"
    },
    "ghcr.io/devcontainers/features/docker-in-docker:4": {
      "version": "latest",
      "moby": true
    },
    "ghcr.io/anthropics/devcontainer-features/claude-code:1.0": {}
  },
  "postCreateCommand": "bash .devcontainer/scripts/post-create.sh ${containerWorkspaceFolder}",
  // Fails container start if egress isolation is not what the compose file claims.
  "postStartCommand": "bash .devcontainer/scripts/verify-isolation.sh",
  "waitFor": "postStartCommand",
  "customizations": {
    "vscode": {
      "extensions": [
        "anthropic.claude-code",
        "wenbopan.vscode-terminal-osc-notifier"
      ],
      "settings": {
        "terminal.integrated.defaultProfile.linux": "bash",
        "security.workspace.trust.enabled": false
      }
    }
  }
}
```

`INIT_FIREWALL` is gone. It existed because the IP-snapshot firewall was too unreliable to leave on; removing that unreliability is the point of this change, and a compose network's `internal` flag is not a clean thing to toggle at runtime.

**Corrected 2026-09-06, after the final review:** the comment above originally read "runArgs, mounts and containerEnv are ignored for compose devcontainers, so all three now live in the compose file." Only `runArgs` is actually ignored; `mounts` and `containerEnv` are merged in by the CLI, which is why `mounts` is still declared here rather than in `docker-compose.yml`.

- [ ] **Step 3: Add the Chromium proxy flag**

Chromium does not read `HTTPS_PROXY`. Replace the `args` array in `.mcp.json` with:

```json
      "args": [
        "--browser",
        "chromium",
        "--headless",
        "--no-sandbox",
        "--proxy-server=http://proxy:3128"
      ]
```

- [ ] **Step 4: Re-run the shape assertion to verify it passes**

Run the same command as Step 1.
Expected: `ok - devcontainer wiring is correct`, exit 0.

- [ ] **Step 5: Re-run the topology test, which now also covers the dev service build**

Run: `.devcontainer/tests/test-compose-topology.sh`
Expected: eight `ok` lines and `Compose topology verified.`, exit 0. This confirms Task 4's Dockerfile edits did not break the compose build context.

- [ ] **Step 6: Commit**

```bash
git add .devcontainer/devcontainer.json .mcp.json
git commit -m "Run the devcontainer under compose behind the egress proxy"
```

---

### Task 6: Rebuild for real, then document

**Files:**
- Modify: `README.md:11-16` (the firewall bullet list) and `README.md:26` (the Playwright firewall note)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing further depends on this task.

**Before you rebuild, do Step 1.** It has to run before Step 2, and it has to run against the right daemon, or there is nothing to compare afterwards.

- [ ] **Step 1: Record the persisted volume names, before rebuilding**

Run this against the **host** Docker daemon — the one hosting this devcontainer. It is not the daemon reached by `docker` commands run *inside* this devcontainer (that is the in-container docker-in-docker daemon, a separate daemon that has never heard of these volumes). Open a terminal on the host, or use `Dev Containers: Reopen Folder Locally` first, then run:

```bash
docker volume ls --format '{{.Name}}' | grep claude-code
```

Expected: two volumes from the current image/Dockerfile-based devcontainer, e.g. `claude-code-config-<old-id>` and `claude-code-bashhistory-<old-id>`. **Write these two full names down** — Step 3 needs them.

Why this is worth doing: `${devcontainerId}` is a hash over the container's identifying labels, and which labels those are depends on the configuration style — an image/Dockerfile devcontainer is identified by `devcontainer.local_folder` plus `devcontainer.config_file`; a compose devcontainer, which this rebuild switches to, by `com.docker.compose.project` plus `com.docker.compose.service`. Different inputs to the hash mean the id is very likely to change, which is close to a certainty here, not a remote possibility. When it does, the rebuild attaches to fresh, empty `claude-code-config-<new-id>` and `claude-code-bashhistory-<new-id>` volumes instead of the ones in use — a fresh Claude Code login and an empty shell history — even though `devcontainer.json`'s `mounts` are written correctly. This happens regardless of anything the branch got wrong; recording the old names now is what makes it recoverable in Step 3.

- [ ] **Step 2: Rebuild the container**

Run `Dev Containers: Rebuild Container` from the VS Code command palette. This is a human action; an agent executing this plan should stop here and hand back.

Expected: the build completes and `postStartCommand` prints four `ok` lines ending in `Egress isolation verified.` A run with one or more `WARN` lines (a host merely unreachable — laptop offline, proxy still starting) still starts and ends in `Egress isolation holds; N connectivity warning(s) above. Starting anyway.`; only a `FATAL` line fails the start.

**If the rebuild fails and you cannot get back in:** reopen the folder locally (`Dev Containers: Reopen Folder Locally`), run `git revert --no-edit <task-5-commit>`, and rebuild. Tasks 1–4 are inert on their own, so reverting Task 5 alone restores the previous working container.

- [ ] **Step 3: Confirm the persisted volumes, and migrate them if the id changed**

Back on the **host** daemon (same caveat as Step 1 — not the in-container one):

```bash
docker volume ls --format '{{.Name}}' | grep claude-code
```

Compare the two names against what you wrote down in Step 1.

- **Names match:** nothing to do, the id was stable.
- **Suffix differs** (expect this): the volumes from Step 1 are untouched — the rebuild does not delete them, so nothing is lost yet — but the container is now writing into new, empty volumes: a fresh Claude Code login and an empty shell history. Stop the devcontainer first so nothing is writing to either side, then, against the host daemon, run once per volume:

  ```bash
  docker run --rm -v <old>:/from -v <new>:/to alpine cp -a /from/. /to/
  ```

  substituting the Step 1 name for `<old>` and the name just listed for `<new>`, once for the config volume and once for the bashhistory volume. Re-open the devcontainer afterwards. Skipping this migration costs a re-login and empty history and nothing else; delete the old volumes only once you've confirmed the new ones have what you need.
- **Suffix is empty** (`claude-code-config-`): the devcontainer CLI did not substitute `${devcontainerId}` at all. The name is still stable across rebuilds, so this is cosmetic — note it, no migration needed.

- [ ] **Step 4: Confirm the toolchain works through the proxy**

```bash
git ls-remote https://github.com/anthropics/claude-code >/dev/null && echo "ok - git"
npm view @playwright/mcp version >/dev/null && echo "ok - npm"
pip download --no-deps --dest /tmp/pipcheck requests >/dev/null && echo "ok - pip"
docker pull alpine:3.20 >/dev/null && echo "ok - dind pull"
curl -sS -o /dev/null https://example.com 2>&1 | grep -q 403 && echo "ok - unlisted host blocked"
```

Expected: five `ok` lines. Any failure that is a proxy refusal names the domain in the error; add it to `.devcontainer/proxy/allowed-domains.txt` and rebuild. `console.anthropic.com`, `.vsassets.io` and `vscode.download.prss.microsoft.com` were already added ahead of this rebuild to close gaps found before the first interactive run; expect at most one or two more here.

- [ ] **Step 5: Confirm Playwright MCP still drives a browser**

Ask Claude Code to navigate to `https://github.com` with the Playwright MCP tools.
Expected: a page snapshot comes back. A blank or error page means Chromium is not using `--proxy-server`; re-check Step 3 of Task 5.

- [ ] **Step 6: Rewrite the README's firewall section**

Replace the paragraph and bullets currently spanning `README.md:11-16` with:

```markdown
On first creation, the Node.js / Python / Docker-in-Docker / Claude Code features are set up. Egress is restricted at all times: the container sits on an `internal` Docker network with no route to the internet, and the only way out is a squid forward proxy running in a separate container that allows the hostnames listed in `.devcontainer/proxy/allowed-domains.txt`.

- Filtering is by **hostname**, not IP, so CDN address changes cannot break it. A leading dot covers subdomains: `.github.com` matches `github.com`, `api.github.com` and `codeload.github.com`.
- To change what is reachable, edit `.devcontainer/proxy/allowed-domains.txt` and rebuild. The list is baked into the proxy image, which the dev container cannot reach, so a process inside cannot widen its own egress.
- A blocked request gets a squid 403 naming the domain, rather than failing silently.
- Isolation is structural, not a firewall rule: there is no default route out of the dev container, so root and `--privileged` nested containers are equally contained. `.devcontainer/scripts/verify-isolation.sh` asserts this on every container start and fails the start if isolation is genuinely broken; a network that is merely unreachable is reported as a warning and the container still opens.
- Nested containers do not inherit the proxy. Image pulls work because the in-container Docker daemon picks up the proxy variables from its own environment, but a process started by `docker run` gets none of them and will hang until timeout on any network access. Pass them explicitly when you need egress from a nested container: `docker run -e HTTPS_PROXY=http://proxy:3128 -e HTTP_PROXY=http://proxy:3128 ...`.
- `.devcontainer/tests/` holds the proxy ACL and compose topology tests. Both need the in-container Docker daemon; run them with `.devcontainer/tests/test-proxy-acl.sh` and `.devcontainer/tests/test-compose-topology.sh`.
```

- [ ] **Step 7: Update the Playwright note**

Replace the bullet at `README.md:26` (`**With the firewall enabled, general web browsing does not work.**`) with:

```markdown
- **General web browsing does not work.** Only the hostnames in `.devcontainer/proxy/allowed-domains.txt` are reachable, so any site you want to visit has to be added there followed by a rebuild. Chromium does not read `HTTPS_PROXY`, so `.mcp.json` passes `--proxy-server=http://proxy:3128` explicitly.
```

- [ ] **Step 8: Commit**

```bash
git add README.md
git commit -m "Document the proxy-based egress isolation"
```

---

## Self-review notes

Checked against the spec on 2026-09-06:

- Every spec component maps to a task: proxy image and squid.conf and entrypoint and allowlist (Task 1), verify-isolation.sh (Task 2), docker-compose.yml (Task 3), Dockerfile edits and init-firewall.sh deletion (Task 4), devcontainer.json and .mcp.json (Task 5), README (Task 6).
- Spec risk 1 (`${devcontainerId}`) is resolved in the spec and encoded in `devcontainer.json`'s `mounts` (Task 5), with a fallback check in Task 6 Steps 1 and 3.
- Spec risks 3, 4 and 5 (VS Code server, `post-create.sh` reachability, allowlist completeness) are covered by Task 6 Steps 2 and 4.
- Spec risk 2 (Claude Code's Bash sandbox proxy) has no dedicated step because it can only be observed in the rebuilt container. It surfaces in Task 6 Step 4, whose commands run through the Bash tool and therefore through the sandbox. If sandboxed Bash cannot reach allowed hosts while unsandboxed Bash can, that is this risk; the fix is to add the sandbox's own proxy port to `NO_PROXY` in `docker-compose.yml`.
- **Corrected 2026-09-06, after the final review:** the first bullet used to credit Task 3's `name:` interpolation for spec risk 1. The spec's own resolution of that risk (2026-09-06) found that form does not work at all — `${devcontainerId}` never reaches a compose file — and moved the volumes to `devcontainer.json`'s `mounts` instead, which is what Task 5 actually ships.
- Names used across tasks are consistent: service `dev`, service `proxy`, alias `proxy`, port 3128, network `isolated`, compose network name `devcontainer-claude-code_isolated`, volume keys `claude-code-config` / `claude-code-bashhistory`.
