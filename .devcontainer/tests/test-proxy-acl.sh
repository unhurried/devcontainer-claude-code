#!/usr/bin/env bash
# Exercise the allowlist against a live squid on throwaway networks. Needs Docker.
# Also covers PROXY_MODE=open.
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
# busybox wget cannot CONNECT, so the client needs real curl.
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
# Any docker run failure reads as `deny`; the `allow` cases run first and would catch that.
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

# Leading-dot entries: apex and subdomains.
expect allow https://api.github.com/zen
expect allow https://github.com/
expect allow https://codeload.github.com/
expect allow https://raw.githubusercontent.com/
expect allow https://downloads.claude.ai/
# Exact entries.
expect allow https://registry.npmjs.org/
expect allow https://pypi.org/
# Unlisted names, even ones sharing infrastructure with a listed one.
expect deny https://www.google.com/
expect deny https://example.com/
# A raw address must not bypass name-based filtering.
expect deny https://140.82.121.6/ -k

# No route out without the proxy.
if docker run --rm --network "$NET_ISO" "$IMG_CLIENT" \
    curl -s -o /dev/null --max-time 10 https://api.github.com/zen >/dev/null 2>&1; then
    printf 'FAIL - %-34s reachable with no proxy\n' "direct egress" >&2
    failures=$((failures + 1))
else
    printf 'ok   - %-34s %s\n' "direct egress" "deny"
fi

# PROXY_MODE=open lifts the allowlist; the raw-address deny stays.
docker rm -f "$CTR" >/dev/null 2>&1 || true
docker run -d --name "$CTR" --network "$NET_ISO" --network-alias proxy \
    -e PROXY_MODE=open "$IMG_PROXY" >/dev/null
docker network connect "$NET_EGR" "$CTR"
for _ in $(seq 30); do
    if docker exec "$CTR" nc -z 127.0.0.1 3128 >/dev/null 2>&1; then break; fi
    sleep 1
done

printf -- '-- PROXY_MODE=open --\n'
expect allow https://www.google.com/
expect allow https://example.com/
expect deny  https://140.82.121.6/ -k

if [ "$failures" -ne 0 ]; then
    printf '\n%d ACL check(s) failed.\n' "$failures" >&2
    exit 1
fi
printf '\nProxy ACL verified.\n'
