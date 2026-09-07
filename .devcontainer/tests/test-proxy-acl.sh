#!/usr/bin/env bash
# Exercise the proxy's allowlist against a live squid, on a throwaway pair of
# networks mirroring docker-compose.yml. Needs a Docker daemon (DinD).
#
# Also covers PROXY_MODE=open (see ../.env): the same denied cases should flip to
# allowed once the domain allowlist is turned off.
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
# Any docker run failure reads as `deny` here; that is only safe because the `expect
# allow` cases run first on the same image and network and would fail loudly first.
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

# PROXY_MODE=open must lift the domain allowlist without opening a route around the
# proxy: swap the same container for one built with PROXY_MODE=open and re-run the
# previously-denied cases expecting them to pass now.
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
expect allow https://140.82.121.6/ -k

if [ "$failures" -ne 0 ]; then
    printf '\n%d ACL check(s) failed.\n' "$failures" >&2
    exit 1
fi
printf '\nProxy ACL verified.\n'
