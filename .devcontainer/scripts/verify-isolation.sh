#!/usr/bin/env bash
# Assert this container's egress isolation is intact. Runs as postStartCommand with
# waitFor: postStartCommand, so a non-zero exit blocks the editor from attaching.
#
# Only a real isolation failure is fatal; mere unreachability (offline, proxy still
# starting, upstream outage) warns and lets the container start.
#
#   fatal   - the unlisted host answered through the proxy (ACL not filtering),
#             unless PROXY_MODE=open, where that is intended
#   fatal   - anything was reachable with the proxy bypassed (a route out exists)
#   warning - an allowed host did not answer
#   warning - the proxy itself could not be reached
set -uo pipefail

ALLOWED_URL=https://registry.npmjs.org/
DENIED_URL=https://example.com/
# GitHub's address, used only as a literal known to route: probing it needs no DNS, so
# unlike the hostname probe it can only fail on the absence of a route.
DENIED_IP_URL=https://140.82.121.6/

fatals=0
warnings=0

pass()  { printf 'ok    - %s\n' "$1"; }
warn()  { printf 'WARN  - %s\n' "$1" >&2; warnings=$((warnings + 1)); }
fatal() { printf 'FATAL - %s\n' "$1" >&2; fatals=$((fatals + 1)); }

# 1. An allowed host answers through the proxy. Not api.github.com: unauthenticated it
#    is rate limited to 60/hr, and a 403 from the limiter would look like a failure.
allowed_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$ALLOWED_URL")"
if [ "$allowed_code" = 200 ]; then
    pass "allowed host reachable through the proxy ($ALLOWED_URL)"
else
    warn "allowed host NOT reachable through the proxy ($ALLOWED_URL, got ${allowed_code:-<none>}) - connectivity, not isolation"
fi

# 2. An unlisted host is refused by the proxy. Three outcomes to tell apart:
#      curl exit 0            -> the host answered: the ACL is not filtering
#      "response 403"         -> the ACL is doing its job
#      any other error        -> the proxy could not be reached at all
#
#    Output is captured before matching rather than piped into grep: a refused CONNECT
#    also exits 56, and under pipefail that would fail the check in the very case it
#    exists to confirm.
#
#    Under PROXY_MODE=open (see ../.env) the allowlist is deliberately off, so the
#    unlisted host answering is the correct outcome.
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

# 3. With the proxy bypassed there is no route out at all. ALL_PROXY must be unset too:
#    curl honours it as a catch-all, and leaving it set would route this check through
#    the proxy while reporting that it did not.
noproxy() { env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy \
                -u ALL_PROXY -u all_proxy "$@"; }

if noproxy curl -s -o /dev/null --max-time 10 "$ALLOWED_URL"; then
    fatal "reached $ALLOWED_URL with the proxy bypassed - this container is NOT isolated"
else
    pass "no egress to a hostname with the proxy bypassed"
fi

# 3b. The same probe against a literal address. Check 3 also passes when the name just
#     fails to resolve; this one needs no DNS, so it can only fail on routing.
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
