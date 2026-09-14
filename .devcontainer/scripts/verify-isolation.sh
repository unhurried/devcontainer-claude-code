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
    warn "allowed host NOT reachable through the proxy ($ALLOWED_URL, got ${allowed_code:-<none>}) - connectivity, not isolation"
fi

# 2. An unlisted host is refused by the proxy.
#      curl exit 0      -> the ACL is not filtering
#      "response 403"   -> the ACL is working
#      anything else    -> the proxy could not be reached
#    Output is captured, not piped: a refused CONNECT exits 56, and under pipefail
#    that would fail the check. Under PROXY_MODE=open the host is expected to answer.
denied_output="$(curl -sS --max-time 20 -o /dev/null "$DENIED_URL" 2>&1)"
denied_rc=$?
if [ "${PROXY_MODE:-allowlist}" = open ]; then
    if [ "$denied_rc" -eq 0 ]; then
        pass "unlisted host reachable through the proxy ($DENIED_URL) - PROXY_MODE=open, allowlist disabled"
    else
        warn "PROXY_MODE=open but $DENIED_URL was not reachable: ${denied_output:-<no output>} - connectivity, not isolation"
    fi
elif [ "$denied_rc" -eq 0 ]; then
    fatal "unlisted host $DENIED_URL was REACHABLE through the proxy - the allowlist is not being enforced"
elif printf '%s\n' "$denied_output" | grep -q 'response 403'; then
    pass "unlisted host refused with 403 ($DENIED_URL)"
else
    warn "could not reach the proxy to test $DENIED_URL: ${denied_output:-<no output>} - connectivity, not isolation"
fi

# 3. With the proxy bypassed there is no route out.
#    ALL_PROXY too: curl honours it as a catch-all.
noproxy() { env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy \
                -u ALL_PROXY -u all_proxy "$@"; }

if noproxy curl -s -o /dev/null --max-time 10 "$ALLOWED_URL"; then
    fatal "reached $ALLOWED_URL with the proxy bypassed - this container is NOT isolated"
else
    pass "no egress to a hostname with the proxy bypassed"
fi

# 3b. Same, against a literal address: check 3 also passes on a DNS failure.
if noproxy curl -k -s -o /dev/null --max-time 10 "$DENIED_IP_URL"; then
    fatal "reached $DENIED_IP_URL with the proxy bypassed - this container has a route out"
else
    pass "no egress to a raw address with the proxy bypassed"
fi

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
