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

# 3. With the proxy bypassed there is no route out at all.
if env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy \
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
