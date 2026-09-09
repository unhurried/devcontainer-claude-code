#!/usr/bin/env bash
# Assert the network shape compose actually builds: the dev network has no route out,
# only the proxy bridges to it, and the persisted volumes are declared where
# ${devcontainerId} can resolve.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$HERE/../docker-compose.yml"
DEVCONTAINER_JSON="$HERE/../devcontainer.json"
# A distinct project name, not the compose file's own `name:`: without -p, `down`
# would stop the live devcontainer and its proxy.
PROJECT=topotest
ISO_NET="${PROJECT}_isolated"

cleanup() {
    # --rmi local drops the proxy image built under this project name; without it every
    # run leaves another topotest-proxy:latest behind.
    docker compose -p "$PROJECT" -f "$COMPOSE" down --remove-orphans --rmi local \
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

resolved="$(docker compose -p "$PROJECT" -f "$COMPOSE" config --format json)"
q() { printf '%s' "$resolved" | jq -r "$1"; }

check "isolated network is internal" true "$(q '.networks.isolated.internal')"
check "dev service is privileged" true "$(q '.services.dev.privileged')"
check "dev service is on the isolated network only" isolated \
    "$(q '.services.dev.networks | keys | join(",")')"
check "proxy service bridges both networks" egress,isolated \
    "$(q '.services.proxy.networks | keys | sort | join(",")')"

# The CLI substitutes ${devcontainerId} only in devcontainer.json, so assert both
# mounts live there and the compose file carries no such token.
check "devcontainer.json mounts both volumes with a \${devcontainerId} suffix" 2 \
    "$(grep -c '^\s*"source=claude-code-\(config\|bashhistory\)-\${devcontainerId},' \
        "$DEVCONTAINER_JSON" || true)"
check "compose file interpolates no \${devcontainerId}" 0 \
    "$(grep -v '^[[:space:]]*#' "$COMPOSE" | grep -c 'devcontainerId' || true)"

# Only the proxy: building the dev image takes minutes and proves nothing here.
docker compose -p "$PROJECT" -f "$COMPOSE" up -d --build proxy >/dev/null

# Mark the probe's own failure explicitly: comparing raw output against "" would make
# a missing image or daemon error look like the property holding.
routes="$(docker run --rm --network "$ISO_NET" alpine:3.20 ip route)" || routes="PROBE-FAILED"
check "dev network has no default route" "" \
    "$(printf '%s\n' "$routes" | grep -E '^default|PROBE-FAILED' || true)"

check "proxy is reachable by alias from the dev network" reached \
    "$(docker run --rm --network "$ISO_NET" alpine:3.20 \
        sh -c 'nc -z proxy 3128 && echo reached' 2>/dev/null || true)"

check "proxy container has egress" ok \
    "$(docker compose -p "$PROJECT" -f "$COMPOSE" exec -T proxy \
        sh -c 'nslookup api.github.com >/dev/null 2>&1 && echo ok' 2>/dev/null || true)"

if [ "$failures" -ne 0 ]; then
    printf '\n%d topology check(s) failed.\n' "$failures" >&2
    exit 1
fi
printf '\nCompose topology verified.\n'
