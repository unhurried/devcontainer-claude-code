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
