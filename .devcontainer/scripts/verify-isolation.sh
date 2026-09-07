#!/usr/bin/env bash
# Assert this container's egress isolation is intact. Runs as postStartCommand with
# waitFor: postStartCommand, so a non-zero exit blocks the editor from attaching.
#
# Only a genuine isolation failure is fatal -- egress existing where there should be
# none, or the proxy failing to filter. A merely unreachable network (laptop offline,
# proxy still starting, upstream outage) is reported as a warning and the container
# starts anyway; refusing to open in that case would look like a security breach when
# it is only a connectivity problem.
#
#   fatal   - the unlisted host answered through the proxy (the ACL is not filtering),
#             unless PROXY_MODE=open, where that is the intended behavior
#   fatal   - anything was reachable with the proxy bypassed (a route out exists)
#   warning - an allowed host did not answer
#   warning - the proxy itself could not be reached
set -uo pipefail

ALLOWED_URL=https://registry.npmjs.org/
DENIED_URL=https://example.com/
# GitHub's address, used only as a literal that is known to route. Probing it with the
# proxy unset cannot involve DNS, so unlike the hostname probe below it can only fail
# on the absence of a route.
DENIED_IP_URL=https://140.82.121.6/

fatals=0
warnings=0

pass()  { printf 'ok    - %s\n' "$1"; }
warn()  { printf 'WARN  - %s\n' "$1" >&2; warnings=$((warnings + 1)); }
fatal() { printf 'FATAL - %s\n' "$1" >&2; fatals=$((fatals + 1)); }

# 1. An allowed host answers through the proxy. Not api.github.com: that endpoint is
#    rate limited to 60/hr per source IP unauthenticated, and a 403 from the limiter
#    would look like a failure. registry.npmjs.org is on the same allowlist and is not.
allowed_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$ALLOWED_URL")"
if [ "$allowed_code" = 200 ]; then
    pass "allowed host reachable through the proxy ($ALLOWED_URL)"
else
    warn "allowed host NOT reachable through the proxy ($ALLOWED_URL, got ${allowed_code:-<none>}) - connectivity, not isolation"
fi

# 2. An unlisted host is refused by the proxy. Three outcomes have to be told apart:
#      curl exit 0                     -> the host answered: the ACL is not filtering
#      "CONNECT tunnel failed, response 403" -> the ACL is doing its job
#      any other error                 -> the proxy could not be reached at all
#
#    The output is captured before being matched, not piped straight into grep: a
#    refused CONNECT also makes curl exit 56, and under `set -o pipefail` that failure
#    becomes the pipeline's status even when grep matched. Piping directly would make
#    this check fail in exactly the case it exists to confirm.
#
#    PROXY_MODE=open (see ../.env) turns this expectation inside out on purpose: the
#    domain allowlist is deliberately off, so the unlisted host answering is the
#    correct outcome, not a filtering failure.
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

# 3. With the proxy bypassed there is no route out at all. ALL_PROXY is unset along
#    with the protocol-specific variables: curl honours it as a catch-all, so leaving
#    it set would let this check route through a proxy while reporting that it did
#    not -- the one way this assertion could pass vacuously.
noproxy() { env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy \
                -u ALL_PROXY -u all_proxy "$@"; }

if noproxy curl -s -o /dev/null --max-time 10 "$ALLOWED_URL"; then
    fatal "reached $ALLOWED_URL with the proxy bypassed - this container is NOT isolated"
else
    pass "no egress to a hostname with the proxy bypassed"
fi

# 3b. The same probe against a literal address. Check 3 alone also passes when the
#     name merely fails to resolve, so it cannot distinguish "no route" from "no DNS";
#     this one needs no DNS and so can only fail on routing.
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
