#!/usr/bin/env bash
# Check egress isolation on every container start. A real isolation failure is fatal
# and blocks the editor from attaching; mere unreachability only warns.
#
#   fatal   - an unlisted host answered through the proxy (unless PROXY_MODE=open)
#   fatal   - anything was reachable with the proxy bypassed
#   warning - an allowed host, or the proxy itself, did not answer
set -uo pipefail

ALLOWED_URL=https://registry.npmjs.org/
DENIED_URL=https://example.com/
# GitHub's address. Needs no DNS, so this probe can only fail on routing.
DENIED_IP_URL=https://140.82.121.6/

fatals=0
warnings=0

pass()  { printf 'ok    - %s\n' "$1"; }
warn()  { printf 'WARN  - %s\n' "$1" >&2; warnings=$((warnings + 1)); }
fatal() { printf 'FATAL - %s\n' "$1" >&2; fatals=$((fatals + 1)); }

# 1. An allowed host answers through the proxy.
#    Not api.github.com: its unauthenticated rate limit would look like a failure.
allowed_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$ALLOWED_URL")"
if [ "$allowed_code" = 200 ]; then
    pass "allowed host reachable through the proxy ($ALLOWED_URL)"
else
    warn "allowed host NOT reachable through the proxy ($ALLOWED_URL, got $allowed_code) - connectivity, not isolation"
fi

# 2. An unlisted host is refused by the proxy. http_connect is the proxy's answer to
#    CONNECT: 403 = the ACL refused it, 200 = it let it through, 000 = no proxy.
#    Under PROXY_MODE=open the host is expected to get through.
denied_code="$(curl -s -o /dev/null -w '%{http_connect}' --max-time 20 "$DENIED_URL")"
if [ "${PROXY_MODE:-allowlist}" = open ]; then
    if [ "$denied_code" = 200 ]; then
        pass "unlisted host reachable through the proxy ($DENIED_URL) - PROXY_MODE=open, allowlist disabled"
    else
        warn "PROXY_MODE=open but $DENIED_URL was not reachable (CONNECT got $denied_code) - connectivity, not isolation"
    fi
elif [ "$denied_code" = 200 ]; then
    fatal "unlisted host $DENIED_URL was REACHABLE through the proxy - the allowlist is not being enforced"
elif [ "$denied_code" = 403 ]; then
    pass "unlisted host refused with 403 ($DENIED_URL)"
else
    warn "could not reach the proxy to test $DENIED_URL (CONNECT got $denied_code) - connectivity, not isolation"
fi

# 3. With the proxy bypassed there is no route out. --noproxy '*' ignores every
#    proxy env var, ALL_PROXY included. Also against a literal address, so a DNS
#    failure alone cannot make the hostname probe pass.
direct() {
    local url="$1" what="$2"
    if curl --noproxy '*' -k -s -o /dev/null --max-time 10 "$url"; then
        fatal "reached $url with the proxy bypassed - this container is NOT isolated"
    else
        pass "no egress to $what with the proxy bypassed"
    fi
}
direct "$ALLOWED_URL" "a hostname"
direct "$DENIED_IP_URL" "a raw address"

if [ "$fatals" -ne 0 ]; then
    printf '\n%d isolation check(s) failed. Refusing to start.\n' "$fatals" >&2
    exit 1
fi
if [ "$warnings" -ne 0 ]; then
    printf '\nEgress isolation holds; %d connectivity warning(s) above. Starting anyway.\n' "$warnings"
    exit 0
fi
printf '\nEgress isolation verified.\n'
exit 0
